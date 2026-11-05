//! Pure UTC calendar math shared by ingestion and profiling.
//!
//! **No I/O and no timezone database.** MORPHIC normalizes every temporal value to UTC
//! milliseconds since the Unix epoch, so only proleptic-Gregorian civil-date conversion is
//! needed. The algorithms are Howard Hinnant's `days_from_civil` / `civil_from_days`, which
//! are exact for the whole supported range and handle negative (pre-1970) epochs.
//!
//! Keeping this here (the bottom of the dependency DAG) lets `morphic-ingest` parse and
//! `morphic-semantic` format without either depending on the other.

/// Milliseconds in one UTC day. Leap seconds are not represented (see ingest policy).
pub const MS_PER_DAY: i64 = 86_400_000;

/// Proleptic Gregorian leap year.
pub fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// Days in `month` (1–12) of `year`; 0 for an invalid month.
pub fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(year) => 29,
        2 => 28,
        _ => 0,
    }
}

/// Days since 1970-01-01 for a civil date. Negative before the epoch.
pub fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let m = i64::from(month);
    let mp = if m > 2 { m - 3 } else { m + 9 }; // March = 0
    let doy = (153 * mp + 2) / 5 + i64::from(day) - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146097 + doe - 719468
}

/// Inverse of [`days_from_civil`]: days since the epoch → `(year, month, day)`.
pub fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m as u32, d as u32)
}

/// Format UTC milliseconds as `YYYY-MM-DDTHH:MM:SS.mmmZ`.
///
/// Uses Euclidean division so pre-epoch values format correctly (a plain `/` would put
/// 1969-12-31T23:59:59.999 on the wrong day).
pub fn format_utc_ms(millis: i64) -> String {
    let days = millis.div_euclid(MS_PER_DAY);
    let rem = millis.rem_euclid(MS_PER_DAY);
    let (y, m, d) = civil_from_days(days);
    let secs = rem / 1000;
    let ms = rem % 1000;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        y,
        m,
        d,
        secs / 3600,
        (secs % 3600) / 60,
        secs % 60,
        ms
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_is_zero() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(format_utc_ms(0), "1970-01-01T00:00:00.000Z");
    }

    #[test]
    fn known_reference_dates() {
        // Independently known day counts / epoch values.
        assert_eq!(days_from_civil(2000, 1, 1), 10957);
        assert_eq!(days_from_civil(2024, 1, 1), 19723);
        assert_eq!(format_utc_ms(1_700_000_000_000), "2023-11-14T22:13:20.000Z");
        assert_eq!(format_utc_ms(951_782_400_000), "2000-02-29T00:00:00.000Z");
    }

    #[test]
    fn pre_epoch_uses_euclidean_remainder() {
        assert_eq!(format_utc_ms(-1), "1969-12-31T23:59:59.999Z");
        assert_eq!(days_from_civil(1969, 12, 31), -1);
        assert_eq!(civil_from_days(-1), (1969, 12, 31));
    }

    #[test]
    fn leap_year_rules() {
        assert!(is_leap(2000)); // divisible by 400
        assert!(!is_leap(1900)); // divisible by 100, not 400
        assert!(is_leap(2024));
        assert!(!is_leap(2023));
        assert_eq!(days_in_month(2024, 2), 29);
        assert_eq!(days_in_month(2023, 2), 28);
        assert_eq!(days_in_month(2024, 4), 30);
        assert_eq!(days_in_month(2024, 12), 31);
        assert_eq!(days_in_month(2024, 13), 0);
    }

    #[test]
    fn roundtrips_across_four_centuries() {
        // Every day from 1800 to 2200 must round-trip through both conversions.
        let start = days_from_civil(1800, 1, 1);
        let end = days_from_civil(2200, 1, 1);
        let mut d = start;
        while d < end {
            let (y, m, day) = civil_from_days(d);
            assert_eq!(days_from_civil(y, m, day), d, "roundtrip failed at day {d}");
            assert!((1..=12).contains(&m));
            assert!((1..=days_in_month(y, m)).contains(&day));
            d += 1;
        }
    }

    #[test]
    fn formatting_is_zero_padded_and_sortable() {
        let a = format_utc_ms(days_from_civil(2024, 3, 9) * MS_PER_DAY + 5 * 3_600_000);
        assert_eq!(a, "2024-03-09T05:00:00.000Z");
        // Lexicographic order matches chronological order for same-width years.
        assert!(a < format_utc_ms(days_from_civil(2024, 3, 10) * MS_PER_DAY));
    }
}
