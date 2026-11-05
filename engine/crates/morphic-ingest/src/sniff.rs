//! Delimiter and header detection (docs/architecture/05 §1, M1.1).
//!
//! Both heuristics are *guesses* and are always overridable via `IngestOptions`. The
//! chosen values are reported back so the UI can show "detected ';' delimiter" and offer
//! a re-import with an override rather than silently producing a wrong table.

use std::collections::HashSet;

/// Candidate delimiters, in tie-break preference order.
pub const CANDIDATES: [u8; 4] = [b',', b';', b'\t', b'|'];

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
}
