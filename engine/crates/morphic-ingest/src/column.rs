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
    /// A reportable decision about this column (e.g. refused ambiguous date order).
    pub note: Option<String>,
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
            note: None,
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
            note: None,
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
            note: None,
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
            note: None,
        };
    }

    // --- timestamp (M1.1 1.1.2) ---
    // Tried only after the numeric rungs, so bare integers (IDs, epoch-looking numbers)
    // are never reinterpreted as dates. Ambiguous day/month order is REFUSED, not guessed.
    let mut temporal_note: Option<String> = None;
    if let Some(det) = crate::temporal::detect(&samples, tol) {
        match det.format {
            Some(format) => {
                let mut out_nulls = nulls.to_vec();
                let mut values = Vec::with_capacity(raw.len());
                let mut coerced = 0usize;
                for (i, s) in raw.iter().enumerate() {
                    if nulls[i] {
                        values.push(0);
                        continue;
                    }
                    match crate::temporal::parse(s, format) {
                        Some(v) => values.push(v),
                        None => {
                            values.push(0);
                            out_nulls[i] = true;
                            coerced += 1;
                        }
                    }
                }
                let mut note = format!(
                    "parsed as timestamps using {} and normalized to UTC milliseconds",
                    format.as_str()
                );
                if det.zoned_count < det.matched {
                    note.push_str(&format!(
                        "; {} of {} value(s) had no UTC offset and were assumed to be UTC",
                        det.matched - det.zoned_count,
                        det.matched
                    ));
                }
                return ColumnBuild {
                    column: Column {
                        name: name.to_string(),
                        dtype: DataType::Timestamp,
                        values: ColumnValues::Timestamp(values),
                        nulls: out_nulls,
                    },
                    coerced,
                    parse_ratio: ratio(det.matched),
                    note: Some(note),
                };
            }
            None if det.ambiguous_day_month => {
                temporal_note = Some(
                    "looks like slash-separated dates but day/month order is ambiguous                      (no value has a component above 12); kept as text rather than guessed"
                        .to_string(),
                );
            }
            None => {}
        }
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
        note: temporal_note,
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
        assert_eq!(
            build_column("f", &r, &[false; 3], 0.95).column.dtype,
            DataType::Int64
        );
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
        assert_eq!(
            build_column("x", &r, &[false; 3], 0.95).column.dtype,
            DataType::Int64
        );
    }

    #[test]
    fn nan_and_infinity_are_rejected() {
        let r = raw(&["NaN", "inf", "-inf"]);
        assert_eq!(
            build_column("x", &r, &[false; 3], 0.95).column.dtype,
            DataType::Utf8
        );
    }

    #[test]
    fn mixed_int_and_float_widens_to_float() {
        let r = raw(&["1", "2.5", "3"]);
        assert_eq!(
            build_column("x", &r, &[false; 3], 0.95).column.dtype,
            DataType::Float64
        );
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

    // --- M1.1 task 1.1.2: the timestamp rung ---

    #[test]
    fn iso_column_becomes_timestamp_utc_millis() {
        let r = raw(&["2023-11-14T22:13:20Z", "1970-01-01T00:00:00Z"]);
        let b = build_column("ts", &r, &[false; 2], 0.95);
        assert_eq!(b.column.dtype, DataType::Timestamp);
        assert_eq!(b.coerced, 0);
        match b.column.values {
            ColumnValues::Timestamp(v) => assert_eq!(v, vec![1_700_000_000_000, 0]),
            other => panic!("expected timestamp, got {:?}", other),
        }
    }

    #[test]
    fn unparseable_timestamp_cells_become_null_and_are_counted() {
        let mut vals: Vec<&str> = (0..19).map(|_| "2024-01-01").collect();
        vals.push("not-a-date");
        let r = raw(&vals);
        let b = build_column("ts", &r, &vec![false; 20], 0.95);
        assert_eq!(b.column.dtype, DataType::Timestamp);
        assert_eq!(b.coerced, 1);
        assert!(b.column.nulls[19]);
        assert!(!b.column.nulls[0]);
    }

    #[test]
    fn bare_integers_are_never_reinterpreted_as_dates() {
        // YYYYMMDD and epoch-looking numbers must stay integers (they are often IDs).
        let r = raw(&["20240115", "20240116", "20240117"]);
        assert_eq!(
            build_column("d", &r, &[false; 3], 0.95).column.dtype,
            DataType::Int64
        );
        let e = raw(&["1700000000", "1700000001"]);
        assert_eq!(
            build_column("epoch", &e, &[false; 2], 0.95).column.dtype,
            DataType::Int64
        );
    }

    #[test]
    fn numeric_rungs_win_before_timestamps() {
        let r = raw(&["1.5", "2.5", "3.5"]);
        assert_eq!(
            build_column("x", &r, &[false; 3], 0.95).column.dtype,
            DataType::Float64
        );
    }

    #[test]
    fn ambiguous_day_month_stays_text_and_is_reported() {
        let r = raw(&["01/02/2024", "03/04/2024", "05/06/2024"]);
        let b = build_column("d", &r, &[false; 3], 0.95);
        assert_eq!(
            b.column.dtype,
            DataType::Utf8,
            "must not guess the field order"
        );
        let note = b.note.expect("ambiguity must be reported");
        assert!(note.contains("ambiguous"), "{note}");
        // Original cells are preserved verbatim.
        match b.column.values {
            ColumnValues::Utf8(v) => assert_eq!(v[0], "01/02/2024"),
            other => panic!("expected utf8, got {:?}", other),
        }
    }

    #[test]
    fn day_first_slash_dates_are_typed_when_evidence_resolves_them() {
        let r = raw(&["01/02/2024", "25/12/2024"]);
        let b = build_column("d", &r, &[false; 2], 0.95);
        assert_eq!(b.column.dtype, DataType::Timestamp);
        assert!(b.note.unwrap().contains("DD/MM/YYYY"));
    }

    #[test]
    fn missing_utc_offset_is_disclosed_in_the_note() {
        let r = raw(&["2024-01-01 05:00:00", "2024-01-02 06:00:00"]);
        let b = build_column("ts", &r, &[false; 2], 0.95);
        assert_eq!(b.column.dtype, DataType::Timestamp);
        let note = b.note.unwrap();
        assert!(note.contains("assumed to be UTC"), "{note}");
    }

    #[test]
    fn fully_zoned_column_does_not_warn_about_assumptions() {
        let r = raw(&["2024-01-01T05:00:00Z", "2024-01-02T06:00:00+02:00"]);
        let b = build_column("ts", &r, &[false; 2], 0.95);
        assert_eq!(b.column.dtype, DataType::Timestamp);
        assert!(!b.note.unwrap().contains("assumed"));
    }

    #[test]
    fn mostly_text_column_is_not_temporal() {
        let r = raw(&["2024-01-01", "hello", "world", "more text"]);
        assert_eq!(
            build_column("x", &r, &[false; 4], 0.95).column.dtype,
            DataType::Utf8
        );
    }

    #[test]
    fn all_null_temporal_looking_column_is_null_typed() {
        let r = raw(&["2024-01-01", "2024-01-02"]);
        let b = build_column("ts", &r, &[true, true], 0.95);
        assert_eq!(b.column.dtype, DataType::Null);
    }
}
