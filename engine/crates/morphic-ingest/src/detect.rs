//! Format detection (M1.2 task 1.2.3), implementing docs/architecture/05 §1.1.
//!
//! Order of evidence: **BOM/encoding → content probes on the first 64 KB → extension hint →
//! fallback**. The extension is the *weakest* evidence, never the first: a `.csv` full of
//! log lines is a log file, and a `.txt` full of JSON is JSON.
//!
//! | Probe | Result |
//! |---|---|
//! | first non-ws char `[` | JSON array |
//! | first non-ws char `{` and ≥90% of sampled lines are complete JSON values | JSONL |
//! | first non-ws char `{` otherwise | JSON object |
//! | a delimiter giving ≥2 fields on ≥90% of sampled lines | CSV/TSV |
//! | ≥70% of sampled lines match a curated log pattern | LOG |
//! | extension hint, when no probe was decisive | that format, reported |
//! | otherwise | TXT |
//!
//! Every decision carries the evidence that produced it and a confidence, so the import UI
//! can show *why* and offer a re-import with a `formatHint`. An explicit hint short-circuits
//! detection entirely — that is what an override is for.
//!
//! Probing is bounded: at most [`PROBE_BYTES`] are decoded and at most [`SAMPLE_LINES`] lines
//! examined, so detection cost does not grow with file size. The window is cut at a newline
//! so probes never see half a record.

use crate::{decode, log, sniff};

/// Bytes decoded for probing. Detection never reads the whole file.
pub const PROBE_BYTES: usize = 64 * 1024;

/// Lines examined by the JSONL, CSV and log probes.
pub const SAMPLE_LINES: usize = 256;

/// Share of sampled lines that must be complete JSON values to call a file JSONL.
pub const JSONL_RATE: f64 = 0.90;

/// Minimum log-pattern match rate worth choosing LOG over TXT.
///
/// Lower than [`log::CONFIDENT_MATCH_RATE`] for the same reason as
/// [`sniff::DELIMITER_PLAUSIBLE`]: a mixed log where only 60% of lines match still benefits
/// from timestamp/level extraction, and the log parser keeps every unmatched line verbatim.
/// Choosing TXT would discard the structure that *is* there.
pub const LOG_PLAUSIBLE_RATE: f64 = 0.50;

/// Formats the engine can parse.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Csv,
    Json,
    Jsonl,
    Log,
    Txt,
}

impl Format {
    /// Stable identifier, used in `ImportReport.format`, the bridge and the UI.
    pub fn as_str(self) -> &'static str {
        match self {
            Format::Csv => "csv",
            Format::Json => "json",
            Format::Jsonl => "jsonl",
            Format::Log => "log",
            Format::Txt => "txt",
        }
    }

    /// Parse a caller-supplied hint. Aliases are accepted so the UI and file extensions can
    /// share one vocabulary. Unknown strings return `None` rather than guessing.
    pub fn parse(s: &str) -> Option<Format> {
        match s
            .trim()
            .trim_start_matches('.')
            .to_ascii_lowercase()
            .as_str()
        {
            "csv" | "tsv" => Some(Format::Csv),
            "json" => Some(Format::Json),
            "jsonl" | "ndjson" => Some(Format::Jsonl),
            "log" | "logs" => Some(Format::Log),
            "txt" | "text" => Some(Format::Txt),
            _ => None,
        }
    }

    /// What a file extension weakly suggests.
    fn from_extension(ext: &str) -> Option<Format> {
        Format::parse(ext)
    }
}

/// Why a format was chosen, with enough detail to show the user.
#[derive(Debug, Clone)]
pub struct Detection {
    pub format: Format,
    /// 0.0–1.0. An explicit hint is 1.0; content probes report their agreement.
    pub confidence: f64,
    /// Human-readable evidence, surfaced in `ImportReport.warnings`.
    pub evidence: String,
    pub warnings: Vec<String>,
}

/// Detect the format of `bytes`. `hint` overrides everything; `extension` is the last resort.
pub fn detect(bytes: &[u8], hint: Option<Format>, extension: Option<&str>) -> Detection {
    if let Some(format) = hint {
        return Detection {
            format,
            confidence: 1.0,
            evidence: format!("the format was set explicitly to '{}'", format.as_str()),
            warnings: Vec::new(),
        };
    }
    let mut detection = if bytes.is_empty() {
        // No content means no evidence. The extension below is then the only signal there
        // is, so this must not return early.
        Detection {
            format: Format::Txt,
            confidence: 0.0,
            evidence: "the file is empty".into(),
            warnings: Vec::new(),
        }
    } else {
        let window = &bytes[..bytes.len().min(PROBE_BYTES)];
        // Never probe half a record: cut back to the last newline when there is one.
        let cut = match window.iter().rposition(|b| *b == b'\n') {
            Some(i) if i + 1 < window.len() => i + 1,
            _ => window.len(),
        };
        // Decode properly so a UTF-16 file is not mistaken for NUL-riddled text. The
        // decoder's warnings are deliberately dropped here: the parser reports them once.
        let text = decode::decode(&window[..cut]).text;
        let trimmed = text.trim_start();
        let lines: Vec<&str> = text
            .lines()
            .filter(|l| !l.trim().is_empty())
            .take(SAMPLE_LINES)
            .collect();
        probe(trimmed, &lines, &text)
    };
    if let Some(ext) = extension {
        if let Some(suggested) = Format::from_extension(ext) {
            if suggested != Format::Txt
                && detection.format == Format::Txt
                && detection.confidence < JSONL_RATE
            {
                detection = Detection {
                    format: suggested,
                    confidence: 0.4,
                    evidence: format!(
                        "no content probe was decisive, so the '.{}' extension chose '{}'",
                        ext.trim_start_matches('.'),
                        suggested.as_str()
                    ),
                    warnings: vec![format!(
                        "The format came from the file extension, not the contents. If the \
                         table looks wrong, re-import with an explicit format."
                    )],
                };
            } else if suggested != detection.format {
                detection.warnings.push(format!(
                    "The '.{}' extension suggests '{}', but the contents look like '{}'; \
                     the contents won.",
                    ext.trim_start_matches('.'),
                    suggested.as_str(),
                    detection.format.as_str()
                ));
            }
        }
    }
    detection
}

/// Content probes only — no extension, no hint.
fn probe(trimmed: &str, lines: &[&str], text: &str) -> Detection {
    let mut warnings = Vec::new();

    // JSON is structural and decisive: nothing else legitimately starts with '[' or '{'.
    if trimmed.starts_with('[') {
        return Detection {
            format: Format::Json,
            confidence: 0.95,
            evidence: "the document starts with '[', a JSON array".into(),
            warnings,
        };
    }
    if trimmed.starts_with('{') {
        let parsed = lines
            .iter()
            .filter(|l| serde_json::from_str::<serde_json::Value>(l.trim()).is_ok())
            .count();
        let rate = if lines.is_empty() {
            0.0
        } else {
            parsed as f64 / lines.len() as f64
        };
        if lines.len() >= 2 && rate >= JSONL_RATE {
            return Detection {
                format: Format::Jsonl,
                confidence: rate,
                evidence: format!(
                    "{parsed} of {} sampled lines are complete JSON values ({:.0}%)",
                    lines.len(),
                    100.0 * rate
                ),
                warnings,
            };
        }
        return Detection {
            format: Format::Json,
            confidence: 0.90,
            evidence: "the document starts with '{', a JSON object".into(),
            warnings,
        };
    }

    let csv = sniff::delimiter_evidence(text);
    let csv_score = csv.map(|(_, _, agreement)| agreement).unwrap_or(0.0);
    let (pattern, hits) = log::select_pattern(lines);
    let log_rate = if lines.is_empty() {
        0.0
    } else {
        hits as f64 / lines.len() as f64
    };

    // Both can fire on the same file (a comma-separated log export). The stronger evidence
    // wins and the runner-up is disclosed rather than silently discarded.
    let csv_wins = csv_score >= sniff::DELIMITER_PLAUSIBLE && csv_score >= log_rate;
    let log_wins = log_rate >= LOG_PLAUSIBLE_RATE && !csv_wins;
    if csv_wins && log_rate >= LOG_PLAUSIBLE_RATE {
        warnings.push(format!(
            "This file also looks like '{}' logs ({:.0}% of lines matched). It was read as \
             delimited text because the column evidence was stronger; re-import as 'log' \
             if that is wrong.",
            pattern.as_str(),
            100.0 * log_rate
        ));
    } else if log_wins && csv_score >= sniff::DELIMITER_PLAUSIBLE {
        warnings.push(format!(
            "This file also has a consistent delimiter ({:.0}% of lines). It was read as \
             '{}' logs; re-import as 'csv' if that is wrong.",
            100.0 * csv_score,
            pattern.as_str()
        ));
    }

    if csv_wins {
        let (delim, fields, agreement) = csv.expect("csv_wins implies evidence");
        let name = match delim {
            b',' => "','",
            b';' => "';'",
            b'\t' => "TAB",
            b'|' => "'|'",
            _ => "an unknown delimiter",
        };
        if agreement < sniff::DELIMITER_AGREEMENT {
            warnings.push(format!(
                "Only {:.0}% of sampled lines agree on {fields} fields, so some rows are \
                 probably ragged. Short rows will have empty cells and over-long rows are \
                 reported rather than dropped.",
                100.0 * agreement
            ));
        }
        return Detection {
            format: Format::Csv,
            confidence: agreement,
            evidence: format!(
                "{fields} fields separated by {name} on {:.0}% of sampled lines",
                100.0 * agreement
            ),
            warnings,
        };
    }
    if log_wins {
        if log_rate < log::CONFIDENT_MATCH_RATE {
            warnings.push(format!(
                "Only {:.0}% of sampled lines match the '{}' log pattern. Unmatched lines \
                 are kept verbatim in 'message', so nothing is lost.",
                100.0 * log_rate,
                pattern.as_str()
            ));
        }
        return Detection {
            format: Format::Log,
            confidence: log_rate,
            evidence: format!(
                "{hits} of {} sampled lines match the '{}' log pattern ({:.0}%)",
                lines.len(),
                pattern.as_str(),
                100.0 * log_rate
            ),
            warnings,
        };
    }

    Detection {
        format: Format::Txt,
        confidence: 0.5,
        evidence: format!(
            "no JSON, delimiter or log pattern was decisive across {} sampled lines",
            lines.len()
        ),
        warnings,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn det(s: &str) -> Detection {
        detect(s.as_bytes(), None, None)
    }

    #[test]
    fn an_explicit_hint_short_circuits_everything() {
        let d = detect(b"a,b\n1,2\n", Some(Format::Log), Some("csv"));
        assert_eq!(d.format, Format::Log);
        assert_eq!(d.confidence, 1.0);
        assert!(d.evidence.contains("explicitly"));
    }

    #[test]
    fn hint_aliases_are_accepted() {
        assert_eq!(Format::parse("CSV"), Some(Format::Csv));
        assert_eq!(Format::parse(".tsv"), Some(Format::Csv));
        assert_eq!(Format::parse("ndjson"), Some(Format::Jsonl));
        assert_eq!(Format::parse(" text "), Some(Format::Txt));
        assert_eq!(Format::parse("parquet"), None);
    }

    #[test]
    fn every_format_round_trips_through_its_name() {
        for f in [
            Format::Csv,
            Format::Json,
            Format::Jsonl,
            Format::Log,
            Format::Txt,
        ] {
            assert_eq!(Format::parse(f.as_str()), Some(f));
        }
    }

    #[test]
    fn a_json_array_is_json() {
        let d = det(r#"[{"a":1},{"a":2}]"#);
        assert_eq!(d.format, Format::Json);
        assert!(d.evidence.contains("'['"), "{}", d.evidence);
    }

    #[test]
    fn a_single_json_object_is_json() {
        assert_eq!(det(r#"{"a":1,"b":{"c":2}}"#).format, Format::Json);
    }

    #[test]
    fn a_pretty_printed_object_is_not_mistaken_for_jsonl() {
        // Only the first line is a complete JSON value, so the JSONL rate is far below 90%.
        let d = det("{\n  \"a\": 1,\n  \"b\": 2\n}\n");
        assert_eq!(d.format, Format::Json);
    }

    #[test]
    fn one_object_per_line_is_jsonl() {
        let d = det("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n");
        assert_eq!(d.format, Format::Jsonl);
        assert!(d.confidence >= JSONL_RATE);
        assert!(
            d.evidence.contains("complete JSON values"),
            "{}",
            d.evidence
        );
    }

    #[test]
    fn mostly_jsonl_with_one_bad_line_is_still_jsonl() {
        let mut s = String::new();
        for i in 0..20 {
            s.push_str(&format!("{{\"a\":{i}}}\n"));
        }
        s.push_str("garbage\n");
        assert_eq!(det(&s).format, Format::Jsonl);
    }

    #[test]
    fn a_comma_csv_is_csv_with_evidence() {
        let d = det("id,name,amount\n1,alice,2.5\n2,bob,3.5\n");
        assert_eq!(d.format, Format::Csv);
        assert!(d.evidence.contains("3 fields"), "{}", d.evidence);
        assert!(d.evidence.contains("','"), "{}", d.evidence);
    }

    #[test]
    fn semicolon_and_tab_files_are_csv() {
        assert_eq!(det("a;b;c\n1;2;3\n4;5;6\n").format, Format::Csv);
        let tab = det("a\tb\tc\n1\t2\t3\n4\t5\t6\n");
        assert_eq!(tab.format, Format::Csv);
        assert!(tab.evidence.contains("TAB"), "{}", tab.evidence);
    }

    #[test]
    fn one_ragged_row_does_not_veto_an_obvious_delimiter() {
        let mut s = String::from("a,b,c\n");
        for i in 0..15 {
            s.push_str(&format!("{i},x,y\n"));
        }
        s.push_str("short,row\n");
        let d = det(&s);
        assert_eq!(d.format, Format::Csv);
        assert!(d.confidence < 1.0, "raggedness must lower confidence");
    }

    #[test]
    fn prose_commas_are_not_a_delimiter() {
        let d = det(
            "Hello, world.\nThis line has no comma at all\nAnd here are two, separated, commas\n",
        );
        assert_ne!(d.format, Format::Csv);
    }

    #[test]
    fn iso_logs_are_detected_as_logs() {
        let d = det("2026-11-05T14:00:01Z INFO api hello\n2026-11-05T14:00:02Z WARN api slow\n");
        assert_eq!(d.format, Format::Log);
        assert!(d.evidence.contains("iso-level"), "{}", d.evidence);
    }

    #[test]
    fn access_logs_are_detected_as_logs() {
        let d = det(
            "127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] \"GET / HTTP/1.0\" 200 23\n\
             127.0.0.1 - - [10/Oct/2000:13:55:37 -0700] \"GET /x HTTP/1.0\" 404 1\n",
        );
        assert_eq!(d.format, Format::Log);
    }

    #[test]
    fn logfmt_is_detected_as_logs_not_csv() {
        let d = det("time=2026-11-05T14:00:01Z level=info msg=hi\nlevel=warn msg=slow\n");
        assert_eq!(d.format, Format::Log);
    }

    #[test]
    fn unstructured_prose_is_txt() {
        let d = det("just some prose\nanother line of text\n");
        assert_eq!(d.format, Format::Txt);
        assert!(d.evidence.contains("no JSON"), "{}", d.evidence);
    }

    #[test]
    fn a_single_column_file_is_txt_not_a_one_column_csv() {
        assert_eq!(det("alpha\nbeta\ngamma\n").format, Format::Txt);
    }

    #[test]
    fn the_extension_breaks_a_tie_only_when_content_was_not_decisive() {
        let d = detect(b"alpha\nbeta\n", None, Some("csv"));
        assert_eq!(d.format, Format::Csv);
        assert!(d.evidence.contains("extension"), "{}", d.evidence);
        assert!(
            !d.warnings.is_empty(),
            "an extension guess must be disclosed"
        );
    }

    #[test]
    fn content_beats_a_misleading_extension_and_says_so() {
        let d = detect(b"[{\"a\":1}]", None, Some("csv"));
        assert_eq!(d.format, Format::Json);
        assert!(
            d.warnings.iter().any(|w| w.contains("the contents won")),
            "{:?}",
            d.warnings
        );
    }

    #[test]
    fn a_dot_prefixed_extension_works() {
        assert_eq!(
            detect(b"alpha\nbeta\n", None, Some(".jsonl")).format,
            Format::Jsonl
        );
    }

    #[test]
    fn an_unknown_extension_does_not_force_a_format() {
        assert_eq!(
            detect(b"alpha\nbeta\n", None, Some("bin")).format,
            Format::Txt
        );
    }

    #[test]
    fn empty_input_is_reported_not_guessed() {
        let d = detect(b"", None, None);
        assert_eq!(d.confidence, 0.0);
        assert!(d.evidence.contains("empty"));
    }

    #[test]
    fn a_utf16_json_file_is_not_mistaken_for_nul_riddled_text() {
        let src = "[{\"a\":1}]";
        let mut bytes = vec![0xFF, 0xFE];
        for unit in src.encode_utf16() {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        assert_eq!(detect(&bytes, None, None).format, Format::Json);
    }

    #[test]
    fn a_utf8_bom_does_not_hide_the_json() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(b"[{\"a\":1}]");
        assert_eq!(detect(&bytes, None, None).format, Format::Json);
    }

    #[test]
    fn crlf_files_detect_the_same_as_lf() {
        let lf = det("a,b\n1,2\n3,4\n");
        let crlf = det("a,b\r\n1,2\r\n3,4\r\n");
        assert_eq!(lf.format, crlf.format);
        assert_eq!(lf.format, Format::Csv);
    }

    #[test]
    fn probing_is_bounded_to_the_window() {
        // A CSV head followed by far more than 64 KB of prose must still detect as CSV:
        // detection reads the window, not the file.
        let mut s = String::from("a,b,c\n1,2,3\n4,5,6\n");
        s.push_str(&"x".repeat(PROBE_BYTES * 2));
        assert_eq!(det(&s).format, Format::Csv);
    }

    #[test]
    fn a_ragged_csv_is_still_csv_not_text() {
        // Field counts 3,2,4,3: only half the lines agree, but every line has a comma.
        // Demoting this to TXT would throw away all of its structure; the CSV parser is
        // built to recover exactly this file.
        let d = fixture_detection("malformed/ragged.csv");
        assert_eq!(d.format, Format::Csv);
        assert!(d.confidence < sniff::DELIMITER_AGREEMENT);
        assert!(
            d.warnings.iter().any(|w| w.contains("ragged")),
            "{:?}",
            d.warnings
        );
    }

    #[test]
    fn a_mixed_log_is_still_log_not_text() {
        // 3 of 5 lines are real log entries. The log parser extracts those and keeps the
        // other two verbatim, which is strictly more than TXT would give.
        let d = fixture_detection("malformed/mixed.log");
        assert_eq!(d.format, Format::Log);
        assert!(d.confidence < log::CONFIDENT_MATCH_RATE);
        assert!(
            d.warnings.iter().any(|w| w.contains("kept verbatim")),
            "{:?}",
            d.warnings
        );
    }

    #[test]
    fn an_empty_file_has_no_content_so_the_extension_may_decide() {
        let bare = detect(b"", None, None);
        assert_eq!(bare.format, Format::Txt);
        assert_eq!(bare.confidence, 0.0);
        let hinted = detect(b"", None, Some("csv"));
        assert_eq!(hinted.format, Format::Csv);
        assert!(
            !hinted.warnings.is_empty(),
            "an extension guess is disclosed"
        );
    }

    #[test]
    fn arbitrary_bytes_never_panic() {
        let mut state = 0xA5A5_5A5A_DEAD_BEEFu64;
        let alphabet = b"{}[]\",;|\t\n0123456789abcINFO=: -.\\\xc3\xa9\xff";
        for len in 0..64usize {
            for _ in 0..30 {
                let mut buf = Vec::with_capacity(len);
                for _ in 0..len {
                    state ^= state << 13;
                    state ^= state >> 7;
                    state ^= state << 17;
                    buf.push(alphabet[state as usize % alphabet.len()]);
                }
                let d = detect(&buf, None, None);
                assert!((0.0..=1.0).contains(&d.confidence));
            }
        }
    }

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../fixtures");

    fn fixture_detection(rel: &str) -> Detection {
        let bytes = std::fs::read(format!("{FIXTURES}/{rel}")).expect("fixture");
        detect(&bytes, None, None)
    }

    fn fixture_format(rel: &str) -> Format {
        fixture_detection(rel).format
    }

    #[test]
    fn the_whole_fixture_corpus_detects_correctly() {
        for (rel, expected) in [
            ("valid/mixed_types.csv", Format::Csv),
            ("valid/semicolon.csv", Format::Csv),
            ("valid/tab.tsv", Format::Csv),
            ("valid/records.json", Format::Json),
            ("valid/nested.json", Format::Json),
            ("valid/single_object.json", Format::Json),
            ("valid/events.jsonl", Format::Jsonl),
            ("valid/notes.txt", Format::Txt),
            ("valid/server_logs.log", Format::Log),
            ("valid/syslog.log", Format::Log),
            ("valid/access.log", Format::Log),
            ("valid/logfmt.log", Format::Log),
        ] {
            assert_eq!(fixture_format(rel), expected, "{rel}");
        }
    }

    #[test]
    fn the_malformed_corpus_never_panics_and_always_decides() {
        for rel in [
            "malformed/ragged.csv",
            "malformed/truncated.json",
            "malformed/empty.csv",
            "malformed/bad_element.json",
            "malformed/mixed.log",
        ] {
            let bytes = std::fs::read(format!("{FIXTURES}/{rel}")).expect("fixture present");
            let d = detect(&bytes, None, None);
            assert!(!d.evidence.is_empty(), "{rel}");
        }
    }
}
