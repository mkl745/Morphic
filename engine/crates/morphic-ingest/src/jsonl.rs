//! JSON Lines / NDJSON ingestion (M1.2 task 1.2.2).
//!
//! One JSON value per line. This is the shape log shippers, `jq -c`, BigQuery exports and
//! most event streams produce, and it is genuinely streaming: a line is parsed, folded into
//! the column builders and dropped, so peak parse memory is one line rather than the file.
//!
//! Records go through [`crate::records`] — the *same* flattening, null, naming, typing and
//! quarantine policy as the JSON array parser. Two copies of that policy is how formats
//! drift apart, so there is only one.
//!
//! Differences from [`crate::json`], all deliberate:
//!
//! - **Blank lines are skipped.** They carry no record. A trailing newline is not a row.
//! - **A bad line does not end the parse.** The line is quarantined and the first 20 line
//!   numbers are reported so the user can find them (docs/architecture/05 §1.3).
//! - **No trailing-content or trailing-comma tolerance is needed** — each line stands alone.
//!
//! A line holding a JSON array is quarantined, exactly as an array element would be. A line
//! holding a scalar becomes a `value` cell, so a stream of bare numbers still imports.

use morphic_model::{ImportReport, Table};
use serde_json::Value;

use crate::records::{check_cancel, report_quarantine, row_fields, Grid, Notes};
use crate::{decode, CancelToken, IngestError, IngestOptions, Phase, Progress};

/// Parse JSON Lines bytes with default options and no progress/cancellation.
pub fn parse_jsonl(bytes: &[u8]) -> Result<(Table, ImportReport), IngestError> {
    parse_jsonl_with(bytes, &IngestOptions::default(), None, &mut |_| {})
}

/// Parse JSON Lines with explicit options, optional cancellation, and progress events.
pub fn parse_jsonl_with(
    bytes: &[u8],
    opts: &IngestOptions,
    cancel: Option<&CancelToken>,
    progress: &mut dyn FnMut(Progress),
) -> Result<(Table, ImportReport), IngestError> {
    if bytes.is_empty() {
        return Err(IngestError::Empty);
    }
    if bytes.len() > opts.max_import_bytes {
        return Err(IngestError::ResourceLimit(format!(
            "the file is {} MiB, over the {} MiB import limit; import a sample instead",
            bytes.len() / (1024 * 1024),
            opts.max_import_bytes / (1024 * 1024)
        )));
    }
    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Sniffing,
        rows_read: 0,
        bytes_read: 0,
    });

    let decoded = decode::decode(bytes);
    let text = decoded.text;
    if text.trim().is_empty() {
        return Err(IngestError::Empty);
    }
    let mut warnings = decoded.warnings;
    let total_bytes = text.len() as u64;

    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Parsing,
        rows_read: 0,
        bytes_read: 0,
    });

    let mut grid = Grid::new(opts.max_columns);
    let mut notes = Notes::default();
    let mut quarantined = 0usize;
    let mut bad_lines: Vec<usize> = Vec::new();
    let mut consumed = 0usize;

    for (idx, line) in text.lines().enumerate() {
        consumed += line.len() + 1;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let record = match serde_json::from_str::<Value>(trimmed) {
            Ok(v) => row_fields(&v, &mut notes),
            Err(_) => None,
        };
        match record {
            Some(fields) => grid.push(fields, opts, &mut notes)?,
            None => {
                quarantined += 1;
                if bad_lines.len() < 20 {
                    bad_lines.push(idx + 1);
                }
            }
        }
        if grid.rows > opts.max_rows {
            return Err(IngestError::TooManyRows {
                limit: opts.max_rows,
            });
        }
        if (idx + 1) % 4096 == 0 {
            check_cancel(cancel)?;
            progress(Progress {
                phase: Phase::Parsing,
                rows_read: grid.rows,
                bytes_read: consumed.min(text.len()) as u64,
            });
        }
    }

    if grid.rows == 0 {
        if quarantined > 0 {
            return Err(IngestError::Json(format!(
                "none of the {quarantined} line(s) could be read as JSON records"
            )));
        }
        return Err(IngestError::Empty);
    }

    report_quarantine(grid.rows, quarantined, "line", &mut warnings)?;
    if !bad_lines.is_empty() {
        let listed = bad_lines
            .iter()
            .map(|n| n.to_string())
            .collect::<Vec<_>>()
            .join(", ");
        let more = if quarantined > bad_lines.len() {
            format!(" (first 20 of {quarantined})")
        } else {
            String::new()
        };
        warnings.push(format!("Unreadable line number(s){more}: {listed}."));
    }
    notes.extend_warnings("file", &mut warnings);

    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Typing,
        rows_read: grid.rows,
        bytes_read: total_bytes,
    });
    let columns = grid.build_columns(opts, &mut warnings);

    let report = ImportReport {
        format: "jsonl".into(),
        encoding: decoded.encoding,
        rows_imported: grid.rows,
        rows_quarantined: quarantined,
        field_count: grid.order.len(),
        warnings,
    };
    progress(Progress {
        phase: Phase::Done,
        rows_read: grid.rows,
        bytes_read: total_bytes,
    });
    Ok((
        Table {
            columns,
            row_count: grid.rows,
        },
        report,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use morphic_model::{Column, ColumnValues, DataType};

    fn parse(s: &str) -> (Table, ImportReport) {
        parse_jsonl(s.as_bytes()).unwrap_or_else(|e| panic!("failed on {s}: {e}"))
    }

    fn col<'a>(t: &'a Table, name: &str) -> &'a Column {
        t.columns
            .iter()
            .find(|c| c.name == name)
            .unwrap_or_else(|| panic!("no column '{name}' in {:?}", t.field_names()))
    }

    fn names(t: &Table) -> Vec<&str> {
        t.columns.iter().map(|c| c.name.as_str()).collect()
    }

    fn texts(t: &Table, name: &str) -> Vec<&str> {
        match &col(t, name).values {
            ColumnValues::Utf8(v) => v.iter().map(|s| s.as_str()).collect(),
            other => panic!("'{name}' is not Utf8: {other:?}"),
        }
    }

    fn warned(r: &ImportReport, needle: &str) -> bool {
        r.warnings.iter().any(|w| w.contains(needle))
    }

    #[test]
    fn one_object_per_line_becomes_rows() {
        let (t, r) = parse("{\"id\":1,\"host\":\"a\"}\n{\"id\":2,\"host\":\"b\"}\n");
        assert_eq!(t.row_count, 2);
        assert_eq!(names(&t), vec!["host", "id"]);
        assert_eq!(col(&t, "id").dtype, DataType::Int64);
        assert_eq!(r.format, "jsonl");
        assert_eq!(r.rows_imported, 2);
        assert_eq!(r.rows_quarantined, 0);
    }

    #[test]
    fn a_trailing_newline_is_not_a_row() {
        let (t, _) = parse("{\"a\":1}\n");
        assert_eq!(t.row_count, 1);
    }

    #[test]
    fn no_trailing_newline_is_fine() {
        let (t, _) = parse("{\"a\":1}\n{\"a\":2}");
        assert_eq!(t.row_count, 2);
    }

    #[test]
    fn crlf_line_endings_are_handled() {
        let (t, _) = parse("{\"a\":1}\r\n{\"a\":2}\r\n");
        assert_eq!(t.row_count, 2);
    }

    #[test]
    fn blank_lines_are_skipped_not_quarantined() {
        let (t, r) = parse("{\"a\":1}\n\n   \n{\"a\":2}\n");
        assert_eq!(t.row_count, 2);
        assert_eq!(r.rows_quarantined, 0);
    }

    #[test]
    fn a_bad_line_is_quarantined_and_its_number_reported() {
        let (t, r) = parse("{\"a\":1}\nnot json\n{\"a\":3}\n");
        assert_eq!(t.row_count, 2);
        assert_eq!(r.rows_quarantined, 1);
        assert!(
            warned(&r, "Unreadable line number(s): 2."),
            "{:?}",
            r.warnings
        );
    }

    #[test]
    fn only_the_first_twenty_bad_line_numbers_are_listed() {
        let src = format!("{{\"a\":1}}\n{}", "bad\n".repeat(30));
        let (t, r) = parse(&src);
        assert_eq!(t.row_count, 1);
        assert_eq!(r.rows_quarantined, 30);
        assert!(warned(&r, "first 20 of 30"), "{:?}", r.warnings);
    }

    #[test]
    fn flattening_matches_the_json_array_parser() {
        let (t, r) = parse("{\"user\":{\"city\":\"Oslo\"},\"tags\":[\"x\"]}\n");
        assert!(names(&t).contains(&"user.city"));
        assert_eq!(texts(&t, "user.city"), vec!["Oslo"]);
        assert_eq!(texts(&t, "tags"), vec!["[\"x\"]"]);
        assert!(warned(&r, "holds JSON arrays"));
    }

    #[test]
    fn json_and_jsonl_agree_on_the_same_records() {
        // The whole point of the shared records module: identical input, identical output.
        let records = [r#"{"a":1,"n":{"b":"x"}}"#, r#"{"a":2,"n":{"b":"y"}}"#];
        let array = format!("[{}]", records.join(","));
        let lines = records.join("\n");
        let (ta, _) = crate::json::parse_json(array.as_bytes()).unwrap();
        let (tl, _) = parse(&lines);
        assert_eq!(ta.field_names(), tl.field_names());
        assert_eq!(ta.row_count, tl.row_count);
        for (ca, cl) in ta.columns.iter().zip(tl.columns.iter()) {
            assert_eq!(ca.dtype, cl.dtype, "{}", ca.name);
            assert_eq!(ca.nulls, cl.nulls, "{}", ca.name);
        }
    }

    #[test]
    fn nulls_come_only_from_json_null_or_absent_keys() {
        let (t, _) = parse("{\"a\":\"null\"}\n{\"a\":null}\n{\"b\":1}\n");
        assert_eq!(col(&t, "a").nulls, vec![false, true, true]);
        assert_eq!(texts(&t, "a"), vec!["null", "", ""]);
    }

    #[test]
    fn absent_keys_back_fill_as_null() {
        let (t, _) = parse("{\"a\":1}\n{\"b\":2}\n");
        assert_eq!(col(&t, "a").nulls, vec![false, true]);
        assert_eq!(col(&t, "b").nulls, vec![true, false]);
    }

    #[test]
    fn scalar_lines_become_a_value_column() {
        let (t, r) = parse("1\n2\n3\n");
        assert_eq!(t.row_count, 3);
        assert_eq!(names(&t), vec!["value"]);
        assert_eq!(col(&t, "value").dtype, DataType::Int64);
        assert!(warned(&r, "single 'value' column"));
    }

    #[test]
    fn array_lines_are_quarantined() {
        let (t, r) = parse("{\"a\":1}\n[1,2]\n");
        assert_eq!(t.row_count, 1);
        assert_eq!(r.rows_quarantined, 1);
    }

    #[test]
    fn iso_strings_become_timestamps() {
        let (t, _) =
            parse("{\"at\":\"2024-01-01T05:00:00Z\"}\n{\"at\":\"2024-01-02T06:00:00Z\"}\n");
        assert_eq!(col(&t, "at").dtype, DataType::Timestamp);
    }

    #[test]
    fn empty_input_is_empty() {
        assert!(matches!(parse_jsonl(b""), Err(IngestError::Empty)));
        assert!(matches!(parse_jsonl(b"\n \n\t\n"), Err(IngestError::Empty)));
    }

    #[test]
    fn no_readable_records_is_a_typed_error() {
        let err = parse_jsonl(b"nope\nstill nope\n").unwrap_err();
        match err {
            IngestError::Json(m) => assert!(m.contains("could be read as JSON records"), "{m}"),
            other => panic!("wrong error: {other}"),
        }
    }

    #[test]
    fn a_mostly_broken_file_fails() {
        let src = format!("{{\"a\":1}}\n{}", "bad\n".repeat(1500));
        let err = parse_jsonl(src.as_bytes()).unwrap_err();
        match err {
            IngestError::Json(m) => assert!(m.contains("quarantine allowance"), "{m}"),
            other => panic!("wrong error: {other}"),
        }
    }

    #[test]
    fn the_byte_gate_refuses_before_parsing() {
        let opts = IngestOptions {
            max_import_bytes: 8,
            ..Default::default()
        };
        let err =
            parse_jsonl_with(b"{\"a\":1}\n{\"a\":2}\n", &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, IngestError::ResourceLimit(_)), "{err}");
    }

    #[test]
    fn the_memory_gate_aborts_on_retained_text() {
        let opts = IngestOptions {
            max_memory_bytes: 64,
            ..Default::default()
        };
        let src = "{\"a\":\"0123456789\"}\n".repeat(20);
        let err = parse_jsonl_with(src.as_bytes(), &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, IngestError::ResourceLimit(_)), "{err}");
    }

    #[test]
    fn the_row_gate_is_enforced() {
        let opts = IngestOptions {
            max_rows: 2,
            ..Default::default()
        };
        let err = parse_jsonl_with(b"1\n2\n3\n", &opts, None, &mut |_| {}).unwrap_err();
        assert!(
            matches!(err, IngestError::TooManyRows { limit: 2 }),
            "{err}"
        );
    }

    #[test]
    fn the_column_gate_counts_the_union() {
        let opts = IngestOptions {
            max_columns: 2,
            ..Default::default()
        };
        let err = parse_jsonl_with(
            b"{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n",
            &opts,
            None,
            &mut |_| {},
        )
        .unwrap_err();
        assert!(
            matches!(err, IngestError::TooManyColumns { limit: 2, .. }),
            "{err}"
        );
    }

    #[test]
    fn cancellation_is_honoured_before_work_starts() {
        let token = CancelToken::new();
        token.cancel();
        let err = parse_jsonl_with(b"1\n", &IngestOptions::default(), Some(&token), &mut |_| {})
            .unwrap_err();
        assert!(matches!(err, IngestError::Cancelled), "{err}");
    }

    #[test]
    fn progress_runs_through_every_phase_in_order() {
        let mut phases = Vec::new();
        parse_jsonl_with(b"{\"a\":1}\n", &IngestOptions::default(), None, &mut |p| {
            if phases.last() != Some(&p.phase) {
                phases.push(p.phase);
            }
        })
        .unwrap();
        assert_eq!(
            phases,
            vec![Phase::Sniffing, Phase::Parsing, Phase::Typing, Phase::Done]
        );
    }

    #[test]
    fn a_utf8_bom_does_not_hide_the_first_record() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(b"{\"a\":1}\n");
        let (t, _) = parse_jsonl(&bytes).unwrap();
        assert_eq!(t.row_count, 1);
    }

    #[test]
    fn arbitrary_bytes_never_panic() {
        let mut state = 0x9E37_79B9_7F4A_7C15u64;
        let alphabet = b"{}[]\",:0123456789.eE+-truefalsn \n\t\\\xc3\xa9\xff";
        for len in 0..48usize {
            for _ in 0..40 {
                let mut buf = Vec::with_capacity(len);
                for _ in 0..len {
                    state ^= state << 13;
                    state ^= state >> 7;
                    state ^= state << 17;
                    buf.push(alphabet[state as usize % alphabet.len()]);
                }
                let _ = parse_jsonl(&buf);
            }
        }
    }

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../fixtures");

    #[test]
    fn fixture_events_jsonl() {
        let bytes = std::fs::read(format!("{FIXTURES}/valid/events.jsonl")).expect("fixture");
        let (t, r) = parse_jsonl(&bytes).unwrap();
        assert_eq!(t.row_count, 5);
        assert_eq!(r.rows_quarantined, 0);
        assert!(names(&t).contains(&"user.city"));
        assert_eq!(col(&t, "latency_ms").dtype, DataType::Int64);
        assert_eq!(col(&t, "ts").dtype, DataType::Timestamp);
    }
}
