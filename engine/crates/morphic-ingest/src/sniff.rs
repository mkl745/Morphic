//! Delimiter and header detection (docs/architecture/05 §1, M1.1).
//!
//! Both heuristics are *guesses* and are always overridable via `IngestOptions`. The
//! chosen values are reported back so the UI can show "detected ';' delimiter" and offer
//! a re-import with an override rather than silently producing a wrong table.

use std::collections::HashSet;

/// Candidate delimiters, in tie-break preference order.
pub const CANDIDATES: [u8; 4] = *b",;\t|";

/// Count `delim` occurrences in `line`, ignoring occurrences inside double quotes.
fn count_outside_quotes(line: &str, delim: u8) -> usize {
    let mut in_quotes = false;
    let mut n = 0usize;
    for &b in line.as_bytes() {
        if b == b'"' {
            in_quotes = !in_quotes;
        } else if b == delim && !in_quotes {
            n += 1;
        }
    }
    n
}

/// Pick the delimiter whose per-line count is both non-zero and *consistent*.
///
/// Consistency beats raw frequency: a comma inside a prose column appears a variable
/// number of times per line, whereas the real delimiter repeats identically.
pub fn sniff_delimiter(text: &str) -> u8 {
    let lines: Vec<&str> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .take(20)
        .collect();
    if lines.is_empty() {
        return b',';
    }

    let mut best = b',';
    let mut best_score = 0usize;
    for cand in CANDIDATES {
        let counts: Vec<usize> = lines
            .iter()
            .map(|l| count_outside_quotes(l, cand))
            .collect();
        let min = *counts.iter().min().unwrap_or(&0);
        let max = *counts.iter().max().unwrap_or(&0);
        // A stable, non-zero field separator count across every sampled line.
        if min > 0 && min == max && min > best_score {
            best_score = min;
            best = cand;
        }
    }
    best
}

/// Delimiter evidence for format detection (M1.2 1.2.3).
///
/// Returns `(delimiter, field count, agreement)` where agreement is the share of sampled
/// lines carrying the modal field count. `None` when no candidate produces at least two
/// fields on at least [`DELIMITER_PLAUSIBLE`] of lines — a single-column file is not evidence
/// of a delimited format.
pub fn delimiter_evidence(text: &str) -> Option<(u8, usize, f64)> {
    let lines: Vec<&str> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .take(PROBE_LINES)
        .collect();
    if lines.is_empty() {
        return None;
    }
    let mut best: Option<(u8, usize, f64)> = None;
    for cand in CANDIDATES {
        let counts: Vec<usize> = lines
            .iter()
            .map(|l| count_outside_quotes(l, cand))
            .collect();
        // The modal count, not the minimum: one ragged row must not veto an otherwise
        // obvious delimiter. The agreement fraction carries that raggedness instead.
        let mut modal = 0usize;
        let mut modal_hits = 0usize;
        for probe in &counts {
            let hits = counts.iter().filter(|c| *c == probe).count();
            if hits > modal_hits {
                modal_hits = hits;
                modal = *probe;
            }
        }
        if modal == 0 {
            continue;
        }
        let agreement = modal_hits as f64 / counts.len() as f64;
        if agreement < DELIMITER_PLAUSIBLE {
            continue;
        }
        let better = match best {
            None => true,
            Some((_, fields, prev)) => {
                agreement > prev || (agreement == prev && modal + 1 > fields)
            }
        };
        if better {
            best = Some((cand, modal + 1, agreement));
        }
    }
    best
}

/// Lines examined when scoring a delimiter.
pub const PROBE_LINES: usize = 21;

/// Share of sampled lines that must agree on the field count for the delimiter to be
/// *confident*. Below this the evidence is still returned, but the caller should warn.
pub const DELIMITER_AGREEMENT: f64 = 0.90;

/// Minimum agreement for a delimiter to be worth choosing at all.
///
/// Deliberately lower than [`DELIMITER_AGREEMENT`]: a genuinely ragged CSV (field counts
/// 3,2,4,3) still has a delimiter on every line, and reading it as plain text would throw
/// away all of its structure. docs/architecture/05 §1.1 resolves ambiguity to the *richer*
/// interpretation plus a warning, so a majority is enough to choose CSV — the agreement
/// fraction then travels as the confidence.
pub const DELIMITER_PLAUSIBLE: f64 = 0.50;

/// Decide whether the first record is a header row.
///
/// Signals, in order of strength:
/// 1. a mostly-numeric first row is data, not a header;
/// 2. columns whose first cell is text but whose remaining cells are mostly numeric
///    indicate a label row;
/// 3. otherwise an all-text, all-unique, non-empty first row is treated as a header.
///
/// A single-record file is treated as a header (zero data rows), matching Phase 0.
pub fn sniff_header(rows: &[Vec<String>]) -> bool {
    if rows.len() < 2 {
        return true;
    }
    let first = &rows[0];
    let rest = &rows[1..];
    let ncols = first.len();
    if ncols == 0 {
        return false;
    }

    let is_num = |s: &str| s.trim().parse::<f64>().is_ok();
    let numeric_first = first.iter().filter(|s| is_num(s)).count();
    if numeric_first * 2 > ncols {
        return false;
    }

    let mut label_evidence = 0usize;
    for c in 0..ncols {
        let first_is_num = first.get(c).map(|s| is_num(s)).unwrap_or(false);
        let data_numeric = rest
            .iter()
            .filter(|r| r.get(c).map(|s| is_num(s)).unwrap_or(false))
            .count();
        if !first_is_num && data_numeric * 2 >= rest.len() {
            label_evidence += 1;
        }
    }
    if label_evidence * 2 >= ncols {
        return true;
    }

    let all_text = first.iter().all(|s| !s.trim().is_empty() && !is_num(s));
    let unique: HashSet<&str> = first.iter().map(|s| s.trim()).collect();
    all_text && unique.len() == ncols
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_ignores_quoted_delimiters() {
        assert_eq!(count_outside_quotes("a,\"b,c\",d", b','), 2);
        assert_eq!(count_outside_quotes("a;b;c", b';'), 2);
    }

    #[test]
    fn detects_comma() {
        assert_eq!(sniff_delimiter("a,b,c\n1,2,3\n4,5,6\n"), b',');
    }

    #[test]
    fn detects_semicolon() {
        assert_eq!(sniff_delimiter("a;b;c\n1;2;3\n4;5;6\n"), b';');
    }

    #[test]
    fn detects_tab() {
        assert_eq!(sniff_delimiter("a\tb\tc\n1\t2\t3\n"), b'\t');
    }

    #[test]
    fn detects_pipe() {
        assert_eq!(sniff_delimiter("a|b|c\n1|2|3\n"), b'|');
    }

    #[test]
    fn prose_commas_do_not_beat_a_consistent_semicolon() {
        // The comma count varies per line; the semicolon count is stable at 2.
        let text = "name;note;value\nalice;hello, there;1\nbob;short;2\n";
        assert_eq!(sniff_delimiter(text), b';');
    }

    #[test]
    fn single_column_defaults_to_comma() {
        assert_eq!(sniff_delimiter("a\nb\nc\n"), b',');
    }

    fn rows(v: &[&[&str]]) -> Vec<Vec<String>> {
        v.iter()
            .map(|r| r.iter().map(|s| s.to_string()).collect())
            .collect()
    }

    #[test]
    fn label_row_over_numeric_data_is_a_header() {
        let r = rows(&[&["id", "amount"], &["1", "2.5"], &["2", "3.5"]]);
        assert!(sniff_header(&r));
    }

    #[test]
    fn numeric_first_row_is_data() {
        let r = rows(&[&["1", "2.5"], &["2", "3.5"]]);
        assert!(!sniff_header(&r));
    }

    #[test]
    fn all_text_unique_first_row_is_a_header() {
        let r = rows(&[&["name", "city"], &["alice", "berlin"], &["bob", "paris"]]);
        assert!(sniff_header(&r));
    }

    #[test]
    fn single_record_is_header_only() {
        let r = rows(&[&["a", "b", "c"]]);
        assert!(sniff_header(&r));
    }

    // ------------------------------- M1.2 1.2.3 evidence used by format detection

    #[test]
    fn evidence_reports_the_delimiter_field_count_and_agreement() {
        assert_eq!(delimiter_evidence("a,b,c\n1,2,3\n"), Some((b',', 3, 1.0)));
    }

    #[test]
    fn a_ragged_file_still_yields_evidence_with_lower_agreement() {
        // Counts 2,1,3,2: the modal count is 2 and half the lines agree. Returning None
        // here would demote a recoverable CSV to plain text.
        let (delim, fields, agreement) =
            delimiter_evidence("a,b,c\n1,2\n3,4,5,6\n7,8,9\n").expect("still a delimiter");
        assert_eq!(delim, b',');
        assert_eq!(fields, 3);
        assert!((agreement - 0.5).abs() < f64::EPSILON);
        assert!(agreement < DELIMITER_AGREEMENT);
    }

    #[test]
    fn inconsistent_prose_commas_are_not_evidence() {
        assert_eq!(
            delimiter_evidence("Hello, world.\nNo comma here\nTwo, here, yes\n"),
            None
        );
    }

    #[test]
    fn a_single_column_file_is_not_evidence() {
        assert_eq!(delimiter_evidence("alpha\nbeta\ngamma\n"), None);
    }

    #[test]
    fn delimiters_inside_quotes_are_not_counted() {
        assert_eq!(delimiter_evidence("a,b\n\"x,y\",z\n"), Some((b',', 2, 1.0)));
    }

    #[test]
    fn an_exact_tie_keeps_the_earlier_candidate() {
        // Both ',' and ';' give 2 fields on every line; CANDIDATES order decides.
        assert_eq!(delimiter_evidence("a,b;c\n1,2;3\n").unwrap().0, b',');
    }

    #[test]
    fn more_fields_wins_an_agreement_tie() {
        assert_eq!(delimiter_evidence("a;b,c;d\n1;2,3;4\n"), Some((b';', 3, 1.0)));
    }

}
