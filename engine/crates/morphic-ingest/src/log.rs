//! Curated log line parsing, pattern library v1 (M1.2 task 1.2.2).
//!
//! Implements docs/architecture/05 §1.4: an ordered, scored pattern library rather than a
//! guess-per-line. The pattern is chosen **once** from a sample, then applied to every line,
//! so a file cannot end up with half its rows parsed one way and half another.
//!
//! | Pattern | Example |
//! |---|---|
//! | [`LogPattern::IsoLevel`] | `2026-11-05T14:00:01Z ERROR [payments] Charge failed latency=5000` |
//! | [`LogPattern::Syslog`] | `<34>Nov  5 14:00:01 web01 sshd[1234]: Accepted password` |
//! | [`LogPattern::CommonLog`] | `127.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] "GET /x HTTP/1.0" 200 2326` |
//! | [`LogPattern::Logfmt`] | `time=2026-11-05T14:00:01Z level=info msg="ok" latency=12` |
//! | [`LogPattern::Fallback`] | anything else — optional leading timestamp/level, rest is message |
//!
//! # Nothing is dropped
//!
//! A line the chosen pattern cannot match keeps its **entire raw text** in `message`, with
//! the other fields null. The import never fails because a line was odd.
//!
//! # logfmt keys
//!
//! `key=value` pairs are extracted into their own columns — from the whole line for the
//! logfmt pattern, and from the message tail for the others. Quoted values are unquoted.
//! Keys are capped at [`MAX_LOGFMT_KEYS`] = 64 (docs/architecture/05 §1.4); hitting the cap
//! is reported, not silent. Keys that would collide with an already-extracted field are
//! skipped, because the structured prefix is better evidence than a repeated key.
//!
//! # Disclosed limitations
//!
//! - **Service detection is a heuristic.** After the level, `[svc]` is unambiguous; a bare
//!   token is only taken as a service if it starts lowercase, so `INFO Request received`
//!   keeps `Request received` as the message. `INFO request received` is genuinely
//!   ambiguous and is read as service `request`. This is reported, not hidden.
//! - **syslog and CLF timestamps stay text.** RFC3164 has no year and CLF uses month names;
//!   the M1.1 temporal ladder deliberately refuses both rather than guessing. A warning
//!   says so. ISO-8601 and logfmt ISO timestamps do become real `Timestamp` columns.
//! - Levels are canonicalised to `TRACE/DEBUG/INFO/NOTICE/WARN/ERROR/FATAL` so grouping
//!   works; the mapping is documented on [`canonical_level`].

use std::collections::HashSet;
use std::sync::OnceLock;

use morphic_model::{ImportReport, Table};
use regex::Regex;

use crate::records::{check_cancel, Grid, Notes};
use crate::{decode, CancelToken, IngestError, IngestOptions, Phase, Progress};

/// Maximum distinct logfmt keys promoted to columns (docs/architecture/05 §1.4).
pub const MAX_LOGFMT_KEYS: usize = 64;

/// Lines sampled to choose the pattern. Bounded so a huge file costs the same as a small one.
pub const SAMPLE_LINES: usize = 256;

/// The share of sampled lines a pattern must match to be reported as confident
/// (docs/architecture/05 §1.1).
pub const CONFIDENT_MATCH_RATE: f64 = 0.70;

/// A recognised log shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogPattern {
    IsoLevel,
    Syslog,
    CommonLog,
    Logfmt,
    Fallback,
}

impl LogPattern {
    /// Stable identifier used in `ImportReport.warnings` and tests.
    pub fn as_str(self) -> &'static str {
        match self {
            LogPattern::IsoLevel => "iso-level",
            LogPattern::Syslog => "syslog",
            LogPattern::CommonLog => "common-log",
            LogPattern::Logfmt => "logfmt",
            LogPattern::Fallback => "fallback",
        }
    }

    /// The core fields this pattern always emits, in column order.
    fn core_fields(self) -> &'static [&'static str] {
        match self {
            LogPattern::IsoLevel => &["time", "level", "service", "message"],
            LogPattern::Syslog => &["time", "level", "host", "service", "pid", "message"],
            LogPattern::CommonLog => &[
                "time",
                "host",
                "ident",
                "authuser",
                "message",
                "status",
                "bytes",
                "referer",
                "user_agent",
            ],
            LogPattern::Logfmt => &["time", "level", "service", "message"],
            LogPattern::Fallback => &["time", "level", "message"],
        }
    }
}

const LEVEL_ALTERNATIVES: &str =
    "TRACE|DEBUG|INFO|NOTICE|WARNING|WARN|ERROR|ERR|FATAL|CRITICAL|CRIT|ALERT|EMERG|SEVERE";
const ISO_TIME: &str = r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?";

/// Canonical severity vocabulary. Aliases collapse so `WARN` and `WARNING` group together.
/// `CRIT`, `CRITICAL`, `ALERT` and `EMERG` all map to `FATAL`; `ERR`/`SEVERE` to `ERROR`;
/// `NOTICE` is kept distinct from `INFO` because it is a real syslog distinction.
pub fn canonical_level(raw: &str) -> String {
    let upper = raw.trim().to_ascii_uppercase();
    match upper.as_str() {
        "TRACE" => "TRACE",
        "DEBUG" => "DEBUG",
        "INFO" => "INFO",
        "NOTICE" => "NOTICE",
        "WARN" | "WARNING" => "WARN",
        "ERR" | "ERROR" | "SEVERE" => "ERROR",
        "CRIT" | "CRITICAL" | "FATAL" | "ALERT" | "EMERG" => "FATAL",
        other => other,
    }
    .to_string()
}

/// RFC5424 severity code (the low 3 bits of a syslog PRI) as a canonical level.
fn level_from_pri(pri: &str) -> Option<String> {
    let severity = pri.parse::<u32>().ok()? % 8;
    Some(
        match severity {
            0..=2 => "FATAL",
            3 => "ERROR",
            4 => "WARN",
            5 => "NOTICE",
            6 => "INFO",
            _ => "DEBUG",
        }
        .to_string(),
    )
}

// Patterns are built by concatenation, not `format!`, because the regex text contains `{n}`
// quantifiers that `format!` would try to interpret. Each is compiled exactly once.

fn iso_level_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            &[
                r"^(?P<time>",
                ISO_TIME,
                r")[ \t]+(?P<level>(?i:",
                LEVEL_ALTERNATIVES,
                r"))\b[ \t]*(?:\[(?P<svc_bracket>[^\]]+)\][ \t]*|(?P<svc>[a-z0-9][a-z0-9_.\-]*)[ \t]+)?(?P<message>.*)$",
            ]
            .concat(),
        )
        .expect("iso-level pattern compiles")
    })
}

fn syslog_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"^(?:<(?P<pri>\d{1,3})>)?(?P<time>[A-Z][a-z]{2}[ ]+\d{1,2}[ ]+\d{2}:\d{2}:\d{2})[ \t]+(?P<host>[A-Za-z0-9_.\-]+)[ \t]+(?P<service>[A-Za-z0-9_./\-]+)(?:\[(?P<pid>\d+)\])?:[ \t]*(?P<message>.*)$",
        )
        .expect("syslog pattern compiles")
    })
}

fn common_log_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"^(?P<host>\S+)[ \t]+(?P<ident>\S+)[ \t]+(?P<authuser>\S+)[ \t]+\[(?P<time>[^\]]+)\][ \t]+"(?P<message>[^"]*)"[ \t]+(?P<status>\d{3})[ \t]+(?P<bytes>\d+|-)(?:[ \t]+"(?P<referer>[^"]*)"[ \t]+"(?P<user_agent>[^"]*)")?[ \t]*$"#,
        )
        .expect("common-log pattern compiles")
    })
}

fn logfmt_line_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"^(?:[A-Za-z_][A-Za-z0-9_.\-]*=(?:"(?:[^"\\]|\\.)*"|[^ \t]*)[ \t]*)+$"#)
            .expect("logfmt line pattern compiles")
    })
}

fn logfmt_pair_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?P<key>[A-Za-z_][A-Za-z0-9_.\-]*)=(?:"(?P<quoted>(?:[^"\\]|\\.)*)"|(?P<bare>[^ \t]*))"#,
        )
        .expect("logfmt pair pattern compiles")
    })
}

fn leading_time_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&[r"^(?P<time>", ISO_TIME, r")[ \t]*"].concat())
            .expect("leading time pattern compiles")
    })
}

fn leading_level_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&[r"^(?P<level>(?i:", LEVEL_ALTERNATIVES, r"))\b[ \t]*"].concat())
            .expect("leading level pattern compiles")
    })
}

impl LogPattern {
    fn matcher(self) -> Option<&'static Regex> {
        match self {
            LogPattern::IsoLevel => Some(iso_level_re()),
            LogPattern::Syslog => Some(syslog_re()),
            LogPattern::CommonLog => Some(common_log_re()),
            LogPattern::Logfmt => Some(logfmt_line_re()),
            LogPattern::Fallback => None,
        }
    }
}

/// Choose the pattern that matches the most sampled lines. Ties keep the earlier pattern,
/// so the documented order is the priority order. Returns the pattern and its match count.
pub fn select_pattern(sample: &[&str]) -> (LogPattern, usize) {
    let mut best = (LogPattern::Fallback, 0usize);
    for pattern in [
        LogPattern::IsoLevel,
        LogPattern::Syslog,
        LogPattern::CommonLog,
        LogPattern::Logfmt,
    ] {
        let re = pattern.matcher().expect("non-fallback patterns have a matcher");
        let hits = sample.iter().filter(|line| re.is_match(line)).count();
        if hits > best.1 {
            best = (pattern, hits);
        }
    }
    best
}

/// Per-import observations about log extraction.
#[derive(Default)]
struct LogNotes {
    keys: HashSet<String>,
    capped: bool,
    unmatched: usize,
}

/// Parse log bytes with default options, choosing the pattern automatically.
pub fn parse_log(bytes: &[u8]) -> Result<(Table, ImportReport), IngestError> {
    parse_log_with(bytes, &IngestOptions::default(), None, &mut |_| {})
}

/// Parse log bytes with explicit options, optional cancellation, and progress events.
pub fn parse_log_with(
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

    let sample: Vec<&str> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .take(SAMPLE_LINES)
        .collect();
    if sample.is_empty() {
        return Err(IngestError::Empty);
    }
    let (pattern, hits) = select_pattern(&sample);
    let rate = hits as f64 / sample.len() as f64;
    warnings.push(format!(
        "Detected '{}' log format: {hits} of {} sampled lines matched ({:.0}%).",
        pattern.as_str(),
        sample.len(),
        100.0 * rate
    ));
    if pattern != LogPattern::Fallback && rate < CONFIDENT_MATCH_RATE {
        warnings.push(format!(
            "Only {:.0}% of sampled lines matched '{}', below the {:.0}% confidence bar; \
             unmatched lines are kept verbatim in 'message'.",
            100.0 * rate,
            pattern.as_str(),
            100.0 * CONFIDENT_MATCH_RATE
        ));
    }
    match pattern {
        LogPattern::Syslog => warnings.push(
            "syslog timestamps carry no year, so 'time' stays text rather than being guessed \
             into a timestamp."
                .into(),
        ),
        LogPattern::CommonLog => warnings.push(
            "Common-log timestamps use month names, which the temporal parser deliberately \
             refuses; 'time' stays text."
                .into(),
        ),
        LogPattern::IsoLevel => warnings.push(
            "A bare lowercase word right after the level is read as a service name; \
             'INFO request received' is therefore ambiguous."
                .into(),
        ),
        LogPattern::Logfmt | LogPattern::Fallback => {}
    }

    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Parsing,
        rows_read: 0,
        bytes_read: 0,
    });

    let mut grid = Grid::new(opts.max_columns);
    let mut notes = Notes::default();
    let mut log_notes = LogNotes::default();
    let mut consumed = 0usize;
    let mut seen = 0usize;

    for line in text.lines() {
        consumed += line.len() + 1;
        if line.trim().is_empty() {
            continue;
        }
        seen += 1;
        let fields = extract(pattern, line, &mut log_notes);
        grid.push(fields, opts, &mut notes)?;
        if grid.rows > opts.max_rows {
            return Err(IngestError::TooManyRows {
                limit: opts.max_rows,
            });
        }
        if seen % 4096 == 0 {
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
    if log_notes.unmatched > 0 {
        warnings.push(format!(
            "{} line(s) did not match '{}' and were kept verbatim in 'message'.",
            log_notes.unmatched,
            pattern.as_str()
        ));
    }
    if log_notes.capped {
        warnings.push(format!(
            "More than {MAX_LOGFMT_KEYS} distinct logfmt keys were present; keys past the \
             cap stay inside 'message' and were not promoted to columns."
        ));
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
        format: "log".into(),
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

/// Extract one line. Core fields are always emitted (null when absent) so column order is
/// stable regardless of which line happened to carry a field first.
fn extract(pattern: LogPattern, line: &str, notes: &mut LogNotes) -> Vec<(String, Option<String>)> {
    let mut core: Vec<Option<String>> = vec![None; pattern.core_fields().len()];
    let names = pattern.core_fields();
    let slot = |name: &str| names.iter().position(|n| *n == name);
    let mut matched = true;
    let mut tail: Option<&str> = None;

    match pattern {
        LogPattern::IsoLevel => {
            if let Some(c) = iso_level_re().captures(line) {
                set(&mut core, slot("time"), c.name("time"));
                if let Some(l) = c.name("level") {
                    core[slot("level").unwrap()] = Some(canonical_level(l.as_str()));
                }
                let svc = c.name("svc_bracket").or_else(|| c.name("svc"));
                set(&mut core, slot("service"), svc);
                set(&mut core, slot("message"), c.name("message"));
                tail = c.name("message").map(|m| m.as_str());
            } else {
                matched = false;
            }
        }
        LogPattern::Syslog => {
            if let Some(c) = syslog_re().captures(line) {
                set(&mut core, slot("time"), c.name("time"));
                set(&mut core, slot("host"), c.name("host"));
                set(&mut core, slot("service"), c.name("service"));
                set(&mut core, slot("pid"), c.name("pid"));
                set(&mut core, slot("message"), c.name("message"));
                if let Some(p) = c.name("pri") {
                    core[slot("level").unwrap()] = level_from_pri(p.as_str());
                }
                tail = c.name("message").map(|m| m.as_str());
            } else {
                matched = false;
            }
        }
        LogPattern::CommonLog => {
            if let Some(c) = common_log_re().captures(line) {
                for name in [
                    "time",
                    "host",
                    "ident",
                    "authuser",
                    "message",
                    "status",
                    "bytes",
                    "referer",
                    "user_agent",
                ] {
                    // "-" is the CLF convention for an absent field, not a value.
                    if let Some(m) = c.name(name).filter(|m| m.as_str() != "-") {
                        core[slot(name).unwrap()] = Some(m.as_str().to_string());
                    }
                }
            } else {
                matched = false;
            }
        }
        LogPattern::Logfmt => {
            if logfmt_line_re().is_match(line) {
                tail = Some(line);
            } else {
                matched = false;
            }
        }
        LogPattern::Fallback => {
            let mut rest = line;
            if let Some(c) = leading_time_re().captures(rest) {
                core[slot("time").unwrap()] = Some(c["time"].to_string());
                rest = &rest[c.get(0).expect("whole match").end()..];
            }
            if let Some(c) = leading_level_re().captures(rest) {
                core[slot("level").unwrap()] = Some(canonical_level(&c["level"]));
                rest = &rest[c.get(0).expect("whole match").end()..];
            }
            core[slot("message").unwrap()] = Some(rest.to_string());
            tail = Some(rest);
        }
    }

    if !matched {
        notes.unmatched += 1;
        // No data is dropped: the whole line survives as the message.
        if let Some(i) = slot("message") {
            core[i] = Some(line.to_string());
        }
    }

    let mut out: Vec<(String, Option<String>)> = names
        .iter()
        .zip(core.into_iter())
        .map(|(n, v)| ((*n).to_string(), v))
        .collect();

    if let Some(text) = tail {
        let taken: HashSet<String> = out.iter().map(|(n, _)| n.clone()).collect();
        push_logfmt(text, &mut out, taken, notes, pattern == LogPattern::Logfmt);
    }
    // A logfmt line with no msg= key must not mean the line vanishes.
    if pattern == LogPattern::Logfmt {
        if let Some(cell) = out.iter_mut().find(|(n, v)| n == "message" && v.is_none()) {
            cell.1 = Some(line.to_string());
        }
    }
    out
}

fn set(core: &mut [Option<String>], slot: Option<usize>, m: Option<regex::Match<'_>>) {
    if let (Some(i), Some(m)) = (slot, m) {
        core[i] = Some(m.as_str().to_string());
    }
}

/// Promote `key=value` pairs to columns. For the logfmt pattern the reserved names are
/// filled from their aliases; elsewhere the structured prefix already owns them.
fn push_logfmt(
    text: &str,
    out: &mut Vec<(String, Option<String>)>,
    mut taken: HashSet<String>,
    notes: &mut LogNotes,
    fill_core: bool,
) {
    for c in logfmt_pair_re().captures_iter(text) {
        let raw_key = &c["key"];
        let value = c
            .name("quoted")
            .map(|m| unescape(m.as_str()))
            .or_else(|| c.name("bare").map(|m| m.as_str().to_string()))
            .unwrap_or_default();

        if fill_core {
            let target = match raw_key.to_ascii_lowercase().as_str() {
                "time" | "timestamp" | "ts" | "at" => Some("time"),
                "level" | "lvl" | "severity" => Some("level"),
                "service" | "svc" | "logger" | "component" => Some("service"),
                "msg" | "message" => Some("message"),
                _ => None,
            };
            if let Some(name) = target {
                // Find the core cell only if it is still empty: the structured prefix wins.
                if let Some(cell) = out.iter_mut().find(|(n, v)| n == name && v.is_none()) {
                    cell.1 = Some(if name == "level" {
                        canonical_level(&value)
                    } else {
                        value
                    });
                    continue;
                }
            }
        }

        let key = raw_key.trim().to_string();
        if key.is_empty() || taken.contains(&key) {
            continue;
        }
        if !notes.keys.contains(&key) {
            if notes.keys.len() >= MAX_LOGFMT_KEYS {
                notes.capped = true;
                continue;
            }
            notes.keys.insert(key.clone());
        }
        taken.insert(key.clone());
        out.push((key, Some(value)));
    }
}

/// Undo the two escapes logfmt actually uses inside quoted values.
fn unescape(s: &str) -> String {
    if !s.contains('\\') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('r') => out.push('\r'),
                Some(other) => out.push(other),
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use morphic_model::{Column, ColumnValues, DataType};

    fn parse(s: &str) -> (Table, ImportReport) {
        parse_log(s.as_bytes()).unwrap_or_else(|e| panic!("failed on {s}: {e}"))
    }

    fn col<'a>(t: &'a Table, name: &str) -> &'a Column {
        t.columns
            .iter()
            .find(|c| c.name == name)
            .unwrap_or_else(|| panic!("no column '{name}' in {:?}", t.field_names()))
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

    fn chosen(s: &str) -> LogPattern {
        let sample: Vec<&str> = s.lines().filter(|l| !l.trim().is_empty()).collect();
        select_pattern(&sample).0
    }

    // ------------------------------------------------------ pattern selection

    #[test]
    fn iso_level_is_selected_for_iso_prefixed_levels() {
        assert_eq!(
            chosen("2026-11-05T14:00:01Z INFO api hello\n2026-11-05T14:00:02Z WARN api slow\n"),
            LogPattern::IsoLevel
        );
    }

    #[test]
    fn syslog_is_selected_for_rfc3164() {
        assert_eq!(
            chosen("Nov  5 14:00:01 web01 sshd[1]: hi\nNov  5 14:00:02 web01 cron[2]: yo\n"),
            LogPattern::Syslog
        );
    }

    #[test]
    fn common_log_is_selected_for_access_logs() {
        assert_eq!(
            chosen("127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] \"GET / HTTP/1.0\" 200 23\n"),
            LogPattern::CommonLog
        );
    }

    #[test]
    fn logfmt_is_selected_for_key_value_lines() {
        assert_eq!(
            chosen("time=2026-11-05T14:00:01Z level=info msg=hi\nlevel=warn msg=slow\n"),
            LogPattern::Logfmt
        );
    }

    #[test]
    fn prose_falls_back() {
        assert_eq!(chosen("just some prose\nanother line\n"), LogPattern::Fallback);
    }

    #[test]
    fn an_empty_sample_selects_fallback() {
        assert_eq!(select_pattern(&[]), (LogPattern::Fallback, 0));
    }

    #[test]
    fn selection_counts_matches_not_just_the_first_line() {
        // One ISO line among nine prose lines must not drag the whole file into iso-level.
        let mut s = String::from("2026-11-05T14:00:01Z INFO api hello\n");
        for i in 0..9 {
            s.push_str(&format!("plain prose line {i}\n"));
        }
        let sample: Vec<&str> = s.lines().collect();
        let (p, hits) = select_pattern(&sample);
        assert_eq!(p, LogPattern::IsoLevel);
        assert_eq!(hits, 1);
        let (_, r) = parse(&s);
        assert!(warned(&r, "below the 70% confidence bar"), "{:?}", r.warnings);
    }

    // -------------------------------------------------------------- iso-level

    #[test]
    fn iso_level_extracts_the_core_fields() {
        let (t, r) = parse("2026-11-05T14:00:01Z INFO api Request received latency=12\n");
        assert_eq!(
            t.field_names(),
            vec!["time", "level", "service", "message", "latency"]
        );
        assert_eq!(texts(&t, "level"), vec!["INFO"]);
        assert_eq!(texts(&t, "service"), vec!["api"]);
        assert_eq!(texts(&t, "message"), vec!["Request received latency=12"]);
        assert_eq!(col(&t, "time").dtype, DataType::Timestamp);
        assert_eq!(col(&t, "latency").dtype, DataType::Int64);
        assert_eq!(r.format, "log");
        assert!(warned(&r, "Detected 'iso-level'"));
    }

    #[test]
    fn a_bracketed_service_is_unambiguous() {
        let (t, _) = parse("2026-11-05T14:01:02Z ERROR [Payments API] Charge failed\n");
        assert_eq!(texts(&t, "service"), vec!["Payments API"]);
        assert_eq!(texts(&t, "message"), vec!["Charge failed"]);
    }

    #[test]
    fn a_capitalised_first_word_stays_in_the_message() {
        let (t, _) = parse("2026-11-05T14:01:02Z INFO Request received\n");
        assert!(col(&t, "service").nulls[0]);
        assert_eq!(texts(&t, "message"), vec!["Request received"]);
    }

    #[test]
    fn the_lowercase_service_ambiguity_is_disclosed() {
        let (t, r) = parse("2026-11-05T14:01:02Z INFO request received\n");
        assert_eq!(texts(&t, "service"), vec!["request"]);
        assert!(warned(&r, "ambiguous"), "{:?}", r.warnings);
    }

    #[test]
    fn levels_are_canonicalised_for_grouping() {
        let src = "2026-11-05T14:00:01Z WARNING api a\n\
                   2026-11-05T14:00:02Z err api b\n\
                   2026-11-05T14:00:03Z CRITICAL api c\n\
                   2026-11-05T14:00:04Z notice api d\n";
        let (t, _) = parse(src);
        assert_eq!(texts(&t, "level"), vec!["WARN", "ERROR", "FATAL", "NOTICE"]);
    }

    #[test]
    fn canonical_level_mapping_is_total() {
        assert_eq!(canonical_level("warning"), "WARN");
        assert_eq!(canonical_level(" severe "), "ERROR");
        assert_eq!(canonical_level("emerg"), "FATAL");
        assert_eq!(canonical_level("weird"), "WEIRD");
    }

    #[test]
    fn a_space_separated_iso_timestamp_works() {
        let (t, _) = parse("2026-11-05 14:00:01 INFO api hello\n");
        assert_eq!(texts(&t, "service"), vec!["api"]);
    }

    #[test]
    fn offsets_and_fractional_seconds_are_kept_in_the_time_text() {
        let (t, _) = parse("2026-11-05T14:00:01.123+02:00 INFO api hello\n");
        assert_eq!(col(&t, "time").dtype, DataType::Timestamp);
    }

    // ----------------------------------------------------------------- syslog

    #[test]
    fn syslog_extracts_host_service_pid_and_message() {
        let (t, _) = parse("Nov  5 14:00:01 web01 sshd[1234]: Accepted password for root\n");
        assert_eq!(
            t.field_names(),
            vec!["time", "level", "host", "service", "pid", "message"]
        );
        assert_eq!(texts(&t, "host"), vec!["web01"]);
        assert_eq!(texts(&t, "service"), vec!["sshd"]);
        assert_eq!(col(&t, "pid").dtype, DataType::Int64);
        assert_eq!(texts(&t, "message"), vec!["Accepted password for root"]);
    }

    #[test]
    fn syslog_pri_becomes_a_level() {
        let (t, _) = parse("<34>Nov  5 14:00:03 web01 su: authentication failure\n");
        // 34 % 8 == 2 -> critical -> FATAL
        assert_eq!(texts(&t, "level"), vec!["FATAL"]);
    }

    #[test]
    fn syslog_without_a_pid_leaves_it_null() {
        let (t, _) = parse("Nov  5 14:00:04 web02 kernel: eth0 link up\n");
        assert!(col(&t, "pid").nulls[0]);
        assert_eq!(texts(&t, "service"), vec!["kernel"]);
    }

    #[test]
    fn syslog_time_stays_text_and_says_why() {
        let (t, r) = parse("Nov  5 14:00:01 web01 sshd[1]: hi\n");
        assert_eq!(col(&t, "time").dtype, DataType::Utf8);
        assert!(warned(&r, "no year"), "{:?}", r.warnings);
    }

    // ------------------------------------------------------------- common log

    #[test]
    fn combined_log_extracts_every_field() {
        let line = "127.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] \"GET /x.gif HTTP/1.0\" \
                    200 2326 \"http://example.com/\" \"Mozilla/4.08\"\n";
        let (t, _) = parse(line);
        assert_eq!(
            t.field_names(),
            vec![
                "time",
                "host",
                "ident",
                "authuser",
                "message",
                "status",
                "bytes",
                "referer",
                "user_agent"
            ]
        );
        assert_eq!(texts(&t, "host"), vec!["127.0.0.1"]);
        assert_eq!(texts(&t, "authuser"), vec!["frank"]);
        assert_eq!(texts(&t, "message"), vec!["GET /x.gif HTTP/1.0"]);
        assert_eq!(col(&t, "status").dtype, DataType::Int64);
        assert_eq!(col(&t, "bytes").dtype, DataType::Int64);
        assert_eq!(texts(&t, "referer"), vec!["http://example.com/"]);
        assert_eq!(texts(&t, "user_agent"), vec!["Mozilla/4.08"]);
    }

    #[test]
    fn the_clf_dash_convention_becomes_null_not_a_value() {
        let line = "10.0.0.2 - - [10/Oct/2000:13:55:39 -0700] \"GET /missing HTTP/1.1\" \
                    404 - \"-\" \"-\"\n";
        let (t, _) = parse(line);
        for name in ["ident", "authuser", "bytes", "referer", "user_agent"] {
            assert!(col(&t, name).nulls[0], "{name} should be null");
        }
        assert_eq!(col(&t, "ident").dtype, DataType::Null);
    }

    #[test]
    fn basic_clf_without_referer_or_agent_still_parses() {
        let (t, _) = parse("127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] \"GET / HTTP/1.0\" 200 23\n");
        assert_eq!(col(&t, "status").dtype, DataType::Int64);
        assert!(col(&t, "referer").nulls[0]);
    }

    #[test]
    fn clf_time_stays_text_and_says_why() {
        let (t, r) = parse("127.0.0.1 - - [10/Oct/2000:13:55:36 -0700] \"GET / HTTP/1.0\" 200 23\n");
        assert_eq!(col(&t, "time").dtype, DataType::Utf8);
        assert!(warned(&r, "month names"), "{:?}", r.warnings);
    }

    // ----------------------------------------------------------------- logfmt

    #[test]
    fn logfmt_aliases_fill_the_core_fields() {
        let (t, _) = parse("ts=2026-11-05T14:00:01Z severity=warn svc=api message=\"slow\" n=3\n");
        assert_eq!(texts(&t, "level"), vec!["WARN"]);
        assert_eq!(texts(&t, "service"), vec!["api"]);
        assert_eq!(texts(&t, "message"), vec!["slow"]);
        assert_eq!(col(&t, "time").dtype, DataType::Timestamp);
        assert_eq!(col(&t, "n").dtype, DataType::Int64);
    }

    #[test]
    fn logfmt_extra_keys_become_columns() {
        let (t, _) = parse("level=info msg=hi latency_ms=12 retry=true\n");
        assert_eq!(col(&t, "latency_ms").dtype, DataType::Int64);
        assert_eq!(col(&t, "retry").dtype, DataType::Bool);
    }

    #[test]
    fn quoted_logfmt_values_are_unquoted_and_unescaped() {
        let (t, _) = parse(r#"msg="say \"hi\" now" n=3"#);
        assert_eq!(texts(&t, "message"), vec!["say \"hi\" now"]);
    }

    #[test]
    fn a_logfmt_line_without_a_message_key_keeps_its_raw_text() {
        let (t, _) = parse("a=1 b=2\n");
        assert_eq!(texts(&t, "message"), vec!["a=1 b=2"]);
        assert_eq!(col(&t, "a").dtype, DataType::Int64);
    }

    #[test]
    fn logfmt_keys_are_capped_and_the_cap_is_reported() {
        let pairs = (0..70)
            .map(|i| format!("k{i}=v{i}"))
            .collect::<Vec<_>>()
            .join(" ");
        let (t, r) = parse(&pairs);
        assert_eq!(t.field_count, 4 + MAX_LOGFMT_KEYS);
        assert!(warned(&r, "keys past the cap"), "{:?}", r.warnings);
    }

    #[test]
    fn logfmt_tail_keys_are_promoted_for_other_patterns() {
        let (t, _) = parse("2026-11-05T14:00:01Z ERROR payments Charge failed latency=5000\n");
        assert_eq!(col(&t, "latency").dtype, DataType::Int64);
        // The structured prefix owns 'message'; the tail must not overwrite it.
        assert_eq!(texts(&t, "message"), vec!["Charge failed latency=5000"]);
    }

    #[test]
    fn a_tail_key_cannot_overwrite_an_extracted_core_field() {
        let (t, _) = parse("2026-11-05T14:00:01Z INFO api hello level=DEBUG service=other\n");
        assert_eq!(texts(&t, "level"), vec!["INFO"]);
        assert_eq!(texts(&t, "service"), vec!["api"]);
    }

    // --------------------------------------------------------------- fallback

    #[test]
    fn prose_becomes_a_message_column() {
        let (t, r) = parse("just some prose\nanother line\n");
        assert_eq!(t.field_names(), vec!["time", "level", "message"]);
        assert_eq!(texts(&t, "message"), vec!["just some prose", "another line"]);
        assert!(warned(&r, "Detected 'fallback'"));
    }

    #[test]
    fn fallback_peels_a_leading_timestamp_and_level() {
        let (t, _) = parse("2026-11-05T14:00:01Z something odd happened\n");
        assert_eq!(col(&t, "time").dtype, DataType::Timestamp);
        assert_eq!(texts(&t, "message"), vec!["something odd happened"]);
    }

    #[test]
    fn fallback_peels_a_leading_level_without_a_timestamp() {
        let (t, _) = parse("ERROR disk full\n");
        assert_eq!(texts(&t, "level"), vec!["ERROR"]);
        assert_eq!(texts(&t, "message"), vec!["disk full"]);
    }

    // ------------------------------------------------------------- robustness

    #[test]
    fn unmatched_lines_are_kept_verbatim_and_counted() {
        let src = "2026-11-05T14:00:01Z INFO api ok\n\
                   total garbage here\n\
                   2026-11-05T14:00:02Z INFO api ok2\n\
                   2026-11-05T14:00:03Z INFO api ok3\n";
        let (t, r) = parse(src);
        assert_eq!(t.row_count, 4);
        assert_eq!(texts(&t, "message")[1], "total garbage here");
        assert!(col(&t, "time").nulls[1]);
        assert!(warned(&r, "1 line(s) did not match"), "{:?}", r.warnings);
        assert_eq!(r.rows_quarantined, 0); // nothing is thrown away
    }

    #[test]
    fn blank_lines_are_skipped() {
        let (t, _) = parse("ERROR a\n\n   \nERROR b\n");
        assert_eq!(t.row_count, 2);
    }

    #[test]
    fn empty_input_is_empty() {
        assert!(matches!(parse_log(b""), Err(IngestError::Empty)));
        assert!(matches!(parse_log(b"\n \n\t\n"), Err(IngestError::Empty)));
    }

    #[test]
    fn the_byte_gate_refuses_before_parsing() {
        let opts = IngestOptions {
            max_import_bytes: 4,
            ..Default::default()
        };
        let err = parse_log_with(b"ERROR something\n", &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, IngestError::ResourceLimit(_)), "{err}");
    }

    #[test]
    fn the_memory_gate_aborts() {
        let opts = IngestOptions {
            max_memory_bytes: 64,
            ..Default::default()
        };
        let src = "ERROR aaaaaaaaaaaaaaaaaaaa\n".repeat(20);
        let err = parse_log_with(src.as_bytes(), &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, IngestError::ResourceLimit(_)), "{err}");
    }

    #[test]
    fn the_row_gate_is_enforced() {
        let opts = IngestOptions {
            max_rows: 2,
            ..Default::default()
        };
        let err = parse_log_with(b"a\nb\nc\n", &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, IngestError::TooManyRows { limit: 2 }), "{err}");
    }

    #[test]
    fn the_column_gate_counts_promoted_logfmt_keys() {
        let opts = IngestOptions {
            max_columns: 6,
            ..Default::default()
        };
        let err = parse_log_with(b"a=1 b=2 c=3 d=4\n", &opts, None, &mut |_| {}).unwrap_err();
        assert!(
            matches!(err, IngestError::TooManyColumns { limit: 6, .. }),
            "{err}"
        );
    }

    #[test]
    fn cancellation_is_honoured_before_work_starts() {
        let token = CancelToken::new();
        token.cancel();
        let err = parse_log_with(b"a\n", &IngestOptions::default(), Some(&token), &mut |_| {})
            .unwrap_err();
        assert!(matches!(err, IngestError::Cancelled), "{err}");
    }

    #[test]
    fn progress_runs_through_every_phase_in_order() {
        let mut phases = Vec::new();
        parse_log_with(b"ERROR a\n", &IngestOptions::default(), None, &mut |p| {
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
    fn a_utf8_bom_does_not_hide_the_first_line() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(b"2026-11-05T14:00:01Z INFO api hello\n");
        let (t, _) = parse_log(&bytes).unwrap();
        assert_eq!(col(&t, "time").dtype, DataType::Timestamp);
    }

    #[test]
    fn arbitrary_bytes_never_panic() {
        let mut state = 0x0123_4567_89AB_CDEFu64;
        let alphabet = b"0123456789-:T Z[]\"=abcERRORINFOWARN\t\n\\<>/.\xc3\xa9\xff";
        for len in 0..64usize {
            for _ in 0..40 {
                let mut buf = Vec::with_capacity(len);
                for _ in 0..len {
                    state ^= state << 13;
                    state ^= state >> 7;
                    state ^= state << 17;
                    buf.push(alphabet[state as usize % alphabet.len()]);
                }
                let _ = parse_log(&buf);
            }
        }
    }

    // --------------------------------------------------------------- fixtures

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../fixtures");

    fn fixture(rel: &str) -> Vec<u8> {
        std::fs::read(format!("{FIXTURES}/{rel}")).expect("fixture present")
    }

    #[test]
    fn fixture_server_logs() {
        let (t, r) = parse_log(&fixture("valid/server_logs.log")).unwrap();
        assert_eq!(t.row_count, 8);
        assert!(warned(&r, "Detected 'iso-level'"));
        assert_eq!(col(&t, "time").dtype, DataType::Timestamp);
        assert_eq!(col(&t, "latency").dtype, DataType::Int64);
        assert_eq!(texts(&t, "level")[0], "INFO");
    }

    #[test]
    fn fixture_syslog() {
        let (t, r) = parse_log(&fixture("valid/syslog.log")).unwrap();
        assert_eq!(t.row_count, 5);
        assert!(warned(&r, "Detected 'syslog'"));
        assert_eq!(col(&t, "pid").dtype, DataType::Int64);
        assert_eq!(texts(&t, "level")[2], "FATAL");
        assert_eq!(col(&t, "time").dtype, DataType::Utf8);
    }

    #[test]
    fn fixture_access_log() {
        let (t, r) = parse_log(&fixture("valid/access.log")).unwrap();
        assert_eq!(t.row_count, 4);
        assert!(warned(&r, "Detected 'common-log'"));
        assert_eq!(col(&t, "status").dtype, DataType::Int64);
        assert_eq!(col(&t, "bytes").dtype, DataType::Int64);
        assert!(col(&t, "bytes").nulls[3]);
        assert_eq!(col(&t, "ident").dtype, DataType::Null);
    }

    #[test]
    fn fixture_logfmt() {
        let (t, r) = parse_log(&fixture("valid/logfmt.log")).unwrap();
        assert_eq!(t.row_count, 4);
        assert!(warned(&r, "Detected 'logfmt'"));
        assert_eq!(col(&t, "time").dtype, DataType::Timestamp);
        assert_eq!(col(&t, "latency_ms").dtype, DataType::Int64);
        assert_eq!(col(&t, "retry").dtype, DataType::Bool);
        assert_eq!(texts(&t, "level"), vec!["INFO", "WARN", "ERROR", "DEBUG"]);
    }

    #[test]
    fn fixture_mixed_log_never_crashes_and_drops_nothing() {
        let (t, r) = parse_log(&fixture("malformed/mixed.log")).unwrap();
        assert_eq!(t.row_count, 5);
        assert!(warned(&r, "below the 70% confidence bar"));
        assert!(warned(&r, "2 line(s) did not match"));
        assert_eq!(texts(&t, "message")[1], "this line is not a log entry at all");
        assert_eq!(texts(&t, "message")[3], "???");
    }
}
