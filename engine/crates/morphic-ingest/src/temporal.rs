//! Temporal parsing policy for ingestion (M1.1 task 1.1.2).
//!
//! Normalizes recognized timestamps to **UTC milliseconds**. Deliberate, documented limits:
//!
//! * **No timezone database.** An explicit offset (`Z`, `±HH:MM`, `±HHMM`, `±HH`) is honoured;
//!   a value with no offset is *assumed UTC* and that assumption is surfaced as a warning.
//! * **No silent day/month guessing.** `03/04/2024` is genuinely ambiguous. A slash-date
//!   column is only typed when some row disambiguates it (a component > 12); otherwise the
//!   column stays text and the ambiguity is reported. Guessing here would corrupt data.
//! * **Bare integers are never timestamps.** `20240115` and epoch-looking numbers stay
//!   `int64` so identifiers are not silently reinterpreted as dates.
//! * **Leap seconds (`:60`) are rejected**, since UTC millis cannot represent them.
//! * Fractional seconds are truncated (not rounded) to milliseconds.

use morphic_model::temporal::{days_from_civil, days_in_month, MS_PER_DAY};

/// Recognized source layouts. Reported in the import warnings so the choice is auditable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimestampFormat {
    /// `YYYY-MM-DD` optionally `T`/space `HH:MM[:SS[.fff]]` optionally `Z`/`±HH[:MM]`.
    Iso,
    /// `YYYY/MM/DD` — unambiguous, year first.
    SlashYmd,
    /// `DD/MM/YYYY` — only chosen with disambiguating evidence.
    SlashDmy,
    /// `MM/DD/YYYY` — only chosen with disambiguating evidence.
    SlashMdy,
}

impl TimestampFormat {
    pub fn as_str(self) -> &'static str {
        match self {
            TimestampFormat::Iso => "ISO-8601 (YYYY-MM-DD)",
            TimestampFormat::SlashYmd => "YYYY/MM/DD",
            TimestampFormat::SlashDmy => "DD/MM/YYYY",
            TimestampFormat::SlashMdy => "MM/DD/YYYY",
        }
    }
}

/// Outcome of column-level temporal detection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Detection {
    /// `None` when the column looks temporal but cannot be typed safely.
    pub format: Option<TimestampFormat>,
    /// True when day/month order could not be resolved from the data.
    pub ambiguous_day_month: bool,
    /// How many sampled values carried an explicit UTC offset.
    pub zoned_count: usize,
    /// How many sampled values parsed.
    pub matched: usize,
}

/// Strict ASCII digit run → integer (no signs, no separators, overflow-checked).
fn digits(b: &[u8]) -> Option<i64> {
    if b.is_empty() {
        return None;
    }
    let mut n = 0i64;
    for &c in b {
        if !c.is_ascii_digit() {
            return None;
        }
        n = n.checked_mul(10)?.checked_add(i64::from(c - b'0'))?;
    }
    Some(n)
}

#[derive(Debug, Clone, Copy)]
struct TimeOfDay {
    hour: i64,
    minute: i64,
    second: i64,
    millis: i64,
    offset_minutes: i64,
    has_zone: bool,
}

impl TimeOfDay {
    const MIDNIGHT: TimeOfDay = TimeOfDay {
        hour: 0,
        minute: 0,
        second: 0,
        millis: 0,
        offset_minutes: 0,
        has_zone: false,
    };
}

/// Parse `HH:MM[:SS[.f…]][ ][Z|±HH[:MM]|±HHMM|±HH]`, requiring full consumption.
fn parse_time(b: &[u8]) -> Option<TimeOfDay> {
    if b.len() < 5 || b[2] != b':' {
        return None;
    }
    let hour = digits(&b[0..2])?;
    let minute = digits(&b[3..5])?;
    let mut pos = 5usize;

    let mut second = 0i64;
    if pos < b.len() && b[pos] == b':' {
        if pos + 3 > b.len() {
            return None;
        }
        second = digits(&b[pos + 1..pos + 3])?;
        pos += 3;
    }

    let mut millis = 0i64;
    if pos < b.len() && b[pos] == b'.' {
        pos += 1;
        let start = pos;
        while pos < b.len() && b[pos].is_ascii_digit() {
            pos += 1;
        }
        let frac = &b[start..pos];
        if frac.is_empty() {
            return None;
        }
        // Truncate to millisecond precision, zero-padding short fractions.
        for k in 0..3 {
            millis *= 10;
            if k < frac.len() {
                millis += i64::from(frac[k] - b'0');
            }
        }
    }

    while pos < b.len() && b[pos] == b' ' {
        pos += 1;
    }

    let mut offset_minutes = 0i64;
    let mut has_zone = false;
    if pos < b.len() {
        has_zone = true;
        match b[pos] {
            b'Z' | b'z' => pos += 1,
            b'+' | b'-' => {
                let sign = if b[pos] == b'-' { -1 } else { 1 };
                pos += 1;
                let rest = &b[pos..];
                let (oh, om, used) = if rest.len() >= 5 && rest[2] == b':' {
                    (digits(&rest[0..2])?, digits(&rest[3..5])?, 5usize)
                } else if rest.len() >= 4 && rest[..4].iter().all(|c| c.is_ascii_digit()) {
                    (digits(&rest[0..2])?, digits(&rest[2..4])?, 4usize)
                } else if rest.len() >= 2 {
                    (digits(&rest[0..2])?, 0i64, 2usize)
                } else {
                    return None;
                };
                if oh > 23 || om > 59 {
                    return None;
                }
                offset_minutes = sign * (oh * 60 + om);
                pos += used;
            }
            _ => return None,
        }
    }

    if pos != b.len() || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    Some(TimeOfDay {
        hour,
        minute,
        second,
        millis,
        offset_minutes,
        has_zone,
    })
}

/// Validate the civil date and fold in the time + offset → `(utc_millis, had_explicit_zone)`.
fn combine(year: i64, month: i64, day: i64, time: Option<TimeOfDay>) -> Option<(i64, bool)> {
    if !(1..=9999).contains(&year) || !(1..=12).contains(&month) {
        return None;
    }
    let dim = i64::from(days_in_month(year, month as u32));
    if day < 1 || day > dim {
        return None;
    }
    let t = time.unwrap_or(TimeOfDay::MIDNIGHT);
    let millis = days_from_civil(year, month as u32, day as u32) * MS_PER_DAY
        + t.hour * 3_600_000
        + t.minute * 60_000
        + t.second * 1000
        + t.millis
        - t.offset_minutes * 60_000;
    Some((millis, t.has_zone))
}

/// Parse an ISO-8601-shaped value. Returns `(utc_millis, had_explicit_zone)`.
pub fn parse_iso_full(s: &str) -> Option<(i64, bool)> {
    let trimmed = s.trim();
    let b = trimmed.as_bytes();
    if b.len() < 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let year = digits(&b[0..4])?;
    let month = digits(&b[5..7])?;
    let day = digits(&b[8..10])?;
    let time = if b.len() == 10 {
        None
    } else {
        if !matches!(b[10], b'T' | b't' | b' ') {
            return None;
        }
        Some(parse_time(&b[11..])?)
    };
    combine(year, month, day, time)
}

/// Parse an ISO-8601-shaped value to UTC milliseconds.
pub fn parse_iso(s: &str) -> Option<i64> {
    parse_iso_full(s).map(|(ms, _)| ms)
}

struct SlashParts {
    a: i64,
    b: i64,
    c: i64,
    a_len: usize,
    c_len: usize,
    time: Option<TimeOfDay>,
}

/// Split `N/N/N` with an optional trailing time. Shape only — no calendar validation.
fn split_slash(s: &str) -> Option<SlashParts> {
    let trimmed = s.trim();
    let mut it = trimmed.splitn(3, '/');
    let sa = it.next()?;
    let sb = it.next()?;
    let sc = it.next()?;
    let (sc_num, tail) = match sc.find(|ch| ch == ' ' || ch == 'T') {
        Some(i) => (&sc[..i], Some(&sc.as_bytes()[i + 1..])),
        None => (sc, None),
    };
    let a = digits(sa.as_bytes())?;
    let b = digits(sb.as_bytes())?;
    let c = digits(sc_num.as_bytes())?;
    let time = match tail {
        Some(tb) => Some(parse_time(tb)?),
        None => None,
    };
    Some(SlashParts {
        a,
        b,
        c,
        a_len: sa.len(),
        c_len: sc_num.len(),
        time,
    })
}

/// Parse a slash-separated date under an explicitly chosen field order.
pub fn parse_slash_full(s: &str, format: TimestampFormat) -> Option<(i64, bool)> {
    let p = split_slash(s)?;
    let (year, month, day) = match format {
        TimestampFormat::SlashYmd if p.a_len == 4 => (p.a, p.b, p.c),
        TimestampFormat::SlashDmy if p.c_len == 4 => (p.c, p.b, p.a),
        TimestampFormat::SlashMdy if p.c_len == 4 => (p.c, p.a, p.b),
        _ => return None,
    };
    combine(year, month, day, p.time)
}

/// Parse one value under a detected format.
pub fn parse(s: &str, format: TimestampFormat) -> Option<i64> {
    let full = match format {
        TimestampFormat::Iso => parse_iso_full(s),
        other => parse_slash_full(s, other),
    };
    full.map(|(ms, _)| ms)
}

/// Decide, from a whole column's samples, whether it is temporal and how to read it.
///
/// Returns `None` when the column is not temporal. Returns a `Detection` with
/// `format: None, ambiguous_day_month: true` when it *is* date-shaped but the field order
/// cannot be established — the caller must then keep the column as text and report it.
pub fn detect(samples: &[&str], tolerance: f64) -> Option<Detection> {
    if samples.is_empty() {
        return None;
    }
    let total = samples.len();
    let tol = tolerance.clamp(0.0, 1.0);
    // Division (not `hits >= tol * total`) to match column.rs and avoid the extra
    // rounding of the product, which can reject an exactly-on-tolerance column.
    let enough = |hits: usize| hits as f64 / total as f64 >= tol;

    // ISO first: it is unambiguous and by far the most common in exports and logs.
    let iso: Vec<(i64, bool)> = samples.iter().filter_map(|s| parse_iso_full(s)).collect();
    if enough(iso.len()) {
        return Some(Detection {
            format: Some(TimestampFormat::Iso),
            ambiguous_day_month: false,
            zoned_count: iso.iter().filter(|(_, z)| *z).count(),
            matched: iso.len(),
        });
    }

    let shapes: Vec<SlashParts> = samples.iter().filter_map(|s| split_slash(s)).collect();
    if !enough(shapes.len()) {
        return None;
    }

    let zoned = |fmt: TimestampFormat| {
        samples
            .iter()
            .filter_map(|s| parse_slash_full(s, fmt))
            .filter(|(_, z)| *z)
            .count()
    };
    let matched = |fmt: TimestampFormat| {
        samples
            .iter()
            .filter(|s| parse_slash_full(s, fmt).is_some())
            .count()
    };

    // Year-first is unambiguous.
    if shapes.iter().all(|p| p.a_len == 4) {
        let hits = matched(TimestampFormat::SlashYmd);
        if enough(hits) {
            return Some(Detection {
                format: Some(TimestampFormat::SlashYmd),
                ambiguous_day_month: false,
                zoned_count: zoned(TimestampFormat::SlashYmd),
                matched: hits,
            });
        }
        return None;
    }

    if shapes.iter().all(|p| p.c_len == 4) {
        // Only a component that cannot be a month resolves the order.
        let day_first = shapes.iter().any(|p| p.a > 12 && p.a <= 31);
        let month_first = shapes.iter().any(|p| p.b > 12 && p.b <= 31);
        let fmt = match (day_first, month_first) {
            (true, false) => TimestampFormat::SlashDmy,
            (false, true) => TimestampFormat::SlashMdy,
            // Neither resolves it, or the column contradicts itself: refuse to guess.
            _ => {
                return Some(Detection {
                    format: None,
                    ambiguous_day_month: true,
                    zoned_count: 0,
                    matched: shapes.len(),
                })
            }
        };
        let hits = matched(fmt);
        if enough(hits) {
            return Some(Detection {
                format: Some(fmt),
                ambiguous_day_month: false,
                zoned_count: zoned(fmt),
                matched: hits,
            });
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn date_only_is_midnight_utc() {
        assert_eq!(parse_iso("1970-01-01"), Some(0));
        assert_eq!(parse_iso("2000-01-01"), Some(10957 * MS_PER_DAY));
        // 2024-03-09 is 68 days after 2024-01-01 (31 + 29 + 8), cross-checked independently.
        assert_eq!(parse_iso_full("2024-03-09"), Some((19723 + 68) * MS_PER_DAY, false));
    }

    #[test]
    fn known_epoch_instant() {
        assert_eq!(parse_iso("2023-11-14T22:13:20Z"), Some(1_700_000_000_000));
    }

    #[test]
    fn offsets_are_converted_to_utc() {
        let utc = parse_iso("2024-01-01T12:00:00Z").unwrap();
        // 14:00+02:00 is the same instant as 12:00Z.
        assert_eq!(parse_iso("2024-01-01T14:00:00+02:00"), Some(utc));
        assert_eq!(parse_iso("2024-01-01T14:00:00+0200"), Some(utc));
        assert_eq!(parse_iso("2024-01-01T14:00:00+02"), Some(utc));
        // 07:00-05:00 is also 12:00Z.
        assert_eq!(parse_iso("2024-01-01T07:00:00-05:00"), Some(utc));
        assert_eq!(parse_iso("2024-01-01T17:30:00+05:30"), Some(utc));
    }

    #[test]
    fn zone_presence_is_reported() {
        assert_eq!(parse_iso_full("2024-01-01T00:00:00Z").unwrap().1, true);
        assert_eq!(parse_iso_full("2024-01-01T00:00:00+01:00").unwrap().1, true);
        assert_eq!(parse_iso_full("2024-01-01T00:00:00").unwrap().1, false);
        assert_eq!(parse_iso_full("2024-01-01").unwrap().1, false);
    }

    #[test]
    fn space_separator_and_lowercase_t() {
        let expect = parse_iso("2024-01-01T05:06:07Z");
        assert_eq!(parse_iso("2024-01-01 05:06:07Z"), expect);
        assert_eq!(parse_iso("2024-01-01t05:06:07z"), expect);
        assert_eq!(parse_iso("2024-01-01 05:06:07 Z"), expect);
    }

    #[test]
    fn fractional_seconds_truncate_to_millis() {
        let base = 1_700_000_000_000;
        assert_eq!(parse_iso("2023-11-14T22:13:20.5Z"), Some(base + 500));
        assert_eq!(parse_iso("2023-11-14T22:13:20.123Z"), Some(base + 123));
        assert_eq!(parse_iso("2023-11-14T22:13:20.1239Z"), Some(base + 123));
        assert_eq!(parse_iso("2023-11-14T22:13:20.123456789Z"), Some(base + 123));
    }

    #[test]
    fn minute_precision_is_allowed() {
        assert_eq!(
            parse_iso("2024-01-01T05:06Z"),
            parse_iso("2024-01-01T05:06:00Z")
        );
    }

    #[test]
    fn pre_epoch_dates_work() {
        assert_eq!(parse_iso("1969-12-31T23:59:59.999Z"), Some(-1));
        assert_eq!(parse_iso("1900-01-01"), Some(days_from_civil(1900, 1, 1) * MS_PER_DAY));
    }

    #[test]
    fn invalid_calendar_dates_are_rejected() {
        assert_eq!(parse_iso("2023-02-29"), None); // not a leap year
        assert_eq!(parse_iso("2024-02-30"), None);
        assert_eq!(parse_iso("2024-04-31"), None);
        assert_eq!(parse_iso("2024-00-10"), None);
        assert_eq!(parse_iso("2024-13-01"), None);
        assert_eq!(parse_iso("2024-01-00"), None);
        assert_eq!(parse_iso("0000-01-01"), None);
        assert!(parse_iso("2024-02-29").is_some()); // leap year
    }

    #[test]
    fn invalid_times_are_rejected() {
        assert_eq!(parse_iso("2024-01-01T24:00:00Z"), None);
        assert_eq!(parse_iso("2024-01-01T12:60:00Z"), None);
        // Leap seconds cannot be represented in UTC millis.
        assert_eq!(parse_iso("2024-01-01T23:59:60Z"), None);
        assert_eq!(parse_iso("2024-01-01T12:00:00+25:00"), None);
        assert_eq!(parse_iso("2024-01-01T12:00:00+01:60"), None);
    }

    #[test]
    fn malformed_input_is_rejected_not_panicking() {
        for bad in [
            "", "x", "2024", "2024-01", "not-a-date", "2024/01/01", "2024-1-1",
            "2024-01-01X05:00:00", "2024-01-01T", "2024-01-01T05", "2024-01-01T05:",
            "2024-01-01T05:00:00.", "2024-01-01T05:00:00ZZ", "2024-01-01T05:00:00+",
            "2024-01-01T05:00:00+5", "2024-01-01T05:00:00 trailing", "9999-99-99",
            "２０２４-01-01", "2024-01-01T05:00:00🌍",
        ] {
            assert_eq!(parse_iso(bad), None, "should reject {bad:?}");
        }
    }

    #[test]
    fn surrounding_whitespace_is_tolerated() {
        assert_eq!(parse_iso("  2024-01-01  "), parse_iso("2024-01-01"));
    }

    #[test]
    fn year_first_slash_is_unambiguous() {
        assert_eq!(parse_slash_full("2024/03/09", TimestampFormat::SlashYmd), parse_iso_full("2024-03-09"));
        assert_eq!(
            parse_slash_full("2024/03/09 05:00:00Z", TimestampFormat::SlashYmd),
            parse_iso_full("2024-03-09T05:00:00Z")
        );
    }

    #[test]
    fn detect_prefers_iso() {
        let s = ["2024-01-01T00:00:00Z", "2024-01-02T00:00:00Z"];
        let d = detect(&s, 0.95).unwrap();
        assert_eq!(d.format, Some(TimestampFormat::Iso));
        assert_eq!(d.zoned_count, 2);
        assert_eq!(d.matched, 2);
        assert!(!d.ambiguous_day_month);
    }

    #[test]
    fn detect_reports_missing_offsets() {
        let s = ["2024-01-01 00:00:00", "2024-01-02 00:00:00"];
        let d = detect(&s, 0.95).unwrap();
        assert_eq!(d.format, Some(TimestampFormat::Iso));
        assert_eq!(d.zoned_count, 0);
    }

    #[test]
    fn detect_resolves_day_first_from_evidence() {
        let s = ["01/02/2024", "25/12/2024"];
        let d = detect(&s, 0.95).unwrap();
        assert_eq!(d.format, Some(TimestampFormat::SlashDmy));
        assert_eq!(parse("25/12/2024", d.format.unwrap()), parse_iso("2024-12-25"));
    }

    #[test]
    fn detect_resolves_month_first_from_evidence() {
        let s = ["01/02/2024", "12/25/2024"];
        let d = detect(&s, 0.95).unwrap();
        assert_eq!(d.format, Some(TimestampFormat::SlashMdy));
        assert_eq!(parse("12/25/2024", d.format.unwrap()), parse_iso("2024-12-25"));
    }

    #[test]
    fn ambiguous_day_month_is_refused_not_guessed() {
        let s = ["01/02/2024", "03/04/2024", "05/06/2024"];
        let d = detect(&s, 0.95).unwrap();
        assert_eq!(d.format, None);
        assert!(d.ambiguous_day_month);
    }

    #[test]
    fn self_contradictory_slash_column_is_refused() {
        // 25/12 implies day-first, 12/25 implies month-first: the column is inconsistent.
        let s = ["25/12/2024", "12/25/2024"];
        let d = detect(&s, 0.95).unwrap();
        assert_eq!(d.format, None);
        assert!(d.ambiguous_day_month);
    }

    #[test]
    fn year_first_slash_detected() {
        let s = ["2024/01/01", "2024/02/03"];
        assert_eq!(detect(&s, 0.95).unwrap().format, Some(TimestampFormat::SlashYmd));
    }

    #[test]
    fn non_temporal_columns_are_not_detected() {
        assert!(detect(&["1", "2", "3"], 0.95).is_none());
        assert!(detect(&["alice", "bob"], 0.95).is_none());
        assert!(detect(&["true", "false"], 0.95).is_none());
        // Ratios / version strings must not become dates.
        assert!(detect(&["1/2/3", "4/5/6"], 0.95).is_none());
        assert!(detect(&[], 0.95).is_none());
    }

    #[test]
    fn tolerance_is_honoured() {
        let mut s: Vec<&str> = (0..19).map(|_| "2024-01-01").collect();
        s.push("garbage");
        assert_eq!(detect(&s, 0.95).unwrap().matched, 19);
        // Below tolerance the column must not be typed as temporal.
        assert!(detect(&s, 1.0).is_none());
    }
}
