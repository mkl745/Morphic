//! Group-by with streaming accumulators (M1.3 task 1.3.1, docs/architecture/05 §4.2 step 4).
//!
//! One pass over the selection vector. Each group holds one accumulator per requested
//! aggregation, so memory is `groups × aggs`, not `rows`. The group key is a `Vec<String>`
//! rather than a joined string, because any separator chosen for joining eventually appears
//! inside a value and silently merges two groups.
//!
//! Output order is **first appearance** in the selection, which means a sorted input produces
//! sorted groups for free and the result is deterministic without a second sort.
//!
//! The group count is capped ([`MAX_GROUPS`], matching the chart point ceiling). Excess groups
//! are still *counted* so `total_groups` and `truncated` tell the truth; they are simply not
//! accumulated. Silently returning the first 2000 groups and calling it the whole answer is the
//! failure mode this avoids.

use std::collections::{BTreeMap, HashSet};

use morphic_model::{ColumnValues, Table};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::filter::is_null;
use crate::QueryError;

/// Same ceiling as `chartData` (docs/architecture/03 §4): a chart cannot draw more points than
/// this, so materializing more groups would be work nobody can see.
pub const MAX_GROUPS: usize = 2000;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AggSpec {
    /// count | sum | avg | min | max | distinct_count
    pub op: String,
    #[serde(default)]
    pub field: Option<String>,
    /// Output column name. Defaults to `op_field`, or `op` when there is no field.
    #[serde(default)]
    pub alias: Option<String>,
}

impl AggSpec {
    pub fn new(op: &str, field: Option<&str>) -> AggSpec {
        AggSpec {
            op: op.to_string(),
            field: field.map(str::to_string),
            alias: None,
        }
    }

    /// Output column name for this aggregation. Public because a chart scene names its measure
    /// with the same string the group path uses, so the two cannot drift.
    pub fn label_public(&self) -> String {
        self.label()
    }

    fn label(&self) -> String {
        if let Some(a) = &self.alias {
            return a.clone();
        }
        match &self.field {
            Some(f) => format!("{}_{}", self.op, f),
            None => self.op.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupedRows {
    /// Group key columns first, then one column per aggregation.
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Value>>,
    /// Groups seen, including any beyond the cap.
    pub total_groups: usize,
    /// True when `total_groups` exceeds the number of rows returned.
    pub truncated: bool,
}

/// Per-group running state. `n` counts rows; `seen` counts non-null cells of the field.
#[derive(Debug, Default)]
struct Acc {
    n: usize,
    seen: usize,
    sum: f64,
    min: Option<f64>,
    max: Option<f64>,
    min_ms: Option<i64>,
    max_ms: Option<i64>,
    distinct: HashSet<String>,
}

pub(crate) fn validate(
    table: &Table,
    group_by: &[String],
    aggs: &[AggSpec],
) -> Result<(), QueryError> {
    for g in group_by {
        crate::find_column(table, g)?;
    }
    for a in aggs {
        let known = matches!(
            a.op.as_str(),
            "count" | "sum" | "avg" | "min" | "max" | "distinct_count"
        );
        if !known {
            return Err(QueryError::UnknownOp(a.op.clone()));
        }
        match &a.field {
            None if a.op == "count" => {}
            None => return Err(QueryError::FieldRequired(a.op.clone())),
            Some(name) => {
                let col = crate::find_column(table, name)?;
                if matches!(a.op.as_str(), "sum" | "avg")
                    && !matches!(
                        col.values,
                        ColumnValues::Int64(_) | ColumnValues::Float64(_)
                    )
                {
                    return Err(QueryError::NotNumeric {
                        field: col.name.clone(),
                        dtype: col.dtype.as_str().to_string(),
                    });
                }
            }
        }
    }
    Ok(())
}

pub(crate) fn execute(
    table: &Table,
    selection: &[usize],
    group_by: &[String],
    aggs: &[AggSpec],
    max_groups: usize,
    budget_ms: Option<u64>,
) -> Result<GroupedRows, QueryError> {
    execute_capped(
        table,
        selection,
        group_by,
        aggs,
        max_groups.clamp(1, MAX_GROUPS),
        budget_ms,
    )
}

/// Grouping with an explicit accumulation cap.
///
/// [`execute`] clamps to [`MAX_GROUPS`] because its callers materialize groups for display. A
/// top-N chart is different: it *displays* a few dozen bars but must *see* every category to know
/// which few dozen are largest. Clamping the intermediate groups to the output ceiling would
/// silently choose the top N from whichever categories appeared first.
pub(crate) fn execute_capped(
    table: &Table,
    selection: &[usize],
    group_by: &[String],
    aggs: &[AggSpec],
    cap: usize,
    budget_ms: Option<u64>,
) -> Result<GroupedRows, QueryError> {
    let deadline = crate::budget::Deadline::new(budget_ms);
    let cap = cap.max(1);
    let key_cols: Vec<&morphic_model::Column> = group_by
        .iter()
        .map(|g| crate::find_column(table, g))
        .collect::<Result<_, _>>()?;
    let agg_cols: Vec<Option<&morphic_model::Column>> = aggs
        .iter()
        .map(|a| match &a.field {
            None => Ok(None),
            Some(f) => crate::find_column(table, f).map(Some),
        })
        .collect::<Result<_, _>>()?;

    let mut index: BTreeMap<Vec<String>, usize> = BTreeMap::new();
    let mut keys: Vec<Vec<Value>> = Vec::new();
    let mut accs: Vec<Vec<Acc>> = Vec::new();
    let mut total_groups = 0usize;

    for (i, row) in selection.iter().enumerate() {
        if i % crate::CHECK_ROWS == 0 && i > 0 {
            deadline.check("group")?;
        }
        let key: Vec<String> = key_cols.iter().map(|c| crate::cell_text(c, *row)).collect();
        let slot = match index.get(&key) {
            Some(i) => *i,
            None => {
                total_groups += 1;
                if keys.len() >= cap {
                    continue;
                }
                let i = keys.len();
                index.insert(key, i);
                keys.push(key_cols.iter().map(|c| crate::cell_json(c, *row)).collect());
                accs.push(aggs.iter().map(|_| Acc::default()).collect());
                i
            }
        };
        for (k, spec) in aggs.iter().enumerate() {
            let acc = &mut accs[slot][k];
            acc.n += 1;
            let col = match agg_cols[k] {
                None => continue,
                Some(c) => c,
            };
            if is_null(col, *row) {
                continue;
            }
            acc.seen += 1;
            match spec.op.as_str() {
                "distinct_count" => {
                    acc.distinct.insert(crate::cell_text(col, *row));
                }
                "sum" | "avg" => {
                    if let Some(x) = number_at(col, *row) {
                        acc.sum += x;
                    }
                }
                "min" | "max" => match &col.values {
                    ColumnValues::Timestamp(v) => {
                        if let Some(ms) = v.get(*row) {
                            acc.min_ms = Some(acc.min_ms.map_or(*ms, |cur| cur.min(*ms)));
                            acc.max_ms = Some(acc.max_ms.map_or(*ms, |cur| cur.max(*ms)));
                        }
                    }
                    _ => {
                        if let Some(x) = number_at(col, *row) {
                            acc.min = Some(acc.min.map_or(x, |cur: f64| cur.min(x)));
                            acc.max = Some(acc.max.map_or(x, |cur: f64| cur.max(x)));
                        }
                    }
                },
                _ => {}
            }
        }
    }

    let mut columns: Vec<String> = group_by.to_vec();
    columns.extend(aggs.iter().map(AggSpec::label));
    let mut rows = Vec::with_capacity(keys.len());
    for (i, mut key) in keys.into_iter().enumerate() {
        for (k, spec) in aggs.iter().enumerate() {
            key.push(finish(&accs[i][k], spec));
        }
        rows.push(key);
    }
    deadline.check("group")?;
    Ok(GroupedRows {
        columns,
        rows,
        total_groups,
        truncated: total_groups > accs.len(),
    })
}

fn number_at(col: &morphic_model::Column, row: usize) -> Option<f64> {
    match &col.values {
        ColumnValues::Int64(v) => v.get(row).map(|x| *x as f64),
        ColumnValues::Float64(v) => v.get(row).copied().filter(|x| x.is_finite()),
        _ => None,
    }
}

/// An empty group renders as JSON null, never a misleading zero — the same rule the scalar
/// `aggregate` follows.
fn finish(acc: &Acc, spec: &AggSpec) -> Value {
    match spec.op.as_str() {
        "count" => serde_json::json!(if spec.field.is_none() {
            acc.n
        } else {
            acc.seen
        }),
        "distinct_count" => serde_json::json!(acc.distinct.len()),
        "sum" | "avg" => {
            if acc.seen == 0 {
                Value::Null
            } else if spec.op == "sum" {
                serde_json::json!(acc.sum)
            } else {
                serde_json::json!(acc.sum / acc.seen as f64)
            }
        }
        "min" | "max" => {
            if let (Some(lo), Some(hi)) = (acc.min_ms, acc.max_ms) {
                let ms = if spec.op == "min" { lo } else { hi };
                return Value::String(morphic_model::temporal::format_utc_ms(ms));
            }
            let picked = if spec.op == "min" { acc.min } else { acc.max };
            match picked {
                Some(x) => serde_json::json!(x),
                None => Value::Null,
            }
        }
        _ => Value::Null,
    }
}
