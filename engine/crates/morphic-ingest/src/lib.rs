//! # morphic-ingest
//!
//! Format detection and streaming parsers. **M1.1 implements production CSV**: delimiter
//! and header sniffing, explicit encoding decisions, a 95%-tolerant type ladder, ragged-row
//! repair, quarantine accounting, cancellation, progress events, and bounded memory.
//! JSON / JSONL / TXT / log parsers land in M1.2 (docs/architecture/05).
//!
//! Boundary: produces a `Table` + `ImportReport`. It does not infer semantics or compile UI.
//!
//! Every heuristic is overridable through [`IngestOptions`] and every non-obvious decision
//! is surfaced in `ImportReport::warnings` — the user is told what we guessed (spec §21).

pub mod column;
pub mod decode;
pub mod sniff;
pub mod temporal;

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use morphic_model::{ImportReport, Table};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum IngestError {
    #[error("CSV parse error: {0}")]
    Csv(#[from] csv::Error),
    #[error("the file has no header row")]
    NoHeader,
    #[error("the file is empty")]
    Empty,
    #[error("import cancelled")]
    Cancelled,
    #[error("the file has {found} columns, which exceeds the limit of {limit}")]
    TooManyColumns { limit: usize, found: usize },
    #[error("the file exceeds the row limit of {limit}")]
    TooManyRows { limit: usize },
}

/// Which stage the importer is in, for real progress UI (no fake spinners).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Sniffing,
    Parsing,
    Typing,
    Done,
}

/// A progress observation emitted during import.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    pub phase: Phase,
    pub rows_read: usize,
    pub bytes_read: u64,
}

/// Cooperative cancellation. Cheap to clone and share across the FFI boundary.
#[derive(Debug, Clone, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
}

/// Knobs for one import. Defaults are the documented M1.1 policy.
#[derive(Debug, Clone)]
pub struct IngestOptions {
    /// `None` = sniff the delimiter.
    pub delimiter: Option<u8>,
    /// `None` = sniff whether row 1 is a header.
    pub has_header: Option<bool>,
    /// Minimum fraction of non-null cells that must parse for a column to be typed.
    pub type_tolerance: f64,
    /// Cell values treated as null (compared trimmed + case-insensitively).
    pub null_tokens: Vec<String>,
    /// Hard row cap — a bounded-memory gate, not a silent truncation.
    pub max_rows: usize,
    /// Hard column cap.
    pub max_columns: usize,
}

impl Default for IngestOptions {
    fn default() -> Self {
        Self {
            delimiter: None,
            has_header: None,
            type_tolerance: 0.95,
            null_tokens: ["", "null", "na", "n/a", "nil"]
                .iter()
                .map(|s| s.to_string())
                .collect(),
            max_rows: 2_000_000,
            max_columns: 2_048,
        }
    }
}

impl IngestOptions {
    fn is_null(&self, cell: &str) -> bool {
        let t = cell.trim();
        // Fast path: the overwhelmingly common empty cell.
        if t.is_empty() {
            return true;
        }
        self.null_tokens
            .iter()
            .any(|tok| !tok.is_empty() && t.eq_ignore_ascii_case(tok))
    }
}

/// Parse CSV bytes with default options and no progress/cancellation.
///
/// Retained as the stable entry point used by the Phase 0 bridge and tests.
pub fn parse_csv(bytes: &[u8]) -> Result<(Table, ImportReport), IngestError> {
    parse_csv_with(bytes, &IngestOptions::default(), None, &mut |_| {})
}

/// Parse CSV bytes with explicit options, optional cancellation, and progress events.
pub fn parse_csv_with(
    bytes: &[u8],
    opts: &IngestOptions,
    cancel: Option<&CancelToken>,
    progress: &mut dyn FnMut(Progress),
) -> Result<(Table, ImportReport), IngestError> {
    if bytes.is_empty() {
        return Err(IngestError::Empty);
    }
    let check_cancel = |cancel: Option<&CancelToken>| match cancel {
        Some(c) if c.is_cancelled() => Err(IngestError::Cancelled),
        _ => Ok(()),
    };

    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Sniffing,
        rows_read: 0,
        bytes_read: 0,
    });

    let decoded = decode::decode(bytes);
    let mut warnings = decoded.warnings;
    if decoded.text.trim().is_empty() {
        return Err(IngestError::Empty);
    }

    let delimiter = opts
        .delimiter
        .unwrap_or_else(|| sniff::sniff_delimiter(&decoded.text));
    if delimiter != b',' {
        warnings.push(format!(
            "Detected '{}' as the delimiter.",
            match delimiter {
                b';' => ";".to_string(),
                b'\t' => "\\t".to_string(),
                b'|' => "|".to_string(),
                other => (other as char).to_string(),
            }
        ));
    }

    // Sample a bounded prefix purely to decide the header question.
    let sample = sample_rows(&decoded.text, delimiter, 21, opts.max_columns)?;
    let has_header = opts
        .has_header
        .unwrap_or_else(|| sniff::sniff_header(&sample));

    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Parsing,
        rows_read: 0,
        bytes_read: 0,
    });

    let mut reader = csv::ReaderBuilder::new()
        .delimiter(delimiter)
        .has_headers(false)
        .flexible(true)
        .from_reader(decoded.text.as_bytes());

    let mut rec = csv::StringRecord::new();
    if !reader.read_record(&mut rec)? {
        return Err(IngestError::Empty);
    }
    let ncols = rec.len();
    if ncols == 0 {
        return Err(IngestError::NoHeader);
    }
    if ncols > opts.max_columns {
        return Err(IngestError::TooManyColumns {
            limit: opts.max_columns,
            found: ncols,
        });
    }

    let headers = if has_header {
        normalize_headers(&rec)
    } else {
        warnings.push(format!(
            "No header row detected; columns were named column_1..column_{}.",
            ncols
        ));
        (1..=ncols).map(|i| format!("column_{}", i)).collect()
    };

    let mut raw_cols: Vec<Vec<String>> = vec![Vec::new(); ncols];
    let mut null_cols: Vec<Vec<bool>> = vec![Vec::new(); ncols];
    let mut rows = 0usize;
    let mut quarantined = 0usize;
    let mut ragged = 0usize;

    {
        let push_row = |rec: &csv::StringRecord,
                        raw_cols: &mut [Vec<String>],
                        null_cols: &mut [Vec<bool>],
                        ragged: &mut usize| {
            if rec.len() != ncols {
                *ragged += 1;
            }
            for (i, col) in raw_cols.iter_mut().enumerate() {
                let cell = rec.get(i).unwrap_or("");
                null_cols[i].push(opts.is_null(cell));
                col.push(cell.to_string());
            }
        };

        // A headerless file's first record is data.
        if !has_header {
            push_row(&rec, &mut raw_cols, &mut null_cols, &mut ragged);
            rows += 1;
        }

        let mut consecutive_errors = 0usize;
        loop {
            if rows % 1024 == 0 {
                check_cancel(cancel)?;
            }
            match reader.read_record(&mut rec) {
                Ok(false) => break,
                Ok(true) => {
                    consecutive_errors = 0;
                    if rows >= opts.max_rows {
                        return Err(IngestError::TooManyRows {
                            limit: opts.max_rows,
                        });
                    }
                    push_row(&rec, &mut raw_cols, &mut null_cols, &mut ragged);
                    rows += 1;
                    if rows % 4096 == 0 {
                        progress(Progress {
                            phase: Phase::Parsing,
                            rows_read: rows,
                            bytes_read: reader.position().byte(),
                        });
                    }
                }
                Err(_) => {
                    quarantined += 1;
                    consecutive_errors += 1;
                    // Never spin forever on a pathological reader state.
                    if consecutive_errors >= 100 {
                        warnings.push(
                            "Stopped after 100 consecutive unreadable records; the remainder \
                             of the file was quarantined."
                                .into(),
                        );
                        break;
                    }
                }
            }
        }
    }

    if ragged > 0 {
        warnings.push(format!(
            "{} row(s) did not match the {}-column width; missing cells became null and \
             extra cells were dropped.",
            ragged, ncols
        ));
    }
    if quarantined > 0 {
        warnings.push(format!(
            "{} record(s) were unreadable and quarantined.",
            quarantined
        ));
    }

    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Typing,
        rows_read: rows,
        bytes_read: decoded.text.len() as u64,
    });

    let mut columns = Vec::with_capacity(ncols);
    for (i, name) in headers.iter().enumerate() {
        let built = column::build_column(name, &raw_cols[i], &null_cols[i], opts.type_tolerance);
        if built.coerced > 0 {
            warnings.push(format!(
                "Column '{}': {} value(s) did not parse as {} and were set to null \
                 ({:.1}% of values parsed).",
                name,
                built.coerced,
                built.column.dtype.as_str(),
                100.0 * built.parse_ratio
            ));
        }
        if let Some(note) = &built.note {
            warnings.push(format!("Column '{}': {}.", name, note));
        }
        columns.push(built.column);
    }

    let report = ImportReport {
        format: "csv".into(),
        encoding: decoded.encoding,
        rows_imported: rows,
        rows_quarantined: quarantined,
        field_count: ncols,
        warnings,
    };
    progress(Progress {
        phase: Phase::Done,
        rows_read: rows,
        bytes_read: decoded.text.len() as u64,
    });
    Ok((
        Table {
            columns,
            row_count: rows,
        },
        report,
    ))
}

/// Read at most `limit` records for header sniffing (bounded work, independent of file size).
fn sample_rows(
    text: &str,
    delimiter: u8,
    limit: usize,
    max_columns: usize,
) -> Result<Vec<Vec<String>>, IngestError> {
    let mut reader = csv::ReaderBuilder::new()
        .delimiter(delimiter)
        .has_headers(false)
        .flexible(true)
        .from_reader(text.as_bytes());
    let mut out = Vec::new();
    let mut rec = csv::StringRecord::new();
    while out.len() < limit {
        match reader.read_record(&mut rec) {
            Ok(false) => break,
            Ok(true) => {
                if rec.len() > max_columns {
                    return Err(IngestError::TooManyColumns {
                        limit: max_columns,
                        found: rec.len(),
                    });
                }
                out.push(rec.iter().map(|s| s.to_string()).collect());
            }
            Err(_) => break,
        }
    }
    Ok(out)
}

/// Trim, fill blanks, and de-duplicate header names so downstream bindings stay addressable.
fn normalize_headers(rec: &csv::StringRecord) -> Vec<String> {
    let mut seen: HashSet<String> = HashSet::new();
    rec.iter()
        .enumerate()
        .map(|(i, h)| {
            let base = {
                let t = h.trim();
                if t.is_empty() {
                    format!("column_{}", i + 1)
                } else {
                    t.to_string()
                }
            };
            let mut name = base.clone();
            let mut suffix = 2;
            while !seen.insert(name.clone()) {
                name = format!("{}_{}", base, suffix);
                suffix += 1;
            }
            name
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use morphic_model::DataType;

    #[test]
    fn parses_mixed_types() {
        let csv =
            b"id,name,amount,active\n1,alice,10.5,true\n2,bob,20.0,false\n3,carol,30.25,true\n";
        let (table, report) = parse_csv(csv).unwrap();
        assert_eq!(table.row_count, 3);
        assert_eq!(report.field_count, 4);
        assert_eq!(table.columns[0].dtype, DataType::Int64);
        assert_eq!(table.columns[1].dtype, DataType::Utf8);
        assert_eq!(table.columns[2].dtype, DataType::Float64);
        assert_eq!(table.columns[3].dtype, DataType::Bool);
    }

    #[test]
    fn empty_cells_are_null() {
        let csv = b"a,b\n1,x\n,\n3,z\n";
        let (table, _) = parse_csv(csv).unwrap();
        assert_eq!(table.columns[0].nulls, vec![false, true, false]);
        assert_eq!(table.columns[0].dtype, DataType::Int64);
    }

    #[test]
    fn integers_not_misread_as_bool() {
        let csv = b"flag\n0\n1\n1\n";
        let (table, _) = parse_csv(csv).unwrap();
        assert_eq!(table.columns[0].dtype, DataType::Int64);
    }

    #[test]
    fn empty_file_errors() {
        assert!(matches!(parse_csv(b""), Err(IngestError::Empty)));
    }

    #[test]
    fn whitespace_only_file_errors() {
        assert!(matches!(parse_csv(b"\n\n  \n"), Err(IngestError::Empty)));
    }

    #[test]
    fn header_only_is_zero_rows() {
        let (table, report) = parse_csv(b"a,b,c\n").unwrap();
        assert_eq!(table.row_count, 0);
        assert_eq!(report.rows_imported, 0);
    }

    // --- M1.1 behaviour ---

    #[test]
    fn semicolon_file_is_sniffed() {
        let (table, report) = parse_csv(b"id;amount\n1;2.5\n2;3.5\n").unwrap();
        assert_eq!(report.field_count, 2);
        assert_eq!(table.row_count, 2);
        assert_eq!(table.columns[1].dtype, DataType::Float64);
        assert!(report.warnings.iter().any(|w| w.contains("delimiter")));
    }

    #[test]
    fn tab_file_is_sniffed() {
        let (table, _) = parse_csv(b"a\tb\n1\t2\n3\t4\n").unwrap();
        assert_eq!(table.columns.len(), 2);
        assert_eq!(table.columns[0].dtype, DataType::Int64);
    }

    #[test]
    fn headerless_numeric_file_keeps_first_row_as_data() {
        let (table, report) = parse_csv(b"1,2.5\n2,3.5\n3,4.5\n").unwrap();
        assert_eq!(table.row_count, 3);
        assert_eq!(table.columns[0].name, "column_1");
        assert!(report.warnings.iter().any(|w| w.contains("No header")));
    }

    #[test]
    fn explicit_options_override_sniffing() {
        let opts = IngestOptions {
            delimiter: Some(b';'),
            has_header: Some(false),
            ..Default::default()
        };
        // Sniffing alone would call this comma-delimited with a header.
        let (table, _) = parse_csv_with(b"a,b\n1,2\n", &opts, None, &mut |_| {}).unwrap();
        assert_eq!(table.columns.len(), 1);
        assert_eq!(table.row_count, 2);
    }

    #[test]
    fn null_tokens_are_honoured() {
        let (table, _) = parse_csv(b"a,b\n1,x\nNULL,NA\n3,z\n").unwrap();
        assert_eq!(table.columns[0].nulls, vec![false, true, false]);
        assert_eq!(table.columns[0].dtype, DataType::Int64);
    }

    #[test]
    fn tolerant_typing_reports_coercion() {
        let mut csv = String::from("v\n");
        for _ in 0..19 {
            csv.push_str("5\n");
        }
        csv.push_str("bad\n");
        let (table, report) = parse_csv(csv.as_bytes()).unwrap();
        assert_eq!(table.columns[0].dtype, DataType::Int64);
        assert!(table.columns[0].nulls[19]);
        assert!(report.warnings.iter().any(|w| w.contains("set to null")));
    }

    #[test]
    fn duplicate_and_blank_headers_are_repaired() {
        let (table, _) = parse_csv(b"a,a,,d\n1,2,3,4\n").unwrap();
        let names: Vec<&str> = table.columns.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["a", "a_2", "column_3", "d"]);
    }

    #[test]
    fn crlf_and_bom_are_handled() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(b"a,b\r\n1,2\r\n3,4\r\n");
        let (table, report) = parse_csv(&bytes).unwrap();
        assert_eq!(table.columns[0].name, "a");
        assert_eq!(table.row_count, 2);
        assert_eq!(report.encoding, "utf-8");
    }

    #[test]
    fn latin1_fallback_is_reported() {
        let (table, report) = parse_csv(&[b'n', b'a', b'm', b'e', b'\n', 0xE9, b'\n']).unwrap();
        assert_eq!(table.row_count, 1);
        assert!(report.encoding.contains("latin-1"));
        assert!(report.warnings.iter().any(|w| w.contains("UTF-8")));
    }

    #[test]
    fn ragged_rows_are_repaired_and_reported() {
        let (table, report) = parse_csv(b"a,b,c\n1,2\n3,4,5,6\n").unwrap();
        assert_eq!(table.row_count, 2);
        assert_eq!(table.columns.len(), 3);
        assert!(table.columns[2].nulls[0]);
        assert!(report.warnings.iter().any(|w| w.contains("width")));
    }

    #[test]
    fn column_cap_is_enforced() {
        let opts = IngestOptions {
            max_columns: 2,
            ..Default::default()
        };
        let err = parse_csv_with(b"a,b,c\n1,2,3\n", &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(
            err,
            IngestError::TooManyColumns { limit: 2, found: 3 }
        ));
    }

    #[test]
    fn row_cap_is_enforced() {
        let opts = IngestOptions {
            max_rows: 2,
            ..Default::default()
        };
        let err = parse_csv_with(b"a\n1\n2\n3\n", &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, IngestError::TooManyRows { limit: 2 }));
    }

    #[test]
    fn cancellation_before_start_is_honoured() {
        let token = CancelToken::new();
        token.cancel();
        let err = parse_csv_with(
            b"a\n1\n",
            &IngestOptions::default(),
            Some(&token),
            &mut |_| {},
        )
        .unwrap_err();
        assert!(matches!(err, IngestError::Cancelled));
    }

    #[test]
    fn cancellation_during_parse_is_honoured() {
        let token = CancelToken::new();
        let mut csv = String::from("a\n");
        for i in 0..5000 {
            csv.push_str(&format!("{}\n", i));
        }
        // Cancel from the progress callback, i.e. mid-stream.
        let t = token.clone();
        let err = parse_csv_with(
            csv.as_bytes(),
            &IngestOptions::default(),
            Some(&token),
            &mut |p| {
                if p.rows_read > 0 {
                    t.cancel();
                }
            },
        )
        .unwrap_err();
        assert!(matches!(err, IngestError::Cancelled));
    }

    #[test]
    fn progress_reaches_done_with_row_count() {
        let mut phases = Vec::new();
        let mut last = 0;
        let (table, _) =
            parse_csv_with(b"a\n1\n2\n3\n", &IngestOptions::default(), None, &mut |p| {
                phases.push(p.phase);
                last = p.rows_read;
            })
            .unwrap();
        assert_eq!(table.row_count, 3);
        assert_eq!(last, 3);
        assert_eq!(phases.first(), Some(&Phase::Sniffing));
        assert_eq!(phases.last(), Some(&Phase::Done));
        assert!(phases.contains(&Phase::Typing));
    }

    #[test]
    fn quoted_delimiters_are_not_split() {
        let (table, _) = parse_csv(b"name,note\nalice,\"hello, world\"\n").unwrap();
        assert_eq!(table.columns.len(), 2);
        match &table.columns[1].values {
            morphic_model::ColumnValues::Utf8(v) => assert_eq!(v[0], "hello, world"),
            other => panic!("expected utf8, got {:?}", other),
        }
    }

    // Fixture-corpus tests (fixtures/manifest.json). Paths resolve from the crate dir.
    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../fixtures");

    fn fixture(rel: &str) -> Vec<u8> {
        std::fs::read(format!("{}/{}", FIXTURES, rel)).expect("fixture present")
    }

    #[test]
    fn fixture_mixed_types() {
        let (table, report) = parse_csv(&fixture("valid/mixed_types.csv")).unwrap();
        assert_eq!(table.row_count, 5);
        assert_eq!(report.field_count, 5);
        assert_eq!(table.columns[0].dtype, DataType::Int64); // id
        assert_eq!(table.columns[2].dtype, DataType::Float64); // amount
        assert_eq!(table.columns[3].dtype, DataType::Bool); // active
    }

    #[test]
    fn fixture_ragged_never_crashes() {
        let (table, _) = parse_csv(&fixture("malformed/ragged.csv")).unwrap();
        assert_eq!(table.columns.len(), 3); // header width
        assert_eq!(table.row_count, 3);
    }

    #[test]
    fn fixture_empty_errors() {
        assert!(matches!(
            parse_csv(&fixture("malformed/empty.csv")),
            Err(IngestError::Empty)
        ));
    }

    #[test]
    fn fixture_semicolon() {
        let (table, report) = parse_csv(&fixture("valid/semicolon.csv")).unwrap();
        assert_eq!(report.field_count, 3);
        assert_eq!(table.row_count, 4);
        assert_eq!(table.columns[1].dtype, DataType::Float64);
    }

    #[test]
    fn fixture_headerless() {
        let (table, _) = parse_csv(&fixture("valid/headerless.csv")).unwrap();
        assert_eq!(table.row_count, 4);
        assert_eq!(table.columns[0].name, "column_1");
    }

    #[test]
    fn fixture_tolerant_types() {
        let (table, report) = parse_csv(&fixture("valid/tolerant_types.csv")).unwrap();
        assert_eq!(table.columns[1].dtype, DataType::Int64);
        assert!(report.warnings.iter().any(|w| w.contains("set to null")));
    }

    #[test]
    fn fixture_latin1() {
        let (_, report) = parse_csv(&fixture("valid/latin1.csv")).unwrap();
        assert!(report.encoding.contains("latin-1"));
    }

    // --- M1.1 task 1.1.2: temporal ingestion, end to end ---

    #[test]
    fn fixture_timestamps_normalize_offsets_to_the_same_instant() {
        let (table, report) = parse_csv(&fixture("valid/timestamps.csv")).unwrap();
        assert_eq!(table.columns[1].dtype, DataType::Timestamp);
        assert_eq!(table.row_count, 4);
        match &table.columns[1].values {
            morphic_model::ColumnValues::Timestamp(v) => {
                // 12:00Z, 14:00+02:00 and 07:00-05:00 are the same instant.
                assert_eq!(v[0], v[1]);
                assert_eq!(v[1], v[2]);
                assert!(v[3] > v[0]);
            }
            other => panic!("expected timestamps, got {:?}", other),
        }
        // Every value carried an offset, so no assumption warning is emitted.
        assert!(
            !report
                .warnings
                .iter()
                .any(|w| w.contains("assumed to be UTC")),
            "{:?}",
            report.warnings
        );
    }

    #[test]
    fn fixture_naive_timestamps_disclose_the_utc_assumption() {
        let (table, report) = parse_csv(&fixture("valid/naive_timestamps.csv")).unwrap();
        assert_eq!(table.columns[0].dtype, DataType::Timestamp);
        assert!(
            report
                .warnings
                .iter()
                .any(|w| w.contains("assumed to be UTC")),
            "the missing-offset assumption must be reported: {:?}",
            report.warnings
        );
    }

    #[test]
    fn fixture_ambiguous_dates_are_kept_as_text_with_a_warning() {
        let (table, report) = parse_csv(&fixture("valid/ambiguous_dates.csv")).unwrap();
        assert_eq!(table.columns[0].dtype, DataType::Utf8);
        assert!(
            report.warnings.iter().any(|w| w.contains("ambiguous")),
            "ambiguity must be reported: {:?}",
            report.warnings
        );
        // Fidelity: the original cells survive untouched.
        match &table.columns[0].values {
            morphic_model::ColumnValues::Utf8(v) => assert_eq!(v[0], "01/02/2024"),
            other => panic!("expected utf8, got {:?}", other),
        }
    }

    #[test]
    fn fixture_day_first_dates_are_typed_when_evidence_resolves_them() {
        let (table, report) = parse_csv(&fixture("valid/day_first_dates.csv")).unwrap();
        assert_eq!(table.columns[0].dtype, DataType::Timestamp);
        assert!(
            report.warnings.iter().any(|w| w.contains("DD/MM/YYYY")),
            "the chosen layout must be reported: {:?}",
            report.warnings
        );
    }

    #[test]
    fn mixed_types_temporal_column_is_now_a_real_timestamp() {
        // Phase 0 left this as Utf8 with only a role hint; 1.1.2 types it.
        let (table, _) = parse_csv(&fixture("valid/mixed_types.csv")).unwrap();
        assert_eq!(table.columns[4].name, "ts");
        assert_eq!(table.columns[4].dtype, DataType::Timestamp);
    }

    /// Guards the fixture itself, not the parser. `latin1.csv` only tests the fallback path
    /// if it is genuinely invalid UTF-8; a re-encoding (observed once from a workspace
    /// snapshot) would turn it into ordinary UTF-8 and make the real test vacuous.
    #[test]
    fn latin1_fixture_really_is_invalid_utf8() {
        let bytes = fixture("valid/latin1.csv");
        assert!(
            std::str::from_utf8(&bytes).is_err(),
            "fixtures/valid/latin1.csv must contain invalid UTF-8; it was re-encoded. \
             Restore it with: git checkout -- fixtures/valid/latin1.csv"
        );
        assert!(
            bytes.contains(&0xE9),
            "expected the Latin-1 byte 0xE9 (e-acute)"
        );
        assert!(
            bytes.contains(&0xFC),
            "expected the Latin-1 byte 0xFC (u-umlaut)"
        );
    }
}
