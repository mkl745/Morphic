//! # morphic-semantic
//!
//! Turns a `Table` into a `DatasetProfile`: measured **facts** (confidence 1.0) plus
//! **role inferences** with confidence + evidence (docs/architecture/05 §3).
//!
//! Phase 0 implements the core fact set and a transparent role heuristic. Timestamp
//! normalization, sampled quantiles, and the full statistical suite arrive in M1.2.

use std::collections::HashMap;

use morphic_model::{
    Column, ColumnValues, DataType, DatasetProfile, FieldProfile, FieldRole, Inference,
    Table, ValueCount,
};

const SEVERITY_VOCAB: &[&str] = &[
    "trace", "debug", "info", "notice", "warn", "warning", "error", "err", "fatal",
    "critical", "crit", "alert", "emerg", "panic",
];

/// Profile every column of a table.
pub fn profile(table: &Table) -> DatasetProfile {
    let fields = table.columns.iter().map(profile_field).collect();
    DatasetProfile {
        row_count: table.row_count,
        field_count: table.columns.len(),
        fields,
    }
}

fn cell_string(col: &Column, i: usize) -> String {
    match &col.values {
        ColumnValues::Bool(v) => v.get(i).map(|b| b.to_string()).unwrap_or_default(),
        ColumnValues::Int64(v) => v.get(i).map(|n| n.to_string()).unwrap_or_default(),
        ColumnValues::Float64(v) => v.get(i).map(|n| n.to_string()).unwrap_or_default(),
        ColumnValues::Utf8(v) => v.get(i).cloned().unwrap_or_default(),
        ColumnValues::Null => String::new(),
    }
}

fn profile_field(col: &Column) -> FieldProfile {
    let n = col.len();
    let null_count = col.nulls.iter().filter(|&&x| x).count();

    // Value frequency over non-null cells.
    let mut freq: HashMap<String, usize> = HashMap::new();
    let mut avg_len = 0.0f64;
    let mut non_null = 0usize;
    for i in 0..n {
        if col.nulls[i] {
            continue;
        }
        let s = cell_string(col, i);
        avg_len += s.len() as f64;
        non_null += 1;
        *freq.entry(s).or_insert(0) += 1;
    }
    if non_null > 0 {
        avg_len /= non_null as f64;
    }
    let distinct_count = freq.len();

    let mut top: Vec<ValueCount> = freq
        .into_iter()
        .map(|(value, count)| ValueCount { value, count })
        .collect();
    top.sort_by(|a, b| b.count.cmp(&a.count).then(a.value.cmp(&b.value)));
    top.truncate(20);

    let (min, max) = min_max(col);
    let inference = infer_role(col, distinct_count, non_null, &top, avg_len);

    FieldProfile {
        name: col.name.clone(),
        dtype: col.dtype,
        null_count,
        distinct_count,
        min,
        max,
        top_values: top,
        inference,
    }
}

fn min_max(col: &Column) -> (Option<String>, Option<String>) {
    match &col.values {
        ColumnValues::Int64(v) => {
            let nums: Vec<i64> = v
                .iter()
                .enumerate()
                .filter(|(i, _)| !col.nulls[*i])
                .map(|(_, x)| *x)
                .collect();
            (
                nums.iter().min().map(|x| x.to_string()),
                nums.iter().max().map(|x| x.to_string()),
            )
        }
        ColumnValues::Float64(v) => {
            let nums: Vec<f64> = v
                .iter()
                .enumerate()
                .filter(|(i, _)| !col.nulls[*i])
                .map(|(_, x)| *x)
                .filter(|x| !x.is_nan())
                .collect();
            let min = nums.iter().cloned().fold(None::<f64>, |acc, x| {
                Some(match acc {
                    Some(a) if a < x => a,
                    _ => x,
                })
            });
            let max = nums.iter().cloned().fold(None::<f64>, |acc, x| {
                Some(match acc {
                    Some(a) if a > x => a,
                    _ => x,
                })
            });
            (min.map(|x| x.to_string()), max.map(|x| x.to_string()))
        }
        ColumnValues::Utf8(v) => {
            let strs: Vec<&String> = v
                .iter()
                .enumerate()
                .filter(|(i, _)| !col.nulls[*i])
                .map(|(_, x)| x)
                .collect();
            (
                strs.iter().min().map(|x| x.to_string()),
                strs.iter().max().map(|x| x.to_string()),
            )
        }
        _ => (None, None),
    }
}

fn looks_temporal(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 10
        && b[0..4].iter().all(|c| c.is_ascii_digit())
        && b[4] == b'-'
        && b[5..7].iter().all(|c| c.is_ascii_digit())
        && b[7] == b'-'
        && b[8..10].iter().all(|c| c.is_ascii_digit())
}

fn infer_role(
    col: &Column,
    distinct: usize,
    non_null: usize,
    top: &[ValueCount],
    avg_len: f64,
) -> Inference {
    // Severity: categorical values drawn from the level vocabulary.
    if col.dtype == DataType::Utf8 && !top.is_empty() {
        let all_sev = top
            .iter()
            .all(|vc| SEVERITY_VOCAB.contains(&vc.value.to_ascii_lowercase().as_str()));
        if all_sev {
            return Inference {
                role: FieldRole::Severity,
                confidence: 0.97,
                evidence: vec![format!(
                    "'{}' top values match the severity vocabulary",
                    col.name
                )],
            };
        }
    }

    // Temporal: ISO-8601-looking strings.
    if col.dtype == DataType::Utf8 && non_null > 0 {
        let sample: Vec<&ValueCount> = top.iter().take(10).collect();
        let hits = sample.iter().filter(|vc| looks_temporal(&vc.value)).count();
        if !sample.is_empty() && hits * 10 >= sample.len() * 9 {
            return Inference {
                role: FieldRole::Temporal,
                confidence: 0.9,
                evidence: vec![format!("'{}' values look like ISO-8601 timestamps", col.name)],
            };
        }
    }

    // Identifier: near-unique values.
    if non_null > 0 && (distinct as f64) / (non_null as f64) >= 0.99 && non_null >= 5 {
        if matches!(col.dtype, DataType::Utf8 | DataType::Int64) {
            return Inference {
                role: FieldRole::Identifier,
                confidence: 0.9,
                evidence: vec![format!("'{}' is {:.1}% unique", col.name, 100.0 * distinct as f64 / non_null as f64)],
            };
        }
    }

    // Measure: numeric, not an identifier.
    if matches!(col.dtype, DataType::Int64 | DataType::Float64) {
        return Inference {
            role: FieldRole::Measure,
            confidence: 0.85,
            evidence: vec![format!("'{}' is numeric ({})", col.name, col.dtype.as_str())],
        };
    }

    // Text: long strings.
    if col.dtype == DataType::Utf8 && avg_len > 40.0 {
        return Inference {
            role: FieldRole::Text,
            confidence: 0.7,
            evidence: vec![format!("'{}' averages {:.0} characters", col.name, avg_len)],
        };
    }

    // Dimension: low-cardinality categorical.
    if col.dtype == DataType::Utf8 && distinct <= 50 {
        return Inference {
            role: FieldRole::Dimension,
            confidence: 0.8,
            evidence: vec![format!("'{}' has {} distinct values", col.name, distinct)],
        };
    }

    Inference {
        role: FieldRole::Unknown,
        confidence: 0.0,
        evidence: vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use morphic_model::{Column, ColumnValues, Table};

    fn utf8_col(name: &str, vals: &[&str]) -> Column {
        Column {
            name: name.into(),
            dtype: DataType::Utf8,
            values: ColumnValues::Utf8(vals.iter().map(|s| s.to_string()).collect()),
            nulls: vec![false; vals.len()],
        }
    }

    #[test]
    fn detects_severity() {
        let t = Table {
            columns: vec![utf8_col("level", &["ERROR", "INFO", "WARN", "ERROR", "INFO"])],
            row_count: 5,
        };
        let p = profile(&t);
        assert_eq!(p.fields[0].inference.role, FieldRole::Severity);
    }

    #[test]
    fn detects_temporal() {
        let t = Table {
            columns: vec![utf8_col(
                "time",
                &[
                    "2026-11-05T10:00:00Z",
                    "2026-11-05T10:01:00Z",
                    "2026-11-05T10:02:00Z",
                ],
            )],
            row_count: 3,
        };
        let p = profile(&t);
        assert_eq!(p.fields[0].inference.role, FieldRole::Temporal);
    }

    #[test]
    fn numeric_is_measure() {
        let t = Table {
            columns: vec![Column {
                name: "amount".into(),
                dtype: DataType::Float64,
                values: ColumnValues::Float64(vec![1.0, 2.5, 3.0, 2.5]),
                nulls: vec![false; 4],
            }],
            row_count: 4,
        };
        let p = profile(&t);
        assert_eq!(p.fields[0].inference.role, FieldRole::Measure);
        assert_eq!(p.fields[0].distinct_count, 3);
    }
}
