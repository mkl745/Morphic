//! Sorting (M1.3 task 1.3.1, docs/architecture/05 §4.2 step 3).
//!
//! Three properties AT-07 depends on, each pinned by a test:
//!
//! 1. **Stable.** Rows that compare equal keep their incoming order, so sorting by a second
//!    column never scrambles the first. Rust's `sort_by` is stable; the permutation is built
//!    from the selection vector, so "incoming order" means the filter's order, not row id.
//! 2. **Nulls are placed, not compared.** The policy is independent of direction: `nulls: last`
//!    means last in both ascending and descending. Flipping nulls with the direction is a
//!    common surprise, and a UI chip that says "nulls last" must mean it.
//! 3. **Floats use `total_cmp`.** `-0.0`, `0.0` and NaN get a total order, so a sort cannot
//!    produce a permutation that depends on the comparator being called in a particular order.
//!    NaN sorts above every number; nulls are still governed by the policy, not by NaN.

use morphic_model::{Column, ColumnValues, Table};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;

use crate::filter::is_null;
use crate::QueryError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    #[default]
    Asc,
    Desc,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Nulls {
    First,
    #[default]
    Last,
}

/// One key of a possibly multi-field sort.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SortSpec {
    pub field: String,
    #[serde(default)]
    pub dir: Direction,
    #[serde(default)]
    pub nulls: Nulls,
}

impl SortSpec {
    pub fn asc(field: &str) -> SortSpec {
        SortSpec {
            field: field.to_string(),
            dir: Direction::Asc,
            nulls: Nulls::Last,
        }
    }

    pub fn desc(field: &str) -> SortSpec {
        SortSpec {
            field: field.to_string(),
            dir: Direction::Desc,
            nulls: Nulls::Last,
        }
    }
}

/// Cap on sort keys. A UI offers one or two; a plan asking for more is either a bug or an
/// attempt to make the comparator do unbounded work per comparison.
pub const MAX_SORT_KEYS: usize = 8;

pub(crate) fn validate(table: &Table, specs: &[SortSpec]) -> Result<(), QueryError> {
    if specs.len() > MAX_SORT_KEYS {
        return Err(QueryError::InvalidPlan(format!(
            "sort has {} keys; at most {MAX_SORT_KEYS} are allowed",
            specs.len()
        )));
    }
    for s in specs {
        crate::find_column(table, &s.field)?;
    }
    Ok(())
}

/// Sort a selection vector in place. Stable, so equal keys keep their relative order.
///
/// Public because callers that already hold a selection (a cached one, or a test checking
/// idempotence) need to re-order it without re-running the filter.
pub fn sort_selection(table: &Table, rows: &mut [usize], specs: &[SortSpec]) {
    if specs.is_empty() || rows.len() < 2 {
        return;
    }
    // Resolve columns once rather than per comparison: a 100k-row sort makes ~1.7M comparisons
    // and a name lookup in each one is the difference between hitting the budget and missing it.
    let keys: Vec<(&Column, Direction, Nulls)> = specs
        .iter()
        .filter_map(|s| {
            crate::find_column(table, &s.field)
                .ok()
                .map(|c| (c, s.dir, s.nulls))
        })
        .collect();

    rows.sort_by(|a, b| {
        for (col, dir, nulls) in &keys {
            let (an, bn) = (is_null(col, *a), is_null(col, *b));
            let ord = match (an, bn) {
                (true, true) => Ordering::Equal,
                // Null placement ignores direction on purpose.
                (true, false) => {
                    return match nulls {
                        Nulls::First => Ordering::Less,
                        Nulls::Last => Ordering::Greater,
                    }
                }
                (false, true) => {
                    return match nulls {
                        Nulls::First => Ordering::Greater,
                        Nulls::Last => Ordering::Less,
                    }
                }
                (false, false) => compare_cells(col, *a, *b),
            };
            if ord != Ordering::Equal {
                return match dir {
                    Direction::Asc => ord,
                    Direction::Desc => ord.reverse(),
                };
            }
        }
        Ordering::Equal
    });
}

/// Compare two non-null cells of the same column. Nulls are the caller's business: use the
/// [`Nulls`] policy, not this function, to place them.
pub fn compare_cells(col: &Column, a: usize, b: usize) -> Ordering {
    match &col.values {
        ColumnValues::Int64(v) => match (v.get(a), v.get(b)) {
            (Some(x), Some(y)) => x.cmp(y),
            _ => Ordering::Equal,
        },
        ColumnValues::Float64(v) => match (v.get(a), v.get(b)) {
            (Some(x), Some(y)) => x.total_cmp(y),
            _ => Ordering::Equal,
        },
        ColumnValues::Bool(v) => match (v.get(a), v.get(b)) {
            (Some(x), Some(y)) => x.cmp(y),
            _ => Ordering::Equal,
        },
        ColumnValues::Utf8(v) => match (v.get(a), v.get(b)) {
            (Some(x), Some(y)) => x.cmp(y),
            _ => Ordering::Equal,
        },
        ColumnValues::Timestamp(v) => match (v.get(a), v.get(b)) {
            (Some(x), Some(y)) => x.cmp(y),
            _ => Ordering::Equal,
        },
        ColumnValues::Null => Ordering::Equal,
    }
}
