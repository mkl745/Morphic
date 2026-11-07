//! The typed filter tree (M1.3 task 1.3.1, docs/architecture/05 §4.1–4.2).
//!
//! # Why the tree lives here and not in `morphic-schema`
//!
//! The dependency rule in docs/architecture/01 §3 is explicit: `morphic-query` may depend on
//! `morphic-model` and must never know the UI schema. So the *execution* tree lives here, and
//! [`Filter::from_json`] accepts the flat wire node (`{op, field, value, args}`) that the UI
//! schema serializes, without importing the schema crate. `tests` pins every operator name the
//! schema documents, so the two grammars cannot drift silently.
//!
//! # Null semantics, stated rather than inherited
//!
//! A comparison against a null cell is **false**, for every operator including `neq`. This is
//! not SQL's three-valued logic: a filter chip in a UI must either match a row or not, and
//! "unknown" has no rendering. `is_null` / `not_null` are the explicit way to ask about nulls.
//! `not` therefore complements the *match*, so `not(eq)` includes null rows — which is why the
//! evidence for a negated filter says so.
//!
//! # Types come from the column, not the JSON
//!
//! A bound is coerced into the column's domain: an `Int64` column compares numerically even if
//! the bound arrived as `"3"`, and a `Timestamp` column compares in canonical UTC. A bound that
//! cannot be coerced is a plan error with an actionable message, never a silent no-match.

use morphic_model::temporal::format_utc_ms;
use morphic_model::{Column, ColumnValues, Table};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::QueryError;

/// The closed comparison set. Anything else is a plan error, never an interpreted string.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Compare {
    Eq,
    Neq,
    Gt,
    Gte,
    Lt,
    Lte,
}

impl Compare {
    fn parse(s: &str) -> Option<Compare> {
        match s {
            "eq" => Some(Compare::Eq),
            "neq" => Some(Compare::Neq),
            "gt" => Some(Compare::Gt),
            "gte" => Some(Compare::Gte),
            "lt" => Some(Compare::Lt),
            "lte" => Some(Compare::Lte),
            _ => None,
        }
    }

    fn applies(self, ord: std::cmp::Ordering) -> bool {
        use std::cmp::Ordering::{Equal, Greater, Less};
        match self {
            Compare::Eq => ord == Equal,
            Compare::Neq => ord != Equal,
            Compare::Gt => ord == Greater,
            Compare::Gte => ord != Less,
            Compare::Lt => ord == Less,
            Compare::Lte => ord != Greater,
        }
    }
}

/// A validated filter tree. Construction validates operator names and arity; [`Filter::validate`]
/// additionally checks fields against a table, which is a separate step because a plan may be
/// validated before its dataset is loaded.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Filter {
    And(Vec<Filter>),
    Or(Vec<Filter>),
    Not(Box<Filter>),
    Compare {
        field: String,
        cmp: Compare,
        value: Value,
    },
    In {
        field: String,
        values: Vec<Value>,
    },
    Contains {
        field: String,
        text: String,
    },
    IsNull {
        field: String,
    },
    NotNull {
        field: String,
    },
}

/// Guards against a filter deep enough to overflow the stack during evaluation. The UI cannot
/// produce anything close to this; a hostile plan could.
pub const MAX_FILTER_DEPTH: usize = 32;
/// Guards against a plan whose node count alone is the attack.
pub const MAX_FILTER_NODES: usize = 512;

impl Filter {
    /// Parse the flat wire node the UI schema serializes: `{op, field?, value?, args?}`.
    pub fn from_json(node: &Value) -> Result<Filter, QueryError> {
        let mut nodes = 0usize;
        Filter::parse_at(node, 0, &mut nodes)
    }

    fn parse_at(node: &Value, depth: usize, nodes: &mut usize) -> Result<Filter, QueryError> {
        if depth > MAX_FILTER_DEPTH {
            return Err(QueryError::InvalidPlan(format!(
                "filter nesting exceeds {MAX_FILTER_DEPTH} levels"
            )));
        }
        *nodes += 1;
        if *nodes > MAX_FILTER_NODES {
            return Err(QueryError::InvalidPlan(format!(
                "filter exceeds {MAX_FILTER_NODES} nodes"
            )));
        }
        let op = node
            .get("op")
            .and_then(Value::as_str)
            .ok_or_else(|| QueryError::InvalidPlan("filter node has no 'op'".into()))?;
        let field = || -> Result<String, QueryError> {
            node.get("field")
                .and_then(Value::as_str)
                .map(str::to_string)
                .ok_or_else(|| QueryError::InvalidPlan(format!("filter '{op}' requires a field")))
        };
        let mut args = || -> Result<Vec<Filter>, QueryError> {
            match node.get("args") {
                None | Some(Value::Null) => Ok(Vec::new()),
                Some(Value::Array(items)) => items
                    .iter()
                    .map(|n| Filter::parse_at(n, depth + 1, nodes))
                    .collect(),
                Some(_) => Err(QueryError::InvalidPlan("'args' must be an array".into())),
            }
        };

        match op {
            "and" | "or" => {
                let kids = args()?;
                if kids.is_empty() {
                    return Err(QueryError::InvalidPlan(format!(
                        "'{op}' needs at least one arg"
                    )));
                }
                Ok(if op == "and" {
                    Filter::And(kids)
                } else {
                    Filter::Or(kids)
                })
            }
            "not" => {
                let mut kids = args()?;
                if kids.len() != 1 {
                    return Err(QueryError::InvalidPlan(
                        "'not' takes exactly one arg".into(),
                    ));
                }
                Ok(Filter::Not(Box::new(kids.remove(0))))
            }
            "is_null" | "not_null" => {
                let f = field()?;
                Ok(if op == "is_null" {
                    Filter::IsNull { field: f }
                } else {
                    Filter::NotNull { field: f }
                })
            }
            "contains" => {
                let f = field()?;
                let text = node
                    .get("value")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        QueryError::InvalidPlan("'contains' requires a string value".into())
                    })?
                    .to_string();
                Ok(Filter::Contains { field: f, text })
            }
            "in" => {
                let f = field()?;
                let values = match node.get("value") {
                    Some(Value::Array(items)) => items.clone(),
                    _ => {
                        return Err(QueryError::InvalidPlan(
                            "'in' requires an array value".into(),
                        ))
                    }
                };
                if values.is_empty() {
                    return Err(QueryError::InvalidPlan(
                        "'in' needs at least one value".into(),
                    ));
                }
                Ok(Filter::In { field: f, values })
            }
            other => {
                let cmp = Compare::parse(other).ok_or_else(|| {
                    QueryError::InvalidPlan(format!("unknown filter operator '{other}'"))
                })?;
                let f = field()?;
                let value = node
                    .get("value")
                    .filter(|v| !v.is_null())
                    .cloned()
                    .ok_or_else(|| {
                        QueryError::InvalidPlan(format!("'{other}' requires a non-null value"))
                    })?;
                Ok(Filter::Compare {
                    field: f,
                    cmp,
                    value,
                })
            }
        }
    }

    /// Every field this tree reads, in first-use order. Used for validation and for the UI's
    /// "which columns does this filter touch" display.
    pub fn fields(&self) -> Vec<&str> {
        let mut out = Vec::new();
        self.collect_fields(&mut out);
        out
    }

    fn collect_fields<'a>(&'a self, out: &mut Vec<&'a str>) {
        match self {
            Filter::And(kids) | Filter::Or(kids) => {
                for k in kids {
                    k.collect_fields(out);
                }
            }
            Filter::Not(k) => k.collect_fields(out),
            Filter::Compare { field, .. }
            | Filter::In { field, .. }
            | Filter::Contains { field, .. }
            | Filter::IsNull { field }
            | Filter::NotNull { field } => {
                if !out.contains(&field.as_str()) {
                    out.push(field.as_str());
                }
            }
        }
    }

    /// Check every referenced field exists, and every bound coerces into its column's domain.
    /// Doing this once, before scanning rows, turns a bad plan into one clear error instead of
    /// a silently empty result.
    pub fn validate(&self, table: &Table) -> Result<(), QueryError> {
        for name in self.fields() {
            let col = crate::find_column(table, name)?;
            self.check_bounds(col)?;
        }
        Ok(())
    }

    fn check_bounds(&self, col: &Column) -> Result<(), QueryError> {
        match self {
            Filter::And(kids) | Filter::Or(kids) => {
                for k in kids {
                    k.check_bounds(col)?;
                }
            }
            Filter::Not(k) => k.check_bounds(col)?,
            Filter::Compare { field, value, .. } => {
                if field == &col.name {
                    Bound::coerce(col, value)?;
                }
            }
            Filter::In { field, values } => {
                if field == &col.name {
                    for v in values {
                        Bound::coerce(col, v)?;
                    }
                }
            }
            Filter::Contains { .. } | Filter::IsNull { .. } | Filter::NotNull { .. } => {}
        }
        Ok(())
    }

    /// True when `row` satisfies the tree. Callers must have run [`Filter::validate`] first;
    /// an unknown field here reads as null rather than panicking, so a stale plan degrades to
    /// "no match" instead of taking the process down.
    pub fn matches(&self, table: &Table, row: usize) -> bool {
        match self {
            // Short-circuit: `and` stops at the first false, `or` at the first true.
            Filter::And(kids) => kids.iter().all(|k| k.matches(table, row)),
            Filter::Or(kids) => kids.iter().any(|k| k.matches(table, row)),
            Filter::Not(k) => !k.matches(table, row),
            Filter::IsNull { field } => match crate::find_column(table, field) {
                Ok(c) => is_null(c, row),
                Err(_) => true,
            },
            Filter::NotNull { field } => match crate::find_column(table, field) {
                Ok(c) => !is_null(c, row),
                Err(_) => false,
            },
            Filter::Contains { field, text } => match crate::find_column(table, field) {
                Ok(c) if !is_null(c, row) => crate::cell_text(c, row)
                    .to_lowercase()
                    .contains(&text.to_lowercase()),
                _ => false,
            },
            Filter::In { field, values } => match crate::find_column(table, field) {
                Ok(c) if !is_null(c, row) => values.iter().any(|v| {
                    Bound::coerce(c, v)
                        .map(|b| b.cmp_cell(c, row) == Some(std::cmp::Ordering::Equal))
                        .unwrap_or(false)
                }),
                _ => false,
            },
            Filter::Compare { field, cmp, value } => match crate::find_column(table, field) {
                Ok(c) if !is_null(c, row) => Bound::coerce(c, value)
                    .ok()
                    .and_then(|b| b.cmp_cell(c, row))
                    .map(|ord| cmp.applies(ord))
                    .unwrap_or(false),
                _ => false,
            },
        }
    }
}

pub(crate) fn is_null(col: &Column, row: usize) -> bool {
    col.nulls.get(row).copied().unwrap_or(true)
}

/// A bound coerced into a column's domain. Ordering is the *cell's* ordering relative to the
/// bound, so `cmp_cell` reads as "cell ? bound".
#[derive(Debug, Clone)]
enum Bound {
    Int(i64),
    Float(f64),
    Bool(bool),
    Text(String),
}

impl Bound {
    fn coerce(col: &Column, value: &Value) -> Result<Bound, QueryError> {
        let bad = || {
            QueryError::InvalidPlan(format!(
                "value {value} cannot be compared with field '{}' of type {}",
                col.name,
                col.dtype.as_str()
            ))
        };
        match &col.values {
            ColumnValues::Int64(_) => match value {
                Value::Number(n) => n.as_i64().map(Bound::Int).ok_or_else(bad),
                Value::String(s) => s.trim().parse::<i64>().map(Bound::Int).map_err(|_| bad()),
                _ => Err(bad()),
            },
            ColumnValues::Float64(_) => match value {
                Value::Number(n) => n
                    .as_f64()
                    .filter(|x| x.is_finite())
                    .map(Bound::Float)
                    .ok_or_else(bad),
                Value::String(s) => s
                    .trim()
                    .parse::<f64>()
                    .ok()
                    .filter(|x| x.is_finite())
                    .map(Bound::Float)
                    .ok_or_else(bad),
                _ => Err(bad()),
            },
            ColumnValues::Bool(_) => match value {
                Value::Bool(b) => Ok(Bound::Bool(*b)),
                Value::String(s) => match s.trim().to_ascii_lowercase().as_str() {
                    "true" => Ok(Bound::Bool(true)),
                    "false" => Ok(Bound::Bool(false)),
                    _ => Err(bad()),
                },
                _ => Err(bad()),
            },
            ColumnValues::Timestamp(_) => match value {
                Value::Number(n) => n
                    .as_i64()
                    .map(|ms| Bound::Text(format_utc_ms(ms)))
                    .ok_or_else(bad),
                Value::String(s) => canonical_timestamp(s).map(Bound::Text).ok_or_else(|| {
                    QueryError::InvalidPlan(format!(
                        "timestamp bound '{s}' for field '{}' must be UTC milliseconds or an \
                         ISO-8601 UTC string (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS.mmmZ)",
                        col.name
                    ))
                }),
                _ => Err(bad()),
            },
            ColumnValues::Utf8(_) | ColumnValues::Null => Ok(Bound::Text(match value {
                Value::String(s) => s.clone(),
                Value::Null => String::new(),
                other => other.to_string(),
            })),
        }
    }

    /// The cell's ordering relative to this bound, or `None` when the cell is null.
    fn cmp_cell(&self, col: &Column, row: usize) -> Option<std::cmp::Ordering> {
        if is_null(col, row) {
            return None;
        }
        match (self, &col.values) {
            (Bound::Int(b), ColumnValues::Int64(v)) => v.get(row).map(|x| x.cmp(b)),
            (Bound::Float(b), ColumnValues::Float64(v)) => v.get(row).map(|x| x.total_cmp(b)),
            // An integer column can meet a float bound through `in` on a mixed plan.
            (Bound::Float(b), ColumnValues::Int64(v)) => {
                v.get(row).map(|x| (*x as f64).total_cmp(b))
            }
            (Bound::Int(b), ColumnValues::Float64(v)) => {
                v.get(row).map(|x| x.total_cmp(&(*b as f64)))
            }
            (Bound::Bool(b), ColumnValues::Bool(v)) => v.get(row).map(|x| x.cmp(b)),
            (Bound::Text(b), ColumnValues::Utf8(v)) => {
                v.get(row).map(|x| x.as_str().cmp(b.as_str()))
            }
            (Bound::Text(b), ColumnValues::Timestamp(v)) => v
                .get(row)
                .map(|ms| format_utc_ms(*ms).as_str().cmp(b.as_str())),
            _ => None,
        }
    }
}

/// Canonical UTC text for a timestamp bound. Comparing canonical strings is the same as
/// comparing instants because `format_utc_ms` is fixed-width, and it avoids pulling a date
/// parser into a crate that is not allowed to depend on ingestion.
///
/// A date-only bound means **midnight UTC at the start of that day**. The UI sends explicit
/// bounds when it means the end of a day; guessing "23:59:59.999" here would silently change
/// what a `lte` chip means.
fn canonical_timestamp(s: &str) -> Option<String> {
    let t = s.trim();
    if let Ok(ms) = t.parse::<i64>() {
        return Some(format_utc_ms(ms));
    }
    let b = t.as_bytes();
    let date_shape = b.len() >= 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b[..4].iter().all(u8::is_ascii_digit)
        && b[5..7].iter().all(u8::is_ascii_digit)
        && b[8..10].iter().all(u8::is_ascii_digit);
    if !date_shape {
        return None;
    }
    if t.len() == 10 {
        return Some(format!("{t}T00:00:00.000Z"));
    }
    // Already canonical: YYYY-MM-DDTHH:MM:SS.mmmZ
    if t.len() == 24 && t.ends_with('Z') && b[10] == b'T' {
        return Some(t.to_string());
    }
    // ISO with seconds but no millis.
    if t.len() == 20 && t.ends_with('Z') && b[10] == b'T' {
        return Some(format!("{}.000Z", &t[..19]));
    }
    None
}

/// A filter with every column reference and bound resolved **once**, before the scan.
///
/// This is not a micro-optimization. [`Filter::matches`] looks columns up by name and re-coerces
/// its bounds for every row; over 100k rows and a 10-column table that is millions of string
/// comparisons and allocations charged to a query whose target is 150 ms. Compiling turns the
/// per-row work into an index dereference and a numeric comparison.
pub(crate) struct Compiled<'t> {
    root: Node<'t>,
}

enum Node<'t> {
    And(Vec<Node<'t>>),
    Or(Vec<Node<'t>>),
    Not(Box<Node<'t>>),
    Compare {
        col: &'t Column,
        cmp: Compare,
        bound: Bound,
    },
    In {
        col: &'t Column,
        bounds: Vec<Bound>,
    },
    Contains {
        col: &'t Column,
        needle: String,
    },
    IsNull {
        col: &'t Column,
    },
    NotNull {
        col: &'t Column,
    },
}

impl<'t> Compiled<'t> {
    pub(crate) fn new(filter: &Filter, table: &'t Table) -> Result<Compiled<'t>, QueryError> {
        Ok(Compiled {
            root: Node::build(filter, table)?,
        })
    }

    pub(crate) fn matches(&self, row: usize) -> bool {
        self.root.matches(row)
    }
}

impl<'t> Node<'t> {
    fn build(filter: &Filter, table: &'t Table) -> Result<Node<'t>, QueryError> {
        Ok(match filter {
            Filter::And(kids) => Node::And(
                kids.iter()
                    .map(|k| Node::build(k, table))
                    .collect::<Result<_, _>>()?,
            ),
            Filter::Or(kids) => Node::Or(
                kids.iter()
                    .map(|k| Node::build(k, table))
                    .collect::<Result<_, _>>()?,
            ),
            Filter::Not(k) => Node::Not(Box::new(Node::build(k, table)?)),
            Filter::Compare { field, cmp, value } => {
                let col = crate::find_column(table, field)?;
                Node::Compare {
                    col,
                    cmp: *cmp,
                    bound: Bound::coerce(col, value)?,
                }
            }
            Filter::In { field, values } => {
                let col = crate::find_column(table, field)?;
                Node::In {
                    col,
                    bounds: values
                        .iter()
                        .map(|v| Bound::coerce(col, v))
                        .collect::<Result<_, _>>()?,
                }
            }
            Filter::Contains { field, text } => Node::Contains {
                col: crate::find_column(table, field)?,
                needle: text.to_lowercase(),
            },
            Filter::IsNull { field } => Node::IsNull {
                col: crate::find_column(table, field)?,
            },
            Filter::NotNull { field } => Node::NotNull {
                col: crate::find_column(table, field)?,
            },
        })
    }

    fn matches(&self, row: usize) -> bool {
        match self {
            Node::And(kids) => kids.iter().all(|k| k.matches(row)),
            Node::Or(kids) => kids.iter().any(|k| k.matches(row)),
            Node::Not(k) => !k.matches(row),
            Node::IsNull { col } => is_null(col, row),
            Node::NotNull { col } => !is_null(col, row),
            Node::Contains { col, needle } => {
                !is_null(col, row) && crate::cell_text(col, row).to_lowercase().contains(needle)
            }
            Node::In { col, bounds } => {
                !is_null(col, row)
                    && bounds
                        .iter()
                        .any(|b| b.cmp_cell(col, row) == Some(std::cmp::Ordering::Equal))
            }
            Node::Compare { col, cmp, bound } => {
                !is_null(col, row)
                    && bound
                        .cmp_cell(col, row)
                        .map(|ord| cmp.applies(ord))
                        .unwrap_or(false)
            }
        }
    }
}
