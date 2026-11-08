//! # morphic-query
//!
//! Deterministic query execution over columnar tables (docs/architecture/05 §4).
//!
//! **M1.3 (task 1.3.1):** full plan execution — filter tree, field-scoped search, stable
//! multi-key sort with an explicit nulls policy, group-by with streaming accumulators, a
//! wall-clock budget, and an LRU result cache keyed by `(datasetRevision, planHash)`.
//!
//! Execution order is the contract's: filter → search → sort → group/agg → page. Search is
//! still a linear scan; an index is a later optimization and is not claimed here.
//!
//! **Not in 1.3.1:** `projection`. A projected page needs column names in [`Page`] for the UI
//! to label it, which is a wire change that belongs with the table UI in 1.3.3. A plan carrying
//! `projection` is rejected rather than silently ignored.
//!
//! Every result is bounded: `limit` is clamped to [`MAX_PAGE_SIZE`] so a malformed or
//! hostile plan can never ask the engine to materialize an unbounded page.

mod budget;
pub mod cache;
pub mod chart;
pub mod filter;
pub mod group;
pub mod sort;

pub use budget::{CHECK_ROWS, DEFAULT_BUDGET_MS};
pub use chart::{
    auto_bucket, category_scene, category_scene_ordered, series_scene, timeline_scene, Bucketing,
    CategoryOrder, CategoryPoint, CategoryScene, ChartScene, LaneCount, Series, SeriesPoint,
    SeriesScene, SeriesSpec, TimelineBucket, TimelineScene, TimelineSpec, MAX_BAR_POINTS,
    MAX_CATEGORY_GROUPS, MAX_CHART_POINTS, MAX_SERIES, OTHER_LABEL,
};
pub use filter::{Compare, Filter};
pub use group::{AggSpec, GroupedRows, MAX_GROUPS};
pub use sort::{Direction, Nulls, SortSpec};

use budget::Deadline;
use morphic_model::temporal::format_utc_ms;
use morphic_model::{Column, ColumnValues, Table};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Hard ceiling on rows returned by one page (docs/architecture/03 §4).
pub const MAX_PAGE_SIZE: usize = 1024;
/// Default page size when a plan does not specify one.
pub const DEFAULT_PAGE_SIZE: usize = 256;

/// A validated, deterministic query plan. The grammar is closed — never AI-executed.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Plan {
    #[serde(default)]
    pub search: Option<String>,
    /// Restrict search to these fields. `None` searches every column, which is what M1.1 did.
    #[serde(default)]
    pub search_fields: Option<Vec<String>>,
    /// The flat wire filter node (`{op, field, value, args}`), parsed into a [`Filter`] tree at
    /// execution time. Kept as JSON so a plan round-trips and hashes without the schema crate.
    #[serde(default)]
    pub filter: Option<serde_json::Value>,
    #[serde(default)]
    pub sort: Vec<SortSpec>,
    #[serde(default)]
    pub group_by: Vec<String>,
    #[serde(default)]
    pub aggs: Vec<AggSpec>,
    #[serde(default)]
    pub offset: usize,
    #[serde(default = "default_limit")]
    pub limit: usize,
    /// Wall-clock budget for this query. `None` uses [`DEFAULT_BUDGET_MS`].
    #[serde(default)]
    pub budget_ms: Option<u64>,
}

fn default_limit() -> usize {
    DEFAULT_PAGE_SIZE
}

impl Default for Plan {
    fn default() -> Self {
        Self {
            search: None,
            search_fields: None,
            filter: None,
            sort: Vec::new(),
            group_by: Vec::new(),
            aggs: Vec::new(),
            offset: 0,
            limit: DEFAULT_PAGE_SIZE,
            budget_ms: None,
        }
    }
}

impl Plan {
    /// The limit actually applied, after clamping into `1..=MAX_PAGE_SIZE`.
    pub fn effective_limit(&self) -> usize {
        self.limit.clamp(1, MAX_PAGE_SIZE)
    }

    /// Stable hash for the result cache key. Canonical JSON, so two plans that mean the same
    /// thing but were built in a different field order hash identically.
    pub fn hash(&self) -> u64 {
        serde_json::to_value(self)
            .map(|v| cache::hash_json(&v))
            .unwrap_or(0)
    }

    /// Validate every part of the plan against a table, without executing it.
    pub fn validate(&self, table: &Table) -> Result<(), QueryError> {
        if let Some(fields) = &self.search_fields {
            for f in fields {
                find_column(table, f)?;
            }
        }
        if let Some(node) = &self.filter {
            Filter::from_json(node)?.validate(table)?;
        }
        sort::validate(table, &self.sort)?;
        group::validate(table, &self.group_by, &self.aggs)?;
        if !self.group_by.is_empty() && self.aggs.is_empty() {
            return Err(QueryError::InvalidPlan(
                "groupBy requires at least one aggregation".into(),
            ));
        }
        if self.group_by.is_empty() && !self.aggs.is_empty() {
            return Err(QueryError::InvalidPlan(
                "aggs without groupBy: use `aggregate` for a whole-table aggregation".into(),
            ));
        }
        Ok(())
    }
}

/// One page of results plus the information a pager needs.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    /// Row-major cells. Nulls are JSON `null`; timestamps are ISO-8601 UTC strings.
    pub rows: Vec<Vec<serde_json::Value>>,
    /// Rows matching the plan (before paging), so the UI can size its scrollbar.
    pub total_rows: usize,
    pub offset: usize,
    /// The clamped limit that was actually applied.
    pub limit: usize,
    /// True when more rows exist beyond this page.
    pub has_more: bool,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum QueryError {
    #[error("unknown field '{0}'")]
    UnknownField(String),
    #[error("unknown aggregation op '{0}'")]
    UnknownOp(String),
    #[error("aggregation '{0}' requires a field")]
    FieldRequired(String),
    #[error("field '{field}' of type {dtype} is not numeric")]
    NotNumeric { field: String, dtype: String },
    #[error("invalid query plan: {0}")]
    InvalidPlan(String),
    #[error("query resource limit: {0}")]
    ResourceLimit(String),
}

/// Look up a column by name, with the error every caller wants.
pub(crate) fn find_column<'t>(table: &'t Table, name: &str) -> Result<&'t Column, QueryError> {
    table
        .columns
        .iter()
        .find(|c| c.name == name)
        .ok_or_else(|| QueryError::UnknownField(name.to_string()))
}

/// Render one cell as JSON. Null-flagged rows are always `null`, never the buffer placeholder.
fn cell_json(col: &Column, i: usize) -> serde_json::Value {
    use serde_json::Value;
    if col.nulls.get(i).copied().unwrap_or(true) {
        return Value::Null;
    }
    match &col.values {
        ColumnValues::Bool(v) => v.get(i).map(|b| Value::Bool(*b)).unwrap_or(Value::Null),
        ColumnValues::Int64(v) => v
            .get(i)
            .map(|n| serde_json::json!(n))
            .unwrap_or(Value::Null),
        ColumnValues::Float64(v) => v
            .get(i)
            .filter(|x| x.is_finite())
            .map(|x| serde_json::json!(x))
            .unwrap_or(Value::Null),
        ColumnValues::Utf8(v) => v
            .get(i)
            .map(|s| Value::String(s.clone()))
            .unwrap_or(Value::Null),
        ColumnValues::Timestamp(v) => v
            .get(i)
            .map(|ms| Value::String(format_utc_ms(*ms)))
            .unwrap_or(Value::Null),
        ColumnValues::Null => Value::Null,
    }
}

/// A plain, comparable representation used for search and distinct counting.
fn cell_text(col: &Column, i: usize) -> String {
    match cell_json(col, i) {
        serde_json::Value::Null => String::new(),
        serde_json::Value::String(s) => s,
        other => other.to_string(),
    }
}

/// Total row count (kept for the Phase 0 callers).
pub fn count(table: &Table) -> usize {
    table.row_count
}

/// Execute a bounded page: filter → search → sort → page.
///
/// Returns an error for an invalid plan or an exhausted budget. Paging metadata describes the
/// *matching* rows, so a filter narrows `total_rows` and the scrollbar with it.
pub fn query_page(table: &Table, plan: &Plan) -> Result<Page, QueryError> {
    plan.validate(table)?;
    if !plan.group_by.is_empty() {
        // Returning ungrouped rows for a grouped plan would be a silently wrong answer.
        return Err(QueryError::InvalidPlan(
            "this plan groups: call query_groups instead of query_page".into(),
        ));
    }
    let limit = plan.effective_limit();
    let matching = full_selection(table, plan)?;

    let total_rows = matching.len();
    let offset = plan.offset.min(total_rows);
    let window: Vec<usize> = matching.iter().skip(offset).take(limit).copied().collect();
    let rows = window
        .iter()
        .map(|r| table.columns.iter().map(|c| cell_json(c, *r)).collect())
        .collect();

    Ok(Page {
        rows,
        total_rows,
        offset,
        limit,
        has_more: offset + window.len() < total_rows,
    })
}

/// Execute the grouping path: filter → search → sort → group/agg.
///
/// Paging does not apply — the group count is bounded by [`MAX_GROUPS`] instead, and
/// [`GroupedRows::truncated`] says when the answer was capped. Both paths share
/// [`full_selection`], so a grouped answer can never disagree with the table it summarizes.
pub fn query_groups(table: &Table, plan: &Plan) -> Result<GroupedRows, QueryError> {
    plan.validate(table)?;
    if plan.group_by.is_empty() {
        return Err(QueryError::InvalidPlan(
            "queryGroups requires groupBy".into(),
        ));
    }
    let selection = full_selection(table, plan)?;
    group::execute(
        table,
        &selection,
        &plan.group_by,
        &plan.aggs,
        MAX_GROUPS,
        plan.budget_ms,
    )
}

/// The complete matching, sorted selection for a plan, with no paging applied.
///
/// Public because a filtered aggregation needs the selection rather than a page: a metric card
/// must summarize every matching row, not the 256 the table happens to be showing.
pub fn select_rows(table: &Table, plan: &Plan) -> Result<Vec<usize>, QueryError> {
    plan.validate(table)?;
    full_selection(table, plan)
}

/// The complete matching, sorted selection — the shared first half of both execution paths.
fn full_selection(table: &Table, plan: &Plan) -> Result<Vec<usize>, QueryError> {
    let deadline = Deadline::new(plan.budget_ms);
    let parsed = match &plan.filter {
        Some(node) => Some(filter::Compiled::new(&Filter::from_json(node)?, table)?),
        None => None,
    };
    let needle = plan
        .search
        .as_deref()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty());
    let search_cols: Vec<&Column> = match &plan.search_fields {
        None => table.columns.iter().collect(),
        Some(names) => names
            .iter()
            .map(|n| find_column(table, n))
            .collect::<Result<_, _>>()?,
    };

    let mut rows = Vec::new();
    for row in 0..table.row_count {
        if row % CHECK_ROWS == 0 && row > 0 {
            deadline.check("filter/search")?;
        }
        if let Some(f) = &parsed {
            if !f.matches(row) {
                continue;
            }
        }
        if let Some(n) = &needle {
            let hit = search_cols
                .iter()
                .any(|c| cell_text(c, row).to_lowercase().contains(n));
            if !hit {
                continue;
            }
        }
        rows.push(row);
    }
    deadline.check("filter/search")?;

    sort::sort_selection(table, &mut rows, &plan.sort);
    deadline.check("sort")?;
    Ok(rows)
}

/// An aggregation request, decoupled from the UI schema so this crate stays below it.
#[derive(Debug, Clone, Copy)]
pub struct Aggregate<'a> {
    pub op: &'a str,
    pub field: Option<&'a str>,
}

/// Iterate a selection, or every row when there is none. Boxed so the two shapes share one
/// call site without allocating an index vector for the unfiltered case.
fn selected(rows: Option<&[usize]>, row_count: usize) -> Box<dyn Iterator<Item = usize> + '_> {
    match rows {
        Some(r) => Box::new(r.iter().copied()),
        None => Box::new(0..row_count),
    }
}

/// Numeric values of the selected rows, skipping nulls and non-finite floats.
fn numbers_over(col: &Column, rows: Option<&[usize]>, row_count: usize) -> Vec<f64> {
    let keep = |i: usize| !col.nulls.get(i).copied().unwrap_or(true);
    match &col.values {
        ColumnValues::Int64(v) => selected(rows, row_count)
            .filter(|i| keep(*i))
            .filter_map(|i| v.get(i).map(|x| *x as f64))
            .collect(),
        ColumnValues::Float64(v) => selected(rows, row_count)
            .filter(|i| keep(*i))
            .filter_map(|i| v.get(i).copied())
            .filter(|x| x.is_finite())
            .collect(),
        _ => Vec::new(),
    }
}

fn is_numeric(col: &Column) -> bool {
    matches!(
        col.values,
        ColumnValues::Int64(_) | ColumnValues::Float64(_)
    )
}

/// Execute one aggregation. Returns JSON `null` when there is nothing to aggregate, so an
/// empty dataset renders as "no data" rather than a misleading zero.
pub fn aggregate(table: &Table, agg: &Aggregate<'_>) -> Result<serde_json::Value, QueryError> {
    aggregate_over(table, None, agg)
}

/// Aggregate over a selection of rows, or the whole table when `rows` is `None`.
///
/// This is how a filter reaches a metric card: the caller selects once and aggregates the
/// selection, rather than materializing a filtered copy of the table.
pub fn aggregate_over(
    table: &Table,
    rows: Option<&[usize]>,
    agg: &Aggregate<'_>,
) -> Result<serde_json::Value, QueryError> {
    use serde_json::Value;

    let column = match agg.field {
        None => None,
        Some(name) => Some(
            table
                .columns
                .iter()
                .find(|c| c.name == name)
                .ok_or_else(|| QueryError::UnknownField(name.to_string()))?,
        ),
    };

    match agg.op {
        // count with no field = rows; with a field = non-null cells of that field.
        "count" => {
            let n = match column {
                None => rows.map_or(table.row_count, |r| r.len()),
                Some(c) => selected(rows, table.row_count)
                    .filter(|i| !filter::is_null(c, *i))
                    .count(),
            };
            Ok(serde_json::json!(n))
        }
        "distinct_count" => {
            let c = column.ok_or_else(|| QueryError::FieldRequired(agg.op.into()))?;
            let mut seen = std::collections::HashSet::new();
            for i in selected(rows, table.row_count) {
                if !filter::is_null(c, i) {
                    seen.insert(cell_text(c, i));
                }
            }
            Ok(serde_json::json!(seen.len()))
        }
        "sum" | "avg" => {
            let c = column.ok_or_else(|| QueryError::FieldRequired(agg.op.into()))?;
            if !is_numeric(c) {
                return Err(QueryError::NotNumeric {
                    field: c.name.clone(),
                    dtype: c.dtype.as_str().to_string(),
                });
            }
            let vals = numbers_over(c, rows, table.row_count);
            if vals.is_empty() {
                return Ok(Value::Null);
            }
            let sum: f64 = vals.iter().sum();
            let out = if agg.op == "avg" {
                sum / vals.len() as f64
            } else {
                sum
            };
            Ok(serde_json::json!(out))
        }
        "min" | "max" => {
            let c = column.ok_or_else(|| QueryError::FieldRequired(agg.op.into()))?;
            // Timestamps are ordered: report the boundary as a readable UTC instant.
            if let ColumnValues::Timestamp(v) = &c.values {
                let vals: Vec<i64> = selected(rows, table.row_count)
                    .filter(|i| !filter::is_null(c, *i))
                    .filter_map(|i| v.get(i).copied())
                    .collect();
                let picked = if agg.op == "min" {
                    vals.iter().min()
                } else {
                    vals.iter().max()
                };
                return Ok(match picked {
                    Some(ms) => Value::String(format_utc_ms(*ms)),
                    None => Value::Null,
                });
            }
            if !is_numeric(c) {
                return Err(QueryError::NotNumeric {
                    field: c.name.clone(),
                    dtype: c.dtype.as_str().to_string(),
                });
            }
            let vals = numbers_over(c, rows, table.row_count);
            let picked = if agg.op == "min" {
                vals.iter().copied().reduce(f64::min)
            } else {
                vals.iter().copied().reduce(f64::max)
            };
            Ok(match picked {
                Some(x) => serde_json::json!(x),
                None => Value::Null,
            })
        }
        other => Err(QueryError::UnknownOp(other.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use morphic_model::{DataType, Table};

    fn table() -> Table {
        Table {
            columns: vec![
                Column {
                    name: "id".into(),
                    dtype: DataType::Int64,
                    values: ColumnValues::Int64(vec![1, 2, 3, 4, 5]),
                    nulls: vec![false; 5],
                },
                Column {
                    name: "name".into(),
                    dtype: DataType::Utf8,
                    values: ColumnValues::Utf8(
                        ["alpha", "beta", "gamma", "delta", "epsilon"]
                            .iter()
                            .map(|s| s.to_string())
                            .collect(),
                    ),
                    nulls: vec![false, false, true, false, false],
                },
                Column {
                    name: "amount".into(),
                    dtype: DataType::Float64,
                    values: ColumnValues::Float64(vec![10.0, 20.0, 0.0, 40.0, 50.0]),
                    nulls: vec![false, false, true, false, false],
                },
            ],
            row_count: 5,
        }
    }

    fn agg<'a>(op: &'a str, field: Option<&'a str>) -> Aggregate<'a> {
        Aggregate { op, field }
    }

    #[test]
    fn count_returns_row_count() {
        assert_eq!(count(&table()), 5);
    }

    #[test]
    fn plan_defaults_to_256() {
        assert_eq!(Plan::default().limit, DEFAULT_PAGE_SIZE);
        let p: Plan = serde_json::from_str("{}").unwrap();
        assert_eq!(p.limit, DEFAULT_PAGE_SIZE);
    }

    #[test]
    fn limit_is_clamped_to_the_hard_ceiling() {
        let p = Plan {
            limit: 100_000,
            ..Default::default()
        };
        assert_eq!(p.effective_limit(), MAX_PAGE_SIZE);
        let page = query_page(&table(), &p).unwrap();
        assert_eq!(page.limit, MAX_PAGE_SIZE);
        assert_eq!(page.rows.len(), 5);
    }

    #[test]
    fn zero_limit_becomes_one_row_not_an_empty_page() {
        let p = Plan {
            limit: 0,
            ..Default::default()
        };
        let page = query_page(&table(), &p).unwrap();
        assert_eq!(page.limit, 1);
        assert_eq!(page.rows.len(), 1);
    }

    #[test]
    fn paging_walks_the_table_without_gaps_or_repeats() {
        let t = table();
        let p1 = query_page(
            &t,
            &Plan {
                limit: 2,
                offset: 0,
                ..Default::default()
            },
        )
        .unwrap();
        let p2 = query_page(
            &t,
            &Plan {
                limit: 2,
                offset: 2,
                ..Default::default()
            },
        )
        .unwrap();
        let p3 = query_page(
            &t,
            &Plan {
                limit: 2,
                offset: 4,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(p1.rows[0][0], serde_json::json!(1));
        assert_eq!(p2.rows[0][0], serde_json::json!(3));
        assert_eq!(p3.rows[0][0], serde_json::json!(5));
        assert!(p1.has_more);
        assert!(p2.has_more);
        assert!(!p3.has_more);
        assert_eq!(p1.total_rows, 5);
    }

    #[test]
    fn offset_past_the_end_is_empty_not_an_error() {
        let page = query_page(
            &table(),
            &Plan {
                offset: 999,
                ..Default::default()
            },
        )
        .unwrap();
        assert!(page.rows.is_empty());
        assert_eq!(page.offset, 5);
        assert!(!page.has_more);
    }

    #[test]
    fn nulls_are_json_null_not_the_buffer_placeholder() {
        let page = query_page(
            &table(),
            &Plan {
                offset: 2,
                limit: 1,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(page.rows[0][1], serde_json::Value::Null);
        assert_eq!(page.rows[0][2], serde_json::Value::Null);
    }

    #[test]
    fn search_is_case_insensitive_across_columns() {
        let p = Plan {
            search: Some("ALPHA".into()),
            ..Default::default()
        };
        let page = query_page(&table(), &p).unwrap();
        assert_eq!(page.total_rows, 1);
        assert_eq!(page.rows[0][0], serde_json::json!(1));
    }

    #[test]
    fn blank_search_matches_everything() {
        let p = Plan {
            search: Some("   ".into()),
            ..Default::default()
        };
        assert_eq!(query_page(&table(), &p).unwrap().total_rows, 5);
    }

    #[test]
    fn search_with_no_matches_is_empty() {
        let p = Plan {
            search: Some("zzzz".into()),
            ..Default::default()
        };
        let page = query_page(&table(), &p).unwrap();
        assert_eq!(page.total_rows, 0);
        assert!(page.rows.is_empty());
        assert!(!page.has_more);
    }

    #[test]
    fn timestamps_render_as_iso_strings() {
        let t = Table {
            columns: vec![Column {
                name: "when".into(),
                dtype: DataType::Timestamp,
                values: ColumnValues::Timestamp(vec![0]),
                nulls: vec![false],
            }],
            row_count: 1,
        };
        let page = query_page(&t, &Plan::default()).unwrap();
        assert_eq!(
            page.rows[0][0],
            serde_json::json!("1970-01-01T00:00:00.000Z")
        );
    }

    #[test]
    fn count_without_field_counts_rows() {
        assert_eq!(
            aggregate(&table(), &agg("count", None)).unwrap(),
            serde_json::json!(5)
        );
    }

    #[test]
    fn count_with_field_skips_nulls() {
        assert_eq!(
            aggregate(&table(), &agg("count", Some("amount"))).unwrap(),
            serde_json::json!(4)
        );
    }

    #[test]
    fn sum_and_avg_skip_nulls() {
        assert_eq!(
            aggregate(&table(), &agg("sum", Some("amount"))).unwrap(),
            serde_json::json!(120.0)
        );
        assert_eq!(
            aggregate(&table(), &agg("avg", Some("amount"))).unwrap(),
            serde_json::json!(30.0)
        );
    }

    #[test]
    fn min_and_max_on_numbers() {
        assert_eq!(
            aggregate(&table(), &agg("min", Some("amount"))).unwrap(),
            serde_json::json!(10.0)
        );
        assert_eq!(
            aggregate(&table(), &agg("max", Some("amount"))).unwrap(),
            serde_json::json!(50.0)
        );
    }

    #[test]
    fn distinct_count_ignores_nulls() {
        assert_eq!(
            aggregate(&table(), &agg("distinct_count", Some("name"))).unwrap(),
            serde_json::json!(4)
        );
    }

    #[test]
    fn empty_aggregation_is_null_not_zero() {
        let t = Table {
            columns: vec![Column {
                name: "x".into(),
                dtype: DataType::Float64,
                values: ColumnValues::Float64(vec![0.0]),
                nulls: vec![true],
            }],
            row_count: 1,
        };
        assert_eq!(
            aggregate(&t, &agg("avg", Some("x"))).unwrap(),
            serde_json::Value::Null
        );
    }

    #[test]
    fn timestamp_min_max_are_readable_instants() {
        let t = Table {
            columns: vec![Column {
                name: "when".into(),
                dtype: DataType::Timestamp,
                values: ColumnValues::Timestamp(vec![1_700_000_000_000, 0]),
                nulls: vec![false; 2],
            }],
            row_count: 2,
        };
        assert_eq!(
            aggregate(&t, &agg("min", Some("when"))).unwrap(),
            serde_json::json!("1970-01-01T00:00:00.000Z")
        );
        assert_eq!(
            aggregate(&t, &agg("max", Some("when"))).unwrap(),
            serde_json::json!("2023-11-14T22:13:20.000Z")
        );
    }

    #[test]
    fn averaging_text_is_an_error_not_a_silent_zero() {
        assert_eq!(
            aggregate(&table(), &agg("avg", Some("name"))),
            Err(QueryError::NotNumeric {
                field: "name".into(),
                dtype: "utf8".into()
            })
        );
    }

    #[test]
    fn unknown_field_and_op_are_typed_errors() {
        assert_eq!(
            aggregate(&table(), &agg("avg", Some("ghost"))),
            Err(QueryError::UnknownField("ghost".into()))
        );
        assert_eq!(
            aggregate(&table(), &agg("median", Some("amount"))),
            Err(QueryError::UnknownOp("median".into()))
        );
    }

    #[test]
    fn aggregations_needing_a_field_reject_none() {
        for op in ["sum", "avg", "min", "max", "distinct_count"] {
            assert_eq!(
                aggregate(&table(), &agg(op, None)),
                Err(QueryError::FieldRequired(op.into()))
            );
        }
    }
}

#[cfg(test)]
mod plan_tests {
    use super::*;
    use morphic_model::{DataType, Table};
    use serde_json::{json, Value};

    /// id, region (with a null), amount (with a null), when. Enough shape to exercise every
    /// operator, both null policies, and multi-key stability.
    fn sales() -> Table {
        Table {
            columns: vec![
                Column {
                    name: "id".into(),
                    dtype: DataType::Int64,
                    values: ColumnValues::Int64(vec![1, 2, 3, 4, 5, 6]),
                    nulls: vec![false; 6],
                },
                Column {
                    name: "region".into(),
                    dtype: DataType::Utf8,
                    values: ColumnValues::Utf8(
                        ["eu", "us", "eu", "apac", "us", "eu"]
                            .iter()
                            .map(|s| s.to_string())
                            .collect(),
                    ),
                    nulls: vec![false, false, true, false, false, false],
                },
                Column {
                    name: "amount".into(),
                    dtype: DataType::Float64,
                    values: ColumnValues::Float64(vec![10.0, 20.0, 30.0, 40.0, 20.0, 10.0]),
                    nulls: vec![false, false, false, true, false, false],
                },
            ],
            row_count: 6,
        }
    }

    fn ids(page: &Page) -> Vec<i64> {
        page.rows.iter().map(|r| r[0].as_i64().unwrap()).collect()
    }

    fn run(filter: serde_json::Value) -> Page {
        query_page(
            &sales(),
            &Plan {
                filter: Some(filter),
                ..Default::default()
            },
        )
        .unwrap()
    }

    #[test]
    fn comparisons_use_the_column_type_not_the_json_type() {
        // A numeric string bound against an Int64 column still compares numerically.
        let p = run(json!({"op": "gt", "field": "id", "value": "3"}));
        assert_eq!(ids(&p), vec![4, 5, 6]);
        let p = run(json!({"op": "gte", "field": "amount", "value": 20.0}));
        assert_eq!(ids(&p), vec![2, 3, 5]);
    }

    #[test]
    fn nulls_never_satisfy_a_comparison_even_neq() {
        // Row 3 has a null region; row 4 a null amount.
        let p = run(json!({"op": "eq", "field": "region", "value": "eu"}));
        assert_eq!(ids(&p), vec![1, 6]);
        let p = run(json!({"op": "neq", "field": "region", "value": "eu"}));
        assert_eq!(ids(&p), vec![2, 4, 5], "null region is not 'not eu'");
        let p = run(json!({"op": "is_null", "field": "region"}));
        assert_eq!(ids(&p), vec![3]);
        let p = run(json!({"op": "not_null", "field": "amount"}));
        assert_eq!(ids(&p), vec![1, 2, 3, 5, 6]);
    }

    #[test]
    fn not_complements_the_match_so_it_includes_nulls() {
        let p = run(json!({"op": "not", "args": [
            {"op": "eq", "field": "region", "value": "eu"}
        ]}));
        assert_eq!(
            ids(&p),
            vec![2, 3, 4, 5],
            "row 3 is null and not-eu matched"
        );
    }

    #[test]
    fn and_or_compose_and_short_circuit() {
        let p = run(json!({"op": "and", "args": [
            {"op": "eq", "field": "region", "value": "eu"},
            {"op": "gte", "field": "amount", "value": 10}
        ]}));
        assert_eq!(ids(&p), vec![1, 6]);
        let p = run(json!({"op": "or", "args": [
            {"op": "eq", "field": "region", "value": "apac"},
            {"op": "eq", "field": "id", "value": 1}
        ]}));
        assert_eq!(ids(&p), vec![1, 4]);
    }

    #[test]
    fn in_and_contains() {
        let p = run(json!({"op": "in", "field": "region", "value": ["us", "apac"]}));
        assert_eq!(ids(&p), vec![2, 4, 5]);
        let p = run(json!({"op": "contains", "field": "region", "value": "PA"}));
        assert_eq!(ids(&p), vec![4], "contains is case-insensitive");
    }

    #[test]
    fn every_schema_operator_name_parses() {
        // The grammar is duplicated across the DAG boundary; this pins the names so the two
        // cannot drift apart silently.
        let leaf = json!({"op": "eq", "field": "id", "value": 1});
        for op in ["eq", "neq", "gt", "gte", "lt", "lte"] {
            assert!(Filter::from_json(&json!({"op": op, "field": "id", "value": 1})).is_ok());
        }
        for op in ["is_null", "not_null"] {
            assert!(Filter::from_json(&json!({"op": op, "field": "id"})).is_ok());
        }
        assert!(Filter::from_json(&json!({"op":"contains","field":"region","value":"e"})).is_ok());
        assert!(Filter::from_json(&json!({"op":"in","field":"id","value":[1,2]})).is_ok());
        for op in ["and", "or"] {
            assert!(Filter::from_json(&json!({"op": op, "args": [leaf]})).is_ok());
        }
        assert!(Filter::from_json(&json!({"op":"not","args":[leaf]})).is_ok());
    }

    #[test]
    fn bad_plans_are_errors_not_empty_results() {
        let t = sales();
        let bad = [
            json!({"op": "regex", "field": "id", "value": "x"}),
            json!({"op": "eq", "value": 1}),
            json!({"op": "eq", "field": "id"}),
            json!({"op": "and", "args": []}),
            json!({"op": "not", "args": []}),
            json!({"op": "in", "field": "id", "value": []}),
            json!({"op": "in", "field": "id", "value": 3}),
            json!({"op": "contains", "field": "region", "value": 3}),
            json!({"op": "gt", "field": "amount", "value": "abc"}),
            json!({"op": "eq", "field": "nope", "value": 1}),
        ];
        for node in bad {
            let err = query_page(
                &t,
                &Plan {
                    filter: Some(node.clone()),
                    ..Default::default()
                },
            );
            assert!(err.is_err(), "{node} should be rejected");
        }
    }

    #[test]
    fn a_hostile_filter_is_bounded() {
        let mut node = json!({"op": "eq", "field": "id", "value": 1});
        for _ in 0..(filter::MAX_FILTER_DEPTH + 2) {
            node = json!({"op": "not", "args": [node]});
        }
        assert!(Filter::from_json(&node).is_err());

        let many: Vec<_> = (0..filter::MAX_FILTER_NODES + 2)
            .map(|_| json!({"op": "eq", "field": "id", "value": 1}))
            .collect();
        assert!(Filter::from_json(&json!({"op": "or", "args": many})).is_err());
    }

    #[test]
    fn sort_is_stable_across_equal_keys() {
        // amount 20 appears at rows 2 and 5; 10 at rows 1 and 6. A stable sort keeps 2 before 5.
        let p = query_page(
            &sales(),
            &Plan {
                sort: vec![SortSpec::asc("amount")],
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(
            ids(&p),
            vec![1, 6, 2, 5, 3, 4],
            "nulls last, ties in source order"
        );
    }

    #[test]
    fn nulls_policy_is_independent_of_direction() {
        for (dir, want) in [
            (Direction::Asc, vec![1, 6, 2, 5, 3, 4]),
            (Direction::Desc, vec![3, 2, 5, 1, 6, 4]),
        ] {
            let p = query_page(
                &sales(),
                &Plan {
                    sort: vec![SortSpec {
                        field: "amount".into(),
                        dir,
                        nulls: Nulls::Last,
                    }],
                    ..Default::default()
                },
            )
            .unwrap();
            assert_eq!(ids(&p), want, "{dir:?} keeps the null last");
        }
        let p = query_page(
            &sales(),
            &Plan {
                sort: vec![SortSpec {
                    field: "amount".into(),
                    dir: Direction::Desc,
                    nulls: Nulls::First,
                }],
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(ids(&p)[0], 4, "nulls first means first");
    }

    #[test]
    fn multi_key_sort_applies_keys_in_order() {
        let p = query_page(
            &sales(),
            &Plan {
                sort: vec![SortSpec::asc("region"), SortSpec::desc("amount")],
                ..Default::default()
            },
        )
        .unwrap();
        // apac(4, null amount), eu(1,6,3-null-region excluded), us(2,5), then null region(3).
        assert_eq!(ids(&p), vec![4, 1, 6, 2, 5, 3]);
    }

    #[test]
    fn search_can_be_scoped_to_fields() {
        let all = query_page(
            &sales(),
            &Plan {
                search: Some("20".into()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(ids(&all), vec![2, 5]);
        let scoped = query_page(
            &sales(),
            &Plan {
                search: Some("eu".into()),
                search_fields: Some(vec!["region".into()]),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(ids(&scoped), vec![1, 6]);
        let none = query_page(
            &sales(),
            &Plan {
                search: Some("eu".into()),
                search_fields: Some(vec!["id".into()]),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(none.total_rows, 0);
    }

    #[test]
    fn filter_narrows_the_paging_metadata_too() {
        let p = query_page(
            &sales(),
            &Plan {
                filter: Some(json!({"op": "eq", "field": "region", "value": "eu"})),
                limit: 1,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(p.total_rows, 2);
        assert!(p.has_more);
        assert_eq!(p.rows.len(), 1);
    }

    #[test]
    fn the_budget_is_enforced_and_reported() {
        let err = query_page(
            &sales(),
            &Plan {
                budget_ms: Some(0),
                ..Default::default()
            },
        )
        .unwrap_err();
        assert!(matches!(err, QueryError::ResourceLimit(_)), "{err}");
        assert!(err.to_string().contains("budget"));
    }

    #[test]
    fn grouping_streams_and_labels_its_columns() {
        let g = query_groups(
            &sales(),
            &Plan {
                group_by: vec!["region".into()],
                aggs: vec![
                    AggSpec::new("count", None),
                    AggSpec::new("sum", Some("amount")),
                ],
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(g.columns, vec!["region", "count", "sum_amount"]);
        assert_eq!(g.total_groups, 4);
        assert!(!g.truncated);
        // First appearance: eu, us, null, apac.
        assert_eq!(g.rows[0][0], json!("eu"));
        assert_eq!(g.rows[0][1], json!(2));
        assert_eq!(g.rows[0][2], json!(20.0));
        assert_eq!(g.rows[2][0], Value::Null, "the null group is a group");
    }

    #[test]
    fn grouping_respects_the_filter_and_the_sort() {
        let g = query_groups(
            &sales(),
            &Plan {
                filter: Some(json!({"op": "not_null", "field": "amount"})),
                sort: vec![SortSpec::desc("amount")],
                group_by: vec!["region".into()],
                aggs: vec![AggSpec::new("avg", Some("amount"))],
                ..Default::default()
            },
        )
        .unwrap();
        // id 3 has the largest amount (30) and a null region, so the null group leads.
        assert_eq!(g.rows[0][0], Value::Null);
        assert_eq!(g.total_groups, 3);
    }

    #[test]
    fn group_cap_reports_truncation_instead_of_lying() {
        let g = group::execute(
            &sales(),
            &[0, 1, 2, 3, 4, 5],
            &["id".to_string()],
            &[AggSpec::new("count", None)],
            2,
            None,
        )
        .unwrap();
        assert_eq!(g.rows.len(), 2);
        assert_eq!(g.total_groups, 6);
        assert!(g.truncated);
    }

    #[test]
    fn an_empty_group_aggregates_to_null_not_zero() {
        let t = Table {
            columns: vec![Column {
                name: "x".into(),
                dtype: DataType::Float64,
                values: ColumnValues::Float64(vec![1.0]),
                nulls: vec![true],
            }],
            row_count: 1,
        };
        let g = group::execute(
            &t,
            &[0],
            &["x".to_string()],
            &[AggSpec::new("sum", Some("x")), AggSpec::new("count", None)],
            10,
            None,
        )
        .unwrap();
        assert_eq!(g.rows[0][1], Value::Null, "sum of nothing is null");
        assert_eq!(g.rows[0][2], json!(1), "count of rows is still 1");
    }

    #[test]
    fn invalid_group_plans_are_rejected() {
        let t = sales();
        assert!(query_groups(&t, &Plan::default()).is_err());
        assert!(query_page(
            &t,
            &Plan {
                group_by: vec!["region".into()],
                ..Default::default()
            }
        )
        .is_err());
        assert!(query_page(
            &t,
            &Plan {
                aggs: vec![AggSpec::new("sum", Some("region"))],
                group_by: vec!["id".into()],
                ..Default::default()
            }
        )
        .is_err());
    }

    #[test]
    fn cache_hits_on_the_same_revision_and_misses_on_a_new_one() {
        let plan = Plan::default();
        let key = cache::CacheKey::new(1, plan.hash());
        let mut c: cache::ResultCache<Page> = cache::ResultCache::new(2);
        assert!(c.get(key).is_none());
        c.insert(key, query_page(&sales(), &plan).unwrap());
        assert!(c.get(key).is_some());
        assert!(c.get(cache::CacheKey::new(2, plan.hash())).is_none());
        let s = c.stats();
        assert_eq!((s.hits, s.misses), (1, 2));
    }

    #[test]
    fn cache_evicts_least_recently_used_and_reclaims_old_revisions() {
        let mut c: cache::ResultCache<u8> = cache::ResultCache::new(2);
        let k = |n| cache::CacheKey::new(1, n);
        c.insert(k(1), 1);
        c.insert(k(2), 2);
        assert!(c.get(k(1)).is_some(), "1 is now most recently used");
        c.insert(k(3), 3);
        assert!(c.get(k(2)).is_none(), "2 was least recently used");
        assert!(c.get(k(1)).is_some());
        assert_eq!(c.stats().evictions, 1);
        c.retain_revision(2);
        assert!(c.is_empty());
    }

    #[test]
    fn plan_hash_is_stable_and_sensitive() {
        let a = Plan {
            search: Some("eu".into()),
            ..Default::default()
        };
        let b = a.clone();
        assert_eq!(a.hash(), b.hash());
        let c = Plan {
            search: Some("us".into()),
            ..Default::default()
        };
        assert_ne!(a.hash(), c.hash());
        // Round-tripping through JSON must not change the key.
        let wire = serde_json::to_value(&a).unwrap();
        let back: Plan = serde_json::from_value(wire).unwrap();
        assert_eq!(a.hash(), back.hash());
    }

    #[test]
    fn an_m1_1_plan_still_deserializes() {
        // The bridge and Dart still send the flat three-field shape.
        let p: Plan = serde_json::from_value(json!({"search":"eu","offset":0,"limit":10})).unwrap();
        assert_eq!(p.search.as_deref(), Some("eu"));
        assert!(p.sort.is_empty() && p.filter.is_none());
        assert_eq!(query_page(&sales(), &p).unwrap().total_rows, 2);
    }
}

#[cfg(test)]
mod selection_aggregate_tests {
    use super::*;
    use morphic_model::{DataType, Table};
    use serde_json::{json, Value};

    fn t() -> Table {
        Table {
            columns: vec![
                Column {
                    name: "grp".into(),
                    dtype: DataType::Utf8,
                    values: ColumnValues::Utf8(
                        ["a", "b", "a", "c"].iter().map(|s| s.to_string()).collect(),
                    ),
                    nulls: vec![false, false, false, true],
                },
                Column {
                    name: "v".into(),
                    dtype: DataType::Int64,
                    values: ColumnValues::Int64(vec![1, 2, 3, 4]),
                    nulls: vec![false, false, true, false],
                },
            ],
            row_count: 4,
        }
    }

    fn agg<'a>(op: &'a str, field: Option<&'a str>) -> Aggregate<'a> {
        Aggregate { op, field }
    }

    #[test]
    fn no_selection_matches_the_whole_table_aggregate() {
        let table = t();
        for (op, field) in [
            ("count", None),
            ("count", Some("v")),
            ("sum", Some("v")),
            ("avg", Some("v")),
            ("min", Some("v")),
            ("max", Some("v")),
            ("distinct_count", Some("grp")),
        ] {
            let whole = aggregate(&table, &agg(op, field)).unwrap();
            let explicit = aggregate_over(&table, None, &agg(op, field)).unwrap();
            let all: Vec<usize> = (0..table.row_count).collect();
            let selected = aggregate_over(&table, Some(&all), &agg(op, field)).unwrap();
            assert_eq!(whole, explicit, "{op} {field:?}");
            assert_eq!(whole, selected, "{op} {field:?} over every row");
        }
    }

    #[test]
    fn a_selection_narrows_every_operator() {
        let table = t();
        let rows = [0usize, 1];
        assert_eq!(
            aggregate_over(&table, Some(&rows), &agg("count", None)).unwrap(),
            json!(2)
        );
        assert_eq!(
            aggregate_over(&table, Some(&rows), &agg("count", Some("v"))).unwrap(),
            json!(2)
        );
        assert_eq!(
            aggregate_over(&table, Some(&rows), &agg("sum", Some("v"))).unwrap(),
            json!(3.0)
        );
        assert_eq!(
            aggregate_over(&table, Some(&rows), &agg("min", Some("v"))).unwrap(),
            json!(1.0)
        );
        assert_eq!(
            aggregate_over(&table, Some(&rows), &agg("max", Some("v"))).unwrap(),
            json!(2.0)
        );
        assert_eq!(
            aggregate_over(&table, Some(&rows), &agg("distinct_count", Some("grp"))).unwrap(),
            json!(2)
        );
    }

    #[test]
    fn an_empty_selection_is_null_not_zero_for_value_aggregates() {
        let table = t();
        let none: [usize; 0] = [];
        assert_eq!(
            aggregate_over(&table, Some(&none), &agg("count", None)).unwrap(),
            json!(0)
        );
        assert_eq!(
            aggregate_over(&table, Some(&none), &agg("sum", Some("v"))).unwrap(),
            Value::Null
        );
        assert_eq!(
            aggregate_over(&table, Some(&none), &agg("avg", Some("v"))).unwrap(),
            Value::Null
        );
        assert_eq!(
            aggregate_over(&table, Some(&none), &agg("min", Some("v"))).unwrap(),
            Value::Null
        );
    }

    #[test]
    fn nulls_are_skipped_inside_a_selection_too() {
        let table = t();
        // Row 2 has a null v; row 3 a null grp.
        let rows = [2usize, 3];
        assert_eq!(
            aggregate_over(&table, Some(&rows), &agg("count", None)).unwrap(),
            json!(2)
        );
        assert_eq!(
            aggregate_over(&table, Some(&rows), &agg("count", Some("v"))).unwrap(),
            json!(1),
            "count of a field counts non-null cells"
        );
        assert_eq!(
            aggregate_over(&table, Some(&rows), &agg("sum", Some("v"))).unwrap(),
            json!(4.0)
        );
        assert_eq!(
            aggregate_over(&table, Some(&rows), &agg("distinct_count", Some("grp"))).unwrap(),
            json!(1)
        );
    }

    #[test]
    fn select_rows_applies_the_plan_without_paging() {
        let table = t();
        let plan = Plan {
            filter: Some(json!({"op":"eq","field":"grp","value":"a"})),
            sort: vec![SortSpec::desc("v")],
            limit: 1,
            ..Default::default()
        };
        let rows = select_rows(&table, &plan).unwrap();
        // Row 2's v is null, so nulls-last puts it after row 0 even descending.
        assert_eq!(rows, vec![0, 2], "both matches, sorted, despite limit 1");
        let value = aggregate_over(&table, Some(&rows), &agg("count", None)).unwrap();
        assert_eq!(value, json!(2), "a metric sees every match, not the page");
    }

    #[test]
    fn select_rows_validates_the_plan() {
        let table = t();
        let plan = Plan {
            filter: Some(json!({"op":"eq","field":"nope","value":1})),
            ..Default::default()
        };
        assert!(select_rows(&table, &plan).is_err());
    }
}
