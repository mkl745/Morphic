//! # morphic-query
//!
//! Deterministic query execution over columnar tables (docs/architecture/05 §4).
//!
//! **M1.1 (task 1.1.4):** real bounded paging and aggregation, enough to back the
//! `queryPage` and `metricData` bridge calls. Filter/sort/group-by execution, the LRU plan
//! cache, and indexed search land in M1.3 — `search` here is an honest linear scan.
//!
//! Every result is bounded: `limit` is clamped to [`MAX_PAGE_SIZE`] so a malformed or
//! hostile plan can never ask the engine to materialize an unbounded page.

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
    #[serde(default)]
    pub offset: usize,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    DEFAULT_PAGE_SIZE
}

impl Default for Plan {
    fn default() -> Self {
        Self {
            search: None,
            offset: 0,
            limit: DEFAULT_PAGE_SIZE,
        }
    }
}

impl Plan {
    /// The limit actually applied, after clamping into `1..=MAX_PAGE_SIZE`.
    pub fn effective_limit(&self) -> usize {
        self.limit.clamp(1, MAX_PAGE_SIZE)
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

/// Execute a bounded page. `search` is a case-insensitive substring match across all
/// columns; it is a linear scan and is labelled as such until M1.3 adds an index.
pub fn query_page(table: &Table, plan: &Plan) -> Page {
    let limit = plan.effective_limit();
    let needle = plan
        .search
        .as_deref()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty());

    let matches = |row: usize| -> bool {
        match &needle {
            None => true,
            Some(n) => table
                .columns
                .iter()
                .any(|c| cell_text(c, row).to_lowercase().contains(n)),
        }
    };

    let mut matching: Vec<usize> = (0..table.row_count).filter(|r| matches(*r)).collect();
    let total_rows = matching.len();
    let offset = plan.offset.min(total_rows);
    matching.drain(..offset);
    matching.truncate(limit);

    let rows = matching
        .iter()
        .map(|r| table.columns.iter().map(|c| cell_json(c, *r)).collect())
        .collect();

    Page {
        rows,
        total_rows,
        offset,
        limit,
        has_more: offset + matching.len() < total_rows,
    }
}

/// An aggregation request, decoupled from the UI schema so this crate stays below it.
#[derive(Debug, Clone, Copy)]
pub struct Aggregate<'a> {
    pub op: &'a str,
    pub field: Option<&'a str>,
}

/// Numeric values of a column, skipping nulls and non-finite floats.
fn numbers(col: &Column) -> Vec<f64> {
    let keep = |i: usize| !col.nulls.get(i).copied().unwrap_or(true);
    match &col.values {
        ColumnValues::Int64(v) => v
            .iter()
            .enumerate()
            .filter(|(i, _)| keep(*i))
            .map(|(_, x)| *x as f64)
            .collect(),
        ColumnValues::Float64(v) => v
            .iter()
            .enumerate()
            .filter(|(i, _)| keep(*i))
            .map(|(_, x)| *x)
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
                None => table.row_count,
                Some(c) => c.nulls.iter().filter(|n| !**n).count(),
            };
            Ok(serde_json::json!(n))
        }
        "distinct_count" => {
            let c = column.ok_or_else(|| QueryError::FieldRequired(agg.op.into()))?;
            let mut seen = std::collections::HashSet::new();
            for i in 0..c.len() {
                if !c.nulls.get(i).copied().unwrap_or(true) {
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
            let vals = numbers(c);
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
                let vals: Vec<i64> = v
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| !c.nulls.get(*i).copied().unwrap_or(true))
                    .map(|(_, x)| *x)
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
            let vals = numbers(c);
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
        let page = query_page(&table(), &p);
        assert_eq!(page.limit, MAX_PAGE_SIZE);
        assert_eq!(page.rows.len(), 5);
    }

    #[test]
    fn zero_limit_becomes_one_row_not_an_empty_page() {
        let p = Plan {
            limit: 0,
            ..Default::default()
        };
        let page = query_page(&table(), &p);
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
        );
        let p2 = query_page(
            &t,
            &Plan {
                limit: 2,
                offset: 2,
                ..Default::default()
            },
        );
        let p3 = query_page(
            &t,
            &Plan {
                limit: 2,
                offset: 4,
                ..Default::default()
            },
        );
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
        );
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
        );
        assert_eq!(page.rows[0][1], serde_json::Value::Null);
        assert_eq!(page.rows[0][2], serde_json::Value::Null);
    }

    #[test]
    fn search_is_case_insensitive_across_columns() {
        let p = Plan {
            search: Some("ALPHA".into()),
            ..Default::default()
        };
        let page = query_page(&table(), &p);
        assert_eq!(page.total_rows, 1);
        assert_eq!(page.rows[0][0], serde_json::json!(1));
    }

    #[test]
    fn blank_search_matches_everything() {
        let p = Plan {
            search: Some("   ".into()),
            ..Default::default()
        };
        assert_eq!(query_page(&table(), &p).total_rows, 5);
    }

    #[test]
    fn search_with_no_matches_is_empty() {
        let p = Plan {
            search: Some("zzzz".into()),
            ..Default::default()
        };
        let page = query_page(&table(), &p);
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
        let page = query_page(&t, &Plan::default());
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
