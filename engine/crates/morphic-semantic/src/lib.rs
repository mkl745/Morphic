//! # morphic-semantic
//!
//! Turns a `Table` into a `DatasetProfile`: measured **facts** (confidence 1.0) plus
//! **role inferences** with confidence + evidence (docs/architecture/05 §3).
//!
//! M1.1 adds normalized-timestamp facts and distribution statistics (mean, population
//! standard deviation, p50/p95/p99). Quantiles are exact for small columns and estimated
//! from a deterministic systematic sample above [`QUANTILE_SAMPLE_BUDGET`]; the `sampled`
//! flag keeps an estimate from being presented as a measurement.

use std::collections::HashMap;

use morphic_model::temporal::format_utc_ms;
use morphic_model::{
    Column, ColumnValues, DataType, DatasetProfile, FieldProfile, FieldRole, Inference, NumericStats,
    Table, ValueCount,
};

/// Above this many non-null values, quantiles are estimated from a systematic sample.
/// Mean and standard deviation always use the full population (single pass, no sort).
pub const QUANTILE_SAMPLE_BUDGET: usize = 100_000;

const SEVERITY_VOCAB: &[&str] = &[
    "trace", "debug", "info", "notice", "warn", "warning", "error", "err", "fatal", "critical",
    "crit", "alert", "emerg", "panic",
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
        ColumnValues::Timestamp(v) => v.get(i).map(|ms| format_utc_ms(*ms)).unwrap_or_default(),
        ColumnValues::Null => String::new(),
    }
}

/// Non-null, finite numeric values of a column. Timestamps participate as UTC millis so
/// they get a real distribution (min/max/quantiles) without becoming "measures".
fn numeric_values(col: &Column) -> Vec<f64> {
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
        ColumnValues::Timestamp(v) => v
            .iter()
            .enumerate()
            .filter(|(i, _)| keep(*i))
            .map(|(_, x)| *x as f64)
            .collect(),
        _ => Vec::new(),
    }
}

/// Linear-interpolation quantile (the "type 7" definition) over a **sorted** sample.
fn quantile_sorted(sorted: &[f64], q: f64) -> f64 {
    if sorted.len() == 1 {
        return sorted[0];
    }
    let pos = q * (sorted.len() - 1) as f64;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    if lo == hi {
        sorted[lo]
    } else {
        sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo as f64)
    }
}

/// Distribution facts. `None` when the column has no usable numeric values.
fn numeric_stats(values: &[f64]) -> Option<NumericStats> {
    let count = values.len();
    if count == 0 {
        return None;
    }
    let mean = values.iter().sum::<f64>() / count as f64;
    // Two-pass population variance: more stable than E[x^2] - E[x]^2.
    let var = values.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / count as f64;
    let std_dev = if count < 2 { 0.0 } else { var.sqrt() };

    let sample: Vec<f64> = if count > QUANTILE_SAMPLE_BUDGET {
        let step = count.div_ceil(QUANTILE_SAMPLE_BUDGET);
        values.iter().step_by(step).copied().collect()
    } else {
        values.to_vec()
    };
    let sample_size = sample.len();
    let mut sorted = sample;
    sorted.sort_by(f64::total_cmp);

    Some(NumericStats {
        count,
        mean,
        std_dev,
        p50: quantile_sorted(&sorted, 0.50),
        p95: quantile_sorted(&sorted, 0.95),
        p99: quantile_sorted(&sorted, 0.99),
        sampled: sample_size < count,
        sample_size,
    })
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
    let stats = numeric_stats(&numeric_values(col));
    let inference = infer_role(col, distinct_count, non_null, &top, avg_len);

    FieldProfile {
        name: col.name.clone(),
        dtype: col.dtype,
        null_count,
        distinct_count,
        min,
        max,
        top_values: top,
        stats,
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
        ColumnValues::Timestamp(v) => {
            let vals: Vec<i64> = v
                .iter()
                .enumerate()
                .filter(|(i, _)| !col.nulls[*i])
                .map(|(_, x)| *x)
                .collect();
            (
                vals.iter().min().map(|ms| format_utc_ms(*ms)),
                vals.iter().max().map(|ms| format_utc_ms(*ms)),
            )
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
    // Temporal by construction: ingestion already validated and normalized these values to
    // UTC, so this rests on a measured fact rather than a string-shape heuristic.
    if col.dtype == DataType::Timestamp {
        return Inference {
            role: FieldRole::Temporal,
            confidence: 0.99,
            evidence: vec![format!(
                "'{}' was parsed and normalized to UTC timestamps at import",
                col.name
            )],
        };
    }

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
                evidence: vec![format!(
                    "'{}' values look like ISO-8601 timestamps",
                    col.name
                )],
            };
        }
    }

    // Identifier: near-unique values.
    if non_null >= 5
        && (distinct as f64) / (non_null as f64) >= 0.99
        && matches!(col.dtype, DataType::Utf8 | DataType::Int64)
    {
        return Inference {
            role: FieldRole::Identifier,
            confidence: 0.9,
            evidence: vec![format!(
                "'{}' is {:.1}% unique",
                col.name,
                100.0 * distinct as f64 / non_null as f64
            )],
        };
    }

    // Measure: numeric, not an identifier.
    if matches!(col.dtype, DataType::Int64 | DataType::Float64) {
        return Inference {
            role: FieldRole::Measure,
            confidence: 0.85,
            evidence: vec![format!(
                "'{}' is numeric ({})",
                col.name,
                col.dtype.as_str()
            )],
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
            columns: vec![utf8_col(
                "level",
                &["ERROR", "INFO", "WARN", "ERROR", "INFO"],
            )],
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

    // --- M1.1 task 1.1.2: distribution facts + normalized timestamps ---

    fn f64_col(name: &str, vals: &[f64], nulls: &[bool]) -> Column {
        Column {
            name: name.into(),
            dtype: DataType::Float64,
            values: ColumnValues::Float64(vals.to_vec()),
            nulls: nulls.to_vec(),
        }
    }

    fn ts_col(name: &str, vals: &[i64]) -> Column {
        Column {
            name: name.into(),
            dtype: DataType::Timestamp,
            values: ColumnValues::Timestamp(vals.to_vec()),
            nulls: vec![false; vals.len()],
        }
    }

    fn stats_of(col: &Column) -> NumericStats {
        let t = Table { columns: vec![col.clone()], row_count: col.len() };
        profile(&t).fields[0].stats.clone().expect("expected stats")
    }

    #[test]
    fn quantiles_use_linear_interpolation() {
        // 1..=10: p50 = 5.5, p95 = 9.55, p99 = 9.91 (type-7 definition).
        let vals: Vec<f64> = (1..=10).map(|v| v as f64).collect();
        let s = stats_of(&f64_col("x", &vals, &vec![false; 10]));
        assert!((s.p50 - 5.5).abs() < 1e-9, "{}", s.p50);
        assert!((s.p95 - 9.55).abs() < 1e-9, "{}", s.p95);
        assert!((s.p99 - 9.91).abs() < 1e-9, "{}", s.p99);
        assert!((s.mean - 5.5).abs() < 1e-9);
        assert_eq!(s.count, 10);
        assert!(!s.sampled);
        assert_eq!(s.sample_size, 10);
    }

    #[test]
    fn std_dev_is_population_not_sample() {
        // Values 2 and 4: mean 3, population variance 1, population sd 1 (sample sd would be ~1.414).
        let s = stats_of(&f64_col("x", &[2.0, 4.0], &[false, false]));
        assert!((s.mean - 3.0).abs() < 1e-9);
        assert!((s.std_dev - 1.0).abs() < 1e-9, "{}", s.std_dev);
    }

    #[test]
    fn single_value_has_zero_deviation() {
        let s = stats_of(&f64_col("x", &[7.0], &[false]));
        assert_eq!(s.std_dev, 0.0);
        assert_eq!(s.p50, 7.0);
        assert_eq!(s.p99, 7.0);
    }

    #[test]
    fn nulls_are_excluded_from_facts() {
        let s = stats_of(&f64_col("x", &[1.0, 999.0, 3.0], &[false, true, false]));
        assert_eq!(s.count, 2);
        assert!((s.mean - 2.0).abs() < 1e-9);
        assert_eq!(s.p99, 3.0);
    }

    #[test]
    fn non_finite_values_are_excluded() {
        let s = stats_of(&f64_col(
            "x",
            &[1.0, f64::NAN, 3.0, f64::INFINITY],
            &[false; 4],
        ));
        assert_eq!(s.count, 2);
        assert!(s.mean.is_finite());
    }

    #[test]
    fn all_null_column_has_no_stats() {
        let t = Table {
            columns: vec![f64_col("x", &[0.0, 0.0], &[true, true])],
            row_count: 2,
        };
        assert!(profile(&t).fields[0].stats.is_none());
    }

    #[test]
    fn text_column_has_no_stats() {
        let t = Table { columns: vec![utf8_col("s", &["a", "b"])], row_count: 2 };
        assert!(profile(&t).fields[0].stats.is_none());
    }

    #[test]
    fn large_column_marks_quantiles_as_sampled() {
        let n = QUANTILE_SAMPLE_BUDGET + 5_000;
        let vals: Vec<f64> = (0..n).map(|v| v as f64).collect();
        let s = stats_of(&f64_col("x", &vals, &vec![false; n]));
        assert_eq!(s.count, n);
        assert!(s.sampled, "quantiles above the budget must be labelled estimated");
        assert!(s.sample_size < n);
        assert!(s.sample_size <= QUANTILE_SAMPLE_BUDGET);
        // Mean still uses the full population, so it is exact.
        assert!((s.mean - (n - 1) as f64 / 2.0).abs() < 1e-6);
        // A monotonic sequence sampled systematically still brackets the true median.
        assert!((s.p50 - (n - 1) as f64 / 2.0).abs() / (n as f64) < 0.01);
    }

    #[test]
    fn timestamp_role_rests_on_the_normalized_type() {
        let t = Table {
            columns: vec![ts_col("when", &[0, 86_400_000, 172_800_000])],
            row_count: 3,
        };
        let p = profile(&t);
        let f = &p.fields[0];
        assert_eq!(f.dtype, DataType::Timestamp);
        assert_eq!(f.inference.role, FieldRole::Temporal);
        assert!(f.inference.confidence > 0.95);
    }

    #[test]
    fn timestamp_min_max_are_human_readable_utc() {
        let t = Table {
            columns: vec![ts_col("when", &[1_700_000_000_000, 0, -1])],
            row_count: 3,
        };
        let f = &profile(&t).fields[0];
        assert_eq!(f.min.as_deref(), Some("1969-12-31T23:59:59.999Z"));
        assert_eq!(f.max.as_deref(), Some("2023-11-14T22:13:20.000Z"));
    }

    #[test]
    fn timestamps_get_stats_but_are_not_measures() {
        let t = Table {
            columns: vec![ts_col("when", &[0, 1000, 2000])],
            row_count: 3,
        };
        let f = &profile(&t).fields[0];
        let s = f.stats.as_ref().expect("timestamps have a distribution");
        assert_eq!(s.count, 3);
        assert!((s.mean - 1000.0).abs() < 1e-9);
        assert_ne!(f.inference.role, FieldRole::Measure);
    }

    #[test]
    fn timestamp_cells_render_as_iso_in_top_values() {
        let t = Table { columns: vec![ts_col("when", &[0, 0, 1000])], row_count: 3 };
        let f = &profile(&t).fields[0];
        assert_eq!(f.top_values[0].value, "1970-01-01T00:00:00.000Z");
        assert_eq!(f.top_values[0].count, 2);
        assert_eq!(f.distinct_count, 2);
    }
}
