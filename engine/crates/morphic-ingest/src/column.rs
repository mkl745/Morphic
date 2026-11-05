//! The type ladder: raw string cells → a typed, nullable `Column` (M1.1).
//!
//! Phase 0 required **100%** of non-null cells to parse before a column was typed, which
//! made a single stray `"N/A"` collapse an entire numeric column to text. M1.1 adopts the
//! documented tolerance (docs/architecture/05 §2): the most specific type satisfying
//! `parse_ratio >= tolerance` (default 0.95) wins, and the residual cells become **null**
//! with a per-column count so the UI can report exactly what was coerced.
//!
//! Order matters: `bool` is tried before `int64` using a restricted vocabulary so that
//! `0`/`1` flags stay integers; `int64` before `float64` so whole numbers stay integral.

use morphic_model::{Column, ColumnValues, DataType};

/// A built column plus diagnostics about the inference that produced it.
#[derive(Debug, Clone)]
pub struct ColumnBuild {
    pub column: Column,
    /// Non-null cells that failed the chosen type and were set to null.
    pub coerced: usize,
    /// Fraction of non-null cells that parsed as the chosen type (1.0 for Utf8/Null).
    pub parse_ratio: f64,
}

/// Restricted boolean vocabulary. `0`/`1` are deliberately excluded.
fn as_bool(s: &str) -> Option<bool> {
    match s.trim().to_ascii_lowercase().as_str() {
        "true" | "yes" | "y" | "t" => Some(true),
        "false" | "no" | "n" | "f" => Some(false),
        _ => None,
    }
}

fn as_int(s: &str) -> Option<i64> {
    s.trim().parse::<i64>().ok()
}

/// Rejects NaN/infinite so they never enter the columnar store as silent poison.
fn as_float(s: &str) -> Option<f64> {
    let v = s.trim().parse::<f64>().ok()?;
    if v.is_finite() {
        Some(v)
    } else {
        None
    }
}

/// Infer and build one column from raw cells + a parallel null mask.
pub fn build_column(name: &str, raw: &[String], nulls: &[bool], tolerance: f64) -> ColumnBuild {
    let tol = tolerance.clamp(0.0, 1.0);
    let samples: Vec<&str> = raw
        .iter()
        .zip(nulls)
        .filter(|(_, &n)| !n)
        .map(|(s, _)| s.as_str())
        .collect();

    if samples.is_empty() {
        return ColumnBuild {
            column: Column {
                name: name.to_string(),
                dtype: DataType::Null,
                values: ColumnValues::Null,
                nulls: nulls.to_vec(),
            },
            coerced: 0,
            parse_ratio: 1.0,
        };
    }

    let total = samples.len();
    let ratio = |hits: usize| hits as f64 / total as f64;

    // --- bool ---
    let hits = samples.iter().filter(|s| as_bool(s).is_some()).count();
    if ratio(hits) >= tol {
        let mut out_nulls = nulls.to_vec();
        let mut values = Vec::with_capacity(raw.len());
        let mut coerced = 0usize;
        for (i, s) in raw.iter().enumerate() {
            if nulls[i] {
                values.push(false);
                continue;
            }
            match as_bool(s) {
                Some(b) => values.push(b),
                None => {
                    values.push(false);
                    out_nulls[i] = true;
                    coerced += 1;
                }
            }
        }
        return ColumnBuild {
            column: Column {
                name: name.to_string(),
                dtype: DataType::Bool,
                values: ColumnValues::Bool(values),
                nulls: out_nulls,
            },
            coerced,
            parse_ratio: ratio(hits),
        };
    }

    // --- int64 ---
    let hits = samples.iter().filter(|s| as_int(s).is_some()).count();
    if ratio(hits) >= tol {
        let mut out_nulls = nulls.to_vec();
        let mut values = Vec::with_capacity(raw.len());
        let mut coerced = 0usize;
        for (i, s) in raw.iter().enumerate() {
            if nulls[i] {
                values.push(0);
                continue;
            }
            match as_int(s) {
                Some(v) => values.push(v),
                None => {
                    values.push(0);
                    out_nulls[i] = true;
                    coerced += 1;
                }
            }
        }
        return ColumnBuild {
            column: Column {
                name: name.to_string(),
                dtype: DataType::Int64,
                values: ColumnValues::Int64(values),
                nulls: out_nulls,
            },
            coerced,
            parse_ratio: ratio(hits),
        };
    }

    // --- float64 ---
    let hits = samples.iter().filter(|s| as_float(s).is_some()).count();
    if ratio(hits) >= tol {
        let mut out_nulls = nulls.to_vec();
        let mut values = Vec::with_capacity(raw.len());
        let mut coerced = 0usize;
        for (i, s) in raw.iter().enumerate() {
            if nulls[i] {
                values.push(0.0);
                continue;
            }
            match as_float(s) {
                Some(v) => values.push(v),
                None => {
                    values.push(0.0);
                    out_nulls[i] = true;
                    coerced += 1;
                }
            }
        }
        return ColumnBuild {
            column: Column {
                name: name.to_string(),
                dtype: DataType::Float64,
                values: ColumnValues::Float64(values),
                nulls: out_nulls,
            },
            coerced,
            parse_ratio: ratio(hits),
        };
    }

    // --- utf8 fallback (original cells preserved verbatim: fidelity over tidiness) ---
    ColumnBuild {
        column: Column {
            name: name.to_string(),
            dtype: DataType::Utf8,
            values: ColumnValues::Utf8(raw.to_vec()),
            nulls: nulls.to_vec(),
        },
        coerced: 0,
        parse_ratio: 1.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn all_ints_stay_integral() {
        let r = raw(&["1", "2", "3"]);
        let b = build_column("x", &r, &[false; 3], 0.95);
        assert_eq!(b.column.dtype, DataType::Int64);
        assert_eq!(b.coerced, 0);
        assert_eq!(b.parse_ratio, 1.0);
    }

    #[test]
    fn tolerance_types_a_mostly_numeric_column_and_nulls_the_rest() {
        // 19/20 = 95% parse as int; the single "oops" becomes null, not a text column.
        let mut v: Vec<&str> = (0..19).map(|_| "7").collect();
        v.push("oops");
        let r = raw(&v);
        let b = build_column("x", &r, &[false; 20], 0.95);
        assert_eq!(b.column.dtype, DataType::Int64);
        assert_eq!(b.coerced, 1);
        assert!(b.column.nulls[19]);
        assert!(!b.column.nulls[0]);
    }

    #[test]
    fn below_tolerance_falls_back_to_text() {
        // 18/20 = 90% < 95% => stays Utf8, nothing coerced.
        let mut v: Vec<&str> = (0..18).map(|_| "7").collect();
        v.extend_from_slice(&["oops", "oops"]);
        let r = raw(&v);
        let b = build_column("x", &r, &[false; 20], 0.95);
        assert_eq!(b.column.dtype, DataType::Utf8);
        assert_eq!(b.coerced, 0);
    }

    #[test]
    fn zero_one_flags_are_not_booleans() {
        let r = raw(&["0", "1", "1"]);
        assert_eq!(build_column("f", &r, &[false; 3], 0.95).column.dtype, DataType::Int64);
    }

    #[test]
    fn yes_no_vocabulary_is_boolean() {
        let r = raw(&["yes", "no", "YES"]);
        let b = build_column("f", &r, &[false; 3], 0.95);
        assert_eq!(b.column.dtype, DataType::Bool);
        match b.column.values {
            ColumnValues::Bool(v) => assert_eq!(v, vec![true, false, true]),
            _ => panic!("expected bool buffer"),
        }
    }

    #[test]
    fn whitespace_padded_numbers_parse() {
        let r = raw(&[" 1 ", "2", " 3"]);
        assert_eq!(build_column("x", &r, &[false; 3], 0.95).column.dtype, DataType::Int64);
    }

    #[test]
    fn nan_and_infinity_are_rejected() {
        let r = raw(&["NaN", "inf", "-inf"]);
        assert_eq!(build_column("x", &r, &[false; 3], 0.95).column.dtype, DataType::Utf8);
    }

    #[test]
    fn mixed_int_and_float_widens_to_float() {
        let r = raw(&["1", "2.5", "3"]);
        assert_eq!(build_column("x", &r, &[false; 3], 0.95).column.dtype, DataType::Float64);
    }

    #[test]
    fn all_null_column_is_null_typed() {
        let r = raw(&["", ""]);
        let b = build_column("x", &r, &[true, true], 0.95);
        assert_eq!(b.column.dtype, DataType::Null);
    }

    #[test]
    fn utf8_values_are_preserved_verbatim() {
        let r = raw(&["  padded text  ", "other"]);
        let b = build_column("x", &r, &[false; 2], 0.95);
        match b.column.values {
            ColumnValues::Utf8(v) => assert_eq!(v[0], "  padded text  "),
            _ => panic!("expected utf8 buffer"),
        }
    }
}
