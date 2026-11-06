//! Plain-text line datasets (M1.2 task 1.2.2).
//!
//! The honest fallback: when a file is neither delimited, JSON, nor a recognised log shape,
//! it still becomes a workspace instead of an error. Every line is a row with a 1-based
//! `line_number` and the verbatim `line` text (docs/architecture/05 §1.1).
//!
//! Nothing is dropped or rewritten:
//!
//! - Blank lines are kept as empty strings. They are real lines and the line numbers must
//!   stay aligned with the source file, so skipping them would be a lie.
//! - Text is **not** trimmed. Leading indentation is data.
//! - A trailing newline does not invent a final empty row (`str::lines` semantics).
//! - CRLF is handled by `str::lines`.
//!
//! `line` still goes through the shared type ladder, so a file that happens to contain one
//! number per line arrives as an `int64` column rather than text. That is the ladder doing
//! its job, not a special case.

use morphic_model::{ImportReport, Table};

use crate::records::{check_cancel, Grid, Notes};
use crate::{decode, CancelToken, IngestError, IngestOptions, Phase, Progress};

/// Parse plain text into `line_number` + `line` columns with default options.
pub fn parse_txt(bytes: &[u8]) -> Result<(Table, ImportReport), IngestError> {
    parse_txt_with(bytes, &IngestOptions::default(), None, &mut |_| {})
}

/// Parse plain text with explicit options, optional cancellation, and progress events.
pub fn parse_txt_with(
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
    if text.is_empty() {
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
    let mut consumed = 0usize;
    let mut blank = 0usize;

    for (idx, line) in text.lines().enumerate() {
        consumed += line.len() + 1;
        if line.trim().is_empty() {
            blank += 1;
        }
        let fields = vec![
            ("line_number".to_string(), Some((idx + 1).to_string())),
            ("line".to_string(), Some(line.to_string())),
        ];
        grid.push(fields, opts, &mut notes)?;
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
        return Err(IngestError::Empty);
    }
    if blank > 0 {
        warnings.push(format!(
            "{blank} blank line(s) were kept as empty rows so line numbers still match the \
             source file."
        ));
    }

    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Typing,
        rows_read: grid.rows,
        bytes_read: total_bytes,
    });
    let columns = grid.build_columns(opts, &mut warnings);

    let report = ImportReport {
        format: "txt".into(),
        encoding: decoded.encoding,
        rows_imported: grid.rows,
        rows_quarantined: 0,
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
        parse_txt(s.as_bytes()).unwrap_or_else(|e| panic!("failed on {s}: {e}"))
    }

    fn col<'a>(t: &'a Table, name: &str) -> &'a Column {
        t.columns
            .iter()
            .find(|c| c.name == name)
            .unwrap_or_else(|| panic!("no column '{name}'"))
    }

    fn texts(t: &Table, name: &str) -> Vec<&str> {
        match &col(t, name).values {
            ColumnValues::Utf8(v) => v.iter().map(|s| s.as_str()).collect(),
            other => panic!("'{name}' is not Utf8: {other:?}"),
        }
    }

    fn numbers(t: &Table, name: &str) -> Vec<i64> {
        match &col(t, name).values {
            ColumnValues::Int64(v) => v.clone(),
            other => panic!("'{name}' is not Int64: {other:?}"),
        }
    }

    #[test]
    fn every_line_becomes_a_numbered_row() {
        let (t, r) = parse("alpha\nbeta\ngamma\n");
        assert_eq!(t.row_count, 3);
        assert_eq!(t.field_names(), vec!["line_number", "line"]);
        assert_eq!(numbers(&t, "line_number"), vec![1, 2, 3]);
        assert_eq!(texts(&t, "line"), vec!["alpha", "beta", "gamma"]);
        assert_eq!(r.format, "txt");
        assert_eq!(r.rows_quarantined, 0);
    }

    #[test]
    fn a_trailing_newline_does_not_invent_a_row() {
        let (t, _) = parse("one\n");
        assert_eq!(t.row_count, 1);
    }

    #[test]
    fn no_trailing_newline_is_fine() {
        let (t, _) = parse("one\ntwo");
        assert_eq!(t.row_count, 2);
        assert_eq!(texts(&t, "line"), vec!["one", "two"]);
    }

    #[test]
    fn crlf_does_not_leave_a_carriage_return_in_the_text() {
        let (t, _) = parse("one\r\ntwo\r\n");
        assert_eq!(texts(&t, "line"), vec!["one", "two"]);
    }

    #[test]
    fn blank_lines_are_kept_so_numbers_stay_aligned() {
        let (t, r) = parse("one\n\nthree\n");
        assert_eq!(t.row_count, 3);
        assert_eq!(numbers(&t, "line_number"), vec![1, 2, 3]);
        assert_eq!(texts(&t, "line"), vec!["one", "", "three"]);
        assert!(r.warnings.iter().any(|w| w.contains("blank line")));
    }

    #[test]
    fn indentation_is_data_not_noise() {
        let (t, _) = parse("  indented\n\ttabbed\n");
        assert_eq!(texts(&t, "line"), vec!["  indented", "\ttabbed"]);
    }

    #[test]
    fn a_file_of_numbers_is_typed_not_left_as_text() {
        let (t, _) = parse("10\n20\n30\n");
        assert_eq!(col(&t, "line").dtype, DataType::Int64);
        assert_eq!(numbers(&t, "line"), vec![10, 20, 30]);
    }

    #[test]
    fn prose_stays_text() {
        let (t, _) = parse("the quick brown fox\njumps over the lazy dog\n");
        assert_eq!(col(&t, "line").dtype, DataType::Utf8);
    }

    #[test]
    fn unicode_survives_verbatim() {
        let (t, _) = parse("café 東京\nnaïve\n");
        assert_eq!(texts(&t, "line"), vec!["café 東京", "naïve"]);
    }

    #[test]
    fn empty_input_is_empty() {
        assert!(matches!(parse_txt(b""), Err(IngestError::Empty)));
    }

    #[test]
    fn a_single_blank_line_is_still_a_row() {
        let (t, _) = parse("\n");
        assert_eq!(t.row_count, 1);
        assert_eq!(texts(&t, "line"), vec![""]);
    }

    #[test]
    fn the_byte_gate_refuses_before_parsing() {
        let opts = IngestOptions {
            max_import_bytes: 4,
            ..Default::default()
        };
        let err = parse_txt_with(b"abcdefgh", &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, IngestError::ResourceLimit(_)), "{err}");
    }

    #[test]
    fn the_memory_gate_aborts() {
        let opts = IngestOptions {
            max_memory_bytes: 32,
            ..Default::default()
        };
        let src = "0123456789\n".repeat(20);
        let err = parse_txt_with(src.as_bytes(), &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, IngestError::ResourceLimit(_)), "{err}");
    }

    #[test]
    fn the_row_gate_is_enforced() {
        let opts = IngestOptions {
            max_rows: 2,
            ..Default::default()
        };
        let err = parse_txt_with(b"a\nb\nc\n", &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, IngestError::TooManyRows { limit: 2 }), "{err}");
    }

    #[test]
    fn cancellation_is_honoured_before_work_starts() {
        let token = CancelToken::new();
        token.cancel();
        let err = parse_txt_with(b"a\n", &IngestOptions::default(), Some(&token), &mut |_| {})
            .unwrap_err();
        assert!(matches!(err, IngestError::Cancelled), "{err}");
    }

    #[test]
    fn progress_runs_through_every_phase_in_order() {
        let mut phases = Vec::new();
        parse_txt_with(b"a\nb\n", &IngestOptions::default(), None, &mut |p| {
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
    fn a_utf8_bom_is_not_part_of_the_first_line() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(b"hello\n");
        let (t, _) = parse_txt(&bytes).unwrap();
        assert_eq!(texts(&t, "line"), vec!["hello"]);
    }

    #[test]
    fn arbitrary_bytes_never_panic() {
        let mut state = 0xDEAD_BEEF_CAFE_F00Du64;
        for len in 0..48usize {
            for _ in 0..40 {
                let mut buf = Vec::with_capacity(len);
                for _ in 0..len {
                    state ^= state << 13;
                    state ^= state >> 7;
                    state ^= state << 17;
                    buf.push((state % 256) as u8);
                }
                let _ = parse_txt(&buf);
            }
        }
    }

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../fixtures");

    #[test]
    fn fixture_notes_txt() {
        let bytes = std::fs::read(format!("{FIXTURES}/valid/notes.txt")).expect("fixture");
        let (t, r) = parse_txt(&bytes).unwrap();
        assert_eq!(t.row_count, 5);
        assert_eq!(r.format, "txt");
        assert_eq!(numbers(&t, "line_number"), vec![1, 2, 3, 4, 5]);
    }
}
