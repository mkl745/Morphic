//! Chart scenes: the pre-aggregated shapes a painter receives (M1.4 task 1.4.1).
//!
//! docs/architecture/02 §2.5 is explicit that `ChartSeries` is **pre-aggregated in Rust** and
//! that "charts never receive raw tables". This module is where that promise is kept. A painter
//! gets buckets and totals, never rows, so it cannot compute a different answer from the one the
//! engine holds.
//!
//! # Three shapes, three contracts
//!
//! | Shape | Ceiling | Remainder |
//! |---|---|---|
//! | [`CategoryScene`] | binding `limit` bars | an **`Other`** bucket, re-aggregated from rows |
//! | [`SeriesScene`] | [`MAX_CHART_POINTS`] pts, [`MAX_SERIES`] series | reported, never dropped |
//! | [`TimelineScene`] | [`MAX_CHART_POINTS`] buckets | merged into wider buckets, flagged |
//!
//! # Decisions worth stating
//!
//! 1. **`Other` is re-aggregated, not subtracted.** For `count` and `sum` the remainder could be
//!    grand total minus the top N. For `avg`, `min`, `max` and `distinct_count` that arithmetic is
//!    simply wrong — an average of averages is not an average. So the remainder is always
//!    computed by aggregating the rows that did not make the cut. One extra pass buys an answer
//!    that is correct for every operator.
//! 2. **Buckets are fixed durations, not calendar units.** A "month" bucket is 30 days. Calendar
//!    months vary and calendar days vary under DST; pretending otherwise introduces a class of
//!    off-by-one bugs this project has no timezone database to solve. The bucket width in
//!    milliseconds is part of the scene, so a painter and a reader can always see what was used.
//! 3. **Auto-granularity picks the finest bucket that fits**, rather than picking a bucket and
//!    then throwing points away. Downsampling is the fallback when even the coarsest named step
//!    overflows, and it is reported.
//! 4. **An empty bucket is not always zero.** `count` of nothing is 0. An `avg`, `min` or `max` of
//!    nothing is *unknown*, and is sent as a null so a line has a gap instead of diving to zero
//!    and inventing a trend.
//! 5. **Truncation is always visible.** Every scene carries the true total alongside what it
//!    returned. Returning the first 2000 groups and calling it the whole answer is the failure
//!    mode this module exists to avoid.

use std::collections::{BTreeMap, HashSet};

use morphic_model::{Column, ColumnValues, Table};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::filter::is_null;
use crate::group::AggSpec;
use crate::{Aggregate, QueryError};

/// Point ceiling shared by every chart (docs/architecture/03 §4, registry §2).
pub const MAX_CHART_POINTS: usize = 2000;

/// Legend ceiling for a multi-series line chart (docs/architecture/04 §2).
pub const MAX_SERIES: usize = 8;

/// Distinct categories accumulated before a top-N is chosen.
///
/// This is deliberately larger than [`crate::MAX_GROUPS`]: the *output* of a bar chart is a few
/// dozen bars, but choosing the true top few dozen requires seeing every category. Capping the
/// intermediate groups at the output ceiling would pick the top N from whichever categories
/// happened to appear first, which is not a top N at all.
pub const MAX_CATEGORY_GROUPS: usize = 100_000;

/// Label used for the remainder bucket. A painter may localise it; the engine's contract is the
/// `other` field, not this string.
pub const OTHER_LABEL: &str = "Other";

// --- bucketing -----------------------------------------------------------------------------

/// How the time axis was divided. The width is authoritative; `label` is for humans.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Bucketing {
    pub bucket_ms: i64,
    pub label: String,
    /// True when even the coarsest named step overflowed and adjacent buckets were merged.
    pub downsampled: bool,
}

/// Named steps, finest first. Fixed durations — see decision 2 in the module docs.
const LADDER: &[(i64, &str)] = &[
    (1_000, "1s"),
    (5_000, "5s"),
    (15_000, "15s"),
    (30_000, "30s"),
    (60_000, "1m"),
    (300_000, "5m"),
    (900_000, "15m"),
    (1_800_000, "30m"),
    (3_600_000, "1h"),
    (10_800_000, "3h"),
    (21_600_000, "6h"),
    (43_200_000, "12h"),
    (86_400_000, "1d"),
    (172_800_000, "2d"),
    (604_800_000, "7d"),
    (2_592_000_000, "30d"),
    (7_776_000_000, "90d"),
    (31_536_000_000, "365d"),
];

/// Choose the finest bucket width whose bucket count fits `max_points`.
///
/// `span_ms` is the distance between the first and last timestamp, so a single instant has span
/// 0 and takes the finest step. When no named step fits, the coarsest is widened by an integer
/// stride and [`Bucketing::downsampled`] is set — the scene then says it merged buckets rather
/// than implying the data was this coarse to begin with.
pub fn auto_bucket(span_ms: i64, max_points: usize) -> Bucketing {
    let cap = max_points.clamp(2, MAX_CHART_POINTS) as i64;
    let span = span_ms.max(0);
    for (ms, label) in LADDER {
        let buckets = span / ms + 1;
        if buckets <= cap {
            return Bucketing {
                bucket_ms: *ms,
                label: (*label).to_string(),
                downsampled: false,
            };
        }
    }
    let (coarsest, _) = LADDER[LADDER.len() - 1];
    let buckets = span / coarsest + 1;
    // Integer ceiling division: how many coarse buckets must merge to fit the ceiling.
    let stride = buckets.div_euclid(cap) + i64::from(buckets % cap != 0);
    let width = coarsest.saturating_mul(stride.max(1));
    Bucketing {
        bucket_ms: width,
        label: format!("{}d (merged)", width / 86_400_000),
        downsampled: true,
    }
}

/// Floor `v` to a multiple of `bucket`, including before the epoch.
///
/// `v / bucket` truncates toward zero, which puts -1 and +1 in the same bucket and makes the
/// bucket containing the epoch twice as wide as every other. Euclidean division does not.
fn bucket_floor(v: i64, bucket: i64) -> i64 {
    v.div_euclid(bucket).saturating_mul(bucket)
}

// --- scene types ---------------------------------------------------------------------------

/// One bar. `value` is null when the aggregation is undefined for the group (an average of no
/// non-null cells), which is different from zero.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CategoryPoint {
    /// Null for the null-valued category, which is a real group and not the same as "".
    pub label: Option<String>,
    pub value: Option<f64>,
    pub row_count: usize,
}

/// Top-N categories plus an honest remainder.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CategoryScene {
    pub dimension: String,
    /// Output name of the measure, e.g. `avg_amount`.
    pub measure: String,
    pub points: Vec<CategoryPoint>,
    /// Re-aggregated over every row outside the top N. Absent when nothing was left over.
    pub other: Option<CategoryPoint>,
    /// Distinct categories seen, including any beyond [`MAX_CATEGORY_GROUPS`].
    pub total_categories: usize,
    /// True when categories exceeded the accumulation cap, so the top N is chosen from a prefix
    /// and is not guaranteed to be the true top N. A painter must say so.
    pub truncated: bool,
}

/// One point of a series. `y` null means "no value here", which a line should draw as a gap.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SeriesPoint {
    /// Bucket start: UTC milliseconds for a temporal x, the bucket's lower bound for a numeric x.
    pub x: f64,
    pub y: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Series {
    /// The group value, or the measure's name for an ungrouped chart.
    pub name: Option<String>,
    pub points: Vec<SeriesPoint>,
}

/// Bucketed line-chart data.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SeriesScene {
    pub x_field: String,
    /// True when x was a timestamp column, so `bucketing` is in milliseconds of time.
    pub temporal: bool,
    pub bucketing: Bucketing,
    pub series: Vec<Series>,
    /// Groups seen before the [`MAX_SERIES`] cut.
    pub total_series: usize,
    /// True when groups exceeded [`MAX_SERIES`]. The dropped series are not summed into an
    /// "Other" line: adding averages together would be meaningless, and a fabricated total is
    /// worse than an honest count of what is missing.
    pub truncated_series: bool,
    /// Points the painter receives, summed across series.
    pub total_points: usize,
}

/// Per-lane count within a timeline bucket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LaneCount {
    pub lane: Option<String>,
    pub count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TimelineBucket {
    pub start_ms: i64,
    pub count: usize,
    pub lanes: Vec<LaneCount>,
}

/// Density buckets with severity lanes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TimelineScene {
    pub time_field: String,
    pub bucketing: Bucketing,
    /// Lane order, most frequent first, so a painter's legend is stable across revisions.
    pub lanes: Vec<Option<String>>,
    pub buckets: Vec<TimelineBucket>,
    pub total_buckets: usize,
    pub total_lanes: usize,
    pub truncated_lanes: bool,
    /// Rows whose time was null and so belong to no bucket.
    pub unbucketed_rows: usize,
}

/// The tagged union that crosses FFI. One endpoint, three shapes, discriminated by `kind`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ChartScene {
    Category(CategoryScene),
    Series(SeriesScene),
    Timeline(TimelineScene),
}

// --- helpers -------------------------------------------------------------------------------

fn numeric(col: &Column, row: usize) -> Option<f64> {
    if is_null(col, row) {
        return None;
    }
    match &col.values {
        ColumnValues::Int64(v) => v.get(row).map(|n| *n as f64),
        ColumnValues::Float64(v) => v.get(row).copied(),
        ColumnValues::Timestamp(v) => v.get(row).map(|n| *n as f64),
        _ => None,
    }
}

fn json_label(v: &Value) -> Option<String> {
    match v {
        Value::Null => None,
        Value::String(s) => Some(s.clone()),
        other => Some(other.to_string()),
    }
}

/// The text key the group executor uses, so scene code and group code agree on identity.
fn text_key(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn value_of(v: &Value) -> Option<f64> {
    v.as_f64().or_else(|| v.as_i64().map(|n| n as f64))
}

/// Extent of a column over a selection, ignoring nulls.
fn extent(col: &Column, rows: &[usize]) -> Option<(f64, f64)> {
    let mut lo: Option<f64> = None;
    let mut hi: Option<f64> = None;
    for r in rows {
        if let Some(v) = numeric(col, *r) {
            lo = Some(lo.map_or(v, |c: f64| c.min(v)));
            hi = Some(hi.map_or(v, |c: f64| c.max(v)));
        }
    }
    Some((lo?, hi?))
}

// --- category (bar) ------------------------------------------------------------------------

/// Display order of the bars a chart keeps (M1.4 task 1.4.2's sort toggle).
///
/// This orders the bars **after** the top-N cut. Selection is always by measure magnitude:
/// "the twelve biggest, alphabetically" must still be the twelve biggest. Letting a label sort
/// choose which categories survive would quietly drop the largest bars, which is the opposite
/// of what the chart is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum CategoryOrder {
    #[default]
    MeasureDesc,
    MeasureAsc,
    LabelAsc,
    LabelDesc,
}

/// Top-N categories by measure, descending, with the remainder re-aggregated into `Other`.
///
/// Ties break on the label so the same data always produces the same bars — a chart whose bars
/// reorder between revisions for no reason looks like a bug even when every value is right.
pub fn category_scene(
    table: &Table,
    rows: &[usize],
    dimension: &str,
    agg: &Aggregate<'_>,
    limit: usize,
) -> Result<CategoryScene, QueryError> {
    category_scene_ordered(table, rows, dimension, agg, limit, CategoryOrder::default())
}

/// [`category_scene`] with an explicit display order for the kept bars.
pub fn category_scene_ordered(
    table: &Table,
    rows: &[usize],
    dimension: &str,
    agg: &Aggregate<'_>,
    limit: usize,
    order: CategoryOrder,
) -> Result<CategoryScene, QueryError> {
    let dim = crate::find_column(table, dimension)?;
    let spec = AggSpec::new(agg.op, agg.field);
    let dims = [dimension.to_string()];
    crate::group::validate(table, &dims, std::slice::from_ref(&spec))?;

    // One pass carries both the measure and a row count. Two passes would double the work for
    // a fact (`row_count`) the accumulator already knows.
    let count_spec = AggSpec::new("count", None);
    let grouped = crate::group::execute_capped(
        table,
        rows,
        &dims,
        &[spec.clone(), count_spec],
        MAX_CATEGORY_GROUPS,
        None,
    )?;

    let mut points: Vec<(String, CategoryPoint)> = grouped
        .rows
        .iter()
        .map(|r| {
            (
                text_key(&r[0]),
                CategoryPoint {
                    label: json_label(&r[0]),
                    value: value_of(&r[1]),
                    row_count: value_of(&r[2]).unwrap_or(0.0) as usize,
                },
            )
        })
        .collect();

    // Nulls sort last regardless of direction, matching the table's policy: an absent category
    // is not the smallest one. Ties break on the label so bars never reorder for no reason.
    points.sort_by(|a, b| {
        // The *category* being null is what sorts last, not its measure being undefined. A null
        // region with a large average is still an absent category, and floating it to the top
        // would contradict the nulls-last policy the table and its sort chip already promise.
        match (a.1.label.is_none(), b.1.label.is_none()) {
            (true, false) => return std::cmp::Ordering::Greater,
            (false, true) => return std::cmp::Ordering::Less,
            _ => {}
        }
        match (&a.1.value, &b.1.value) {
            (Some(x), Some(y)) => y.total_cmp(x),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        }
        .then_with(|| a.1.label.cmp(&b.1.label))
    });

    let keep = limit.clamp(1, crate::MAX_GROUPS);
    let total_categories = grouped.total_groups;
    let kept: HashSet<String> = points.iter().take(keep).map(|(k, _)| k.clone()).collect();
    let remainder = points.len() > keep;
    let mut points: Vec<CategoryPoint> = points.into_iter().take(keep).map(|(_, p)| p).collect();
    // Re-order only what survived the cut. Nulls stay last under every order: an absent
    // category is not the smallest one, whichever axis the user sorted by.
    points.sort_by(|a, b| {
        match (a.label.is_none(), b.label.is_none()) {
            (true, false) => return std::cmp::Ordering::Greater,
            (false, true) => return std::cmp::Ordering::Less,
            _ => {}
        }
        let primary = match order {
            CategoryOrder::LabelAsc => a.label.cmp(&b.label),
            CategoryOrder::LabelDesc => b.label.cmp(&a.label),
            CategoryOrder::MeasureDesc | CategoryOrder::MeasureAsc => {
                match (&a.value, &b.value) {
                    (Some(x), Some(y)) => {
                        if order == CategoryOrder::MeasureAsc {
                            x.total_cmp(y)
                        } else {
                            y.total_cmp(x)
                        }
                    }
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    (None, None) => std::cmp::Ordering::Equal,
                }
            }
        };
        // A stable tiebreak keeps bars from swapping between revisions when values are equal.
        primary.then_with(|| a.label.cmp(&b.label))
    });

    let other = if remainder {
        // Re-aggregated from the rows, never subtracted from a total: an average of averages is
        // not an average, and min/max/distinct do not subtract at all.
        let rest: Vec<usize> = rows
            .iter()
            .copied()
            .filter(|r| !kept.contains(&crate::cell_text(dim, *r)))
            .collect();
        Some(CategoryPoint {
            label: Some(OTHER_LABEL.to_string()),
            value: value_of(&crate::aggregate_over(table, Some(&rest), agg)?),
            row_count: rest.len(),
        })
    } else {
        None
    };

    Ok(CategoryScene {
        dimension: dimension.to_string(),
        measure: spec.label_public(),
        points,
        other,
        total_categories,
        truncated: grouped.truncated,
    })
}

// --- series (line) -------------------------------------------------------------------------

/// What a series scene is built from. A struct rather than seven positional arguments.
#[derive(Debug, Clone, Copy)]
pub struct SeriesSpec<'a> {
    pub x: &'a str,
    pub agg: Aggregate<'a>,
    pub group_by: Option<&'a str>,
}

/// Bucketed series over a temporal or numeric x.
pub fn series_scene(
    table: &Table,
    rows: &[usize],
    spec: &SeriesSpec<'_>,
) -> Result<SeriesScene, QueryError> {
    let xcol = crate::find_column(table, spec.x)?;
    let temporal = matches!(xcol.values, ColumnValues::Timestamp(_));
    if !temporal
        && !matches!(
            xcol.values,
            ColumnValues::Int64(_) | ColumnValues::Float64(_)
        )
    {
        // A text x cannot be bucketed. The compiler should not propose one; when it does, fail
        // loudly rather than inventing an ordering from string comparison.
        return Err(QueryError::NotNumeric {
            field: xcol.name.clone(),
            dtype: xcol.dtype.as_str().to_string(),
        });
    }
    crate::group::validate(
        table,
        &[],
        std::slice::from_ref(&AggSpec::new(spec.agg.op, spec.agg.field)),
    )?;

    // Partition rows into series first, so the series cut happens before any bucket work.
    let gcol = match spec.group_by {
        None => None,
        Some(name) => Some(crate::find_column(table, name)?),
    };
    let mut partitions: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for r in rows {
        let key = match gcol {
            None => String::new(),
            Some(c) => crate::cell_text(c, *r),
        };
        partitions.entry(key).or_default().push(*r);
    }
    let total_series = partitions.len();
    let mut ordered: Vec<(String, Vec<usize>)> = partitions.into_iter().collect();
    if gcol.is_some() {
        // Largest series first, ties by name: a legend that reshuffles on every revision is
        // unusable, and "first eight encountered" depends on row order the user just changed.
        ordered.sort_by(|a, b| b.1.len().cmp(&a.1.len()).then_with(|| a.0.cmp(&b.0)));
    }
    let truncated_series = ordered.len() > MAX_SERIES;
    ordered.truncate(MAX_SERIES);

    // The ceiling is the TOTAL number of points a painter receives, not a per-series allowance:
    // eight series of 2000 points is 16000 points to draw, which is the cost the ceiling exists
    // to bound. So the axis is bucketed to fit the ceiling divided by the series actually kept.
    let per_series_cap = (MAX_CHART_POINTS / ordered.len().max(1)).max(2);
    let (lo, hi) = extent(xcol, rows).unwrap_or((0.0, 0.0));
    let bucketing = if temporal {
        auto_bucket((hi - lo) as i64, per_series_cap)
    } else {
        numeric_bucket(hi - lo, per_series_cap)
    };

    let mut series = Vec::new();
    let mut total_points = 0usize;
    for (name, part) in ordered {
        let mut buckets: BTreeMap<i64, Vec<usize>> = BTreeMap::new();
        for r in &part {
            if let Some(v) = numeric(xcol, *r) {
                buckets
                    .entry(bucket_floor(v as i64, bucketing.bucket_ms))
                    .or_default()
                    .push(*r);
            }
        }
        let mut points = Vec::with_capacity(buckets.len());
        // Emit every bucket in the span, not only the non-empty ones, so a gap is visible as a
        // gap. Skipping empties would silently compress the x axis and misrepresent timing.
        let start = bucket_floor(lo as i64, bucketing.bucket_ms);
        let end = bucket_floor(hi as i64, bucketing.bucket_ms);
        let mut at = start;
        while at <= end && points.len() < per_series_cap {
            let y = match buckets.get(&at) {
                None => empty_value(spec.agg.op),
                Some(rs) => value_of(&crate::aggregate_over(table, Some(rs), &spec.agg)?),
            };
            points.push(SeriesPoint { x: at as f64, y });
            at = at.saturating_add(bucketing.bucket_ms);
        }
        total_points += points.len();
        series.push(Series {
            name: gcol.map(|_| name),
            points,
        });
    }

    Ok(SeriesScene {
        x_field: spec.x.to_string(),
        temporal,
        bucketing,
        series,
        total_series,
        truncated_series,
        total_points,
    })
}

/// `count` of an empty bucket is zero; the others are undefined and become a gap.
fn empty_value(op: &str) -> Option<f64> {
    match op {
        "count" | "sum" | "distinct_count" => Some(0.0),
        _ => None,
    }
}

/// A 1/2/5 × 10^k step, the same ladder a human would pick for a numeric axis.
fn numeric_bucket(span: f64, max_points: usize) -> Bucketing {
    let cap = max_points.clamp(2, MAX_CHART_POINTS) as f64;
    if !(span.is_finite() && span > 0.0) {
        return Bucketing {
            bucket_ms: 1,
            label: "1".to_string(),
            downsampled: false,
        };
    }
    let raw = span / cap;
    let magnitude = 10f64.powf(raw.log10().floor());
    let mut step = magnitude * 10.0;
    for m in [1.0, 2.0, 5.0, 10.0] {
        if magnitude * m >= raw {
            step = magnitude * m;
            break;
        }
    }
    // The width is an integer count of x units, so a step below 1 cannot be represented. Rather
    // than silently bucketing everything together, widen to 1 and say the axis was merged.
    let merged = step < 1.0;
    Bucketing {
        bucket_ms: step.max(1.0) as i64,
        label: if merged {
            "1 (merged)".to_string()
        } else {
            format!("{step}")
        },
        downsampled: merged,
    }
}

// --- timeline ------------------------------------------------------------------------------

/// What a timeline scene is built from.
#[derive(Debug, Clone, Copy)]
pub struct TimelineSpec<'a> {
    pub time_field: &'a str,
    pub severity_field: Option<&'a str>,
}

/// Per-bucket counters while a timeline is being built.
struct Dens {
    count: usize,
    lanes: Vec<usize>,
}

/// Density buckets with severity lanes, for the log-shaped datasets the timeline exists for.
pub fn timeline_scene(
    table: &Table,
    rows: &[usize],
    spec: &TimelineSpec<'_>,
) -> Result<TimelineScene, QueryError> {
    let tcol = crate::find_column(table, spec.time_field)?;
    if !matches!(tcol.values, ColumnValues::Timestamp(_)) {
        return Err(QueryError::NotNumeric {
            field: tcol.name.clone(),
            dtype: tcol.dtype.as_str().to_string(),
        });
    }
    let scol = match spec.severity_field {
        None => None,
        Some(name) => Some(crate::find_column(table, name)?),
    };

    let mut times: Vec<(usize, i64)> = rows
        .iter()
        .filter_map(|r| numeric(tcol, *r).map(|v| (*r, v as i64)))
        .collect();
    let unbucketed_rows = rows.len() - times.len();
    if times.is_empty() {
        return Ok(TimelineScene {
            time_field: spec.time_field.to_string(),
            bucketing: auto_bucket(0, MAX_CHART_POINTS),
            lanes: Vec::new(),
            buckets: Vec::new(),
            total_buckets: 0,
            total_lanes: 0,
            truncated_lanes: false,
            unbucketed_rows,
        });
    }
    times.sort_by_key(|(_, t)| *t);
    let span = times[times.len() - 1].1 - times[0].1;
    let bucketing = auto_bucket(span, MAX_CHART_POINTS);

    // Lane order by frequency, so the legend and the colour assignment are stable.
    let mut lane_counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut lane_labels: BTreeMap<String, Option<String>> = BTreeMap::new();
    for (r, _) in &times {
        if let Some(c) = scol {
            let key = crate::cell_text(c, *r);
            *lane_counts.entry(key.clone()).or_default() += 1;
            lane_labels
                .entry(key.clone())
                .or_insert_with(|| json_label(&crate::cell_json(c, *r)));
        }
    }
    let total_lanes = lane_counts.len();
    let mut lane_order: Vec<(String, usize)> = lane_counts.into_iter().collect();
    lane_order.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let truncated_lanes = lane_order.len() > MAX_SERIES;
    lane_order.truncate(MAX_SERIES);
    let kept: Vec<String> = lane_order.iter().map(|(k, _)| k.clone()).collect();
    let lanes: Vec<Option<String>> = kept
        .iter()
        .map(|k| lane_labels.get(k).cloned().unwrap_or(None))
        .collect();

    let lane_index: BTreeMap<String, usize> = kept
        .iter()
        .enumerate()
        .map(|(i, k)| (k.clone(), i))
        .collect();
    // Counters are aligned to `kept` by position, not matched by display label: the null lane
    // and an empty-string lane both render as None, and matching on the label would merge them.
    let mut dens: BTreeMap<i64, Dens> = BTreeMap::new();
    for (r, time) in &times {
        let at = bucket_floor(*time, bucketing.bucket_ms);
        let d = dens.entry(at).or_insert_with(|| Dens {
            count: 0,
            lanes: vec![0; kept.len()],
        });
        d.count += 1;
        if let Some(c) = scol {
            if let Some(pos) = lane_index.get(&crate::cell_text(c, *r)) {
                d.lanes[*pos] += 1;
            }
        }
    }
    let buckets: Vec<TimelineBucket> = dens
        .into_iter()
        .map(|(at, d)| TimelineBucket {
            start_ms: at,
            count: d.count,
            lanes: d
                .lanes
                .iter()
                .enumerate()
                .filter(|(_, n)| **n > 0)
                .map(|(i, n)| LaneCount {
                    lane: lanes[i].clone(),
                    count: *n,
                })
                .collect(),
        })
        .collect();
    let total_buckets = buckets.len();
    Ok(TimelineScene {
        time_field: spec.time_field.to_string(),
        bucketing,
        lanes,
        buckets,
        total_buckets,
        total_lanes,
        truncated_lanes,
        unbucketed_rows,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    use morphic_model::DataType;

    fn col(name: &str, values: ColumnValues, nulls: Vec<bool>) -> Column {
        let dtype = match &values {
            ColumnValues::Int64(_) => DataType::Int64,
            ColumnValues::Float64(_) => DataType::Float64,
            ColumnValues::Timestamp(_) => DataType::Timestamp,
            _ => DataType::Utf8,
        };
        Column {
            name: name.into(),
            dtype,
            values,
            nulls,
        }
    }

    fn strings(v: &[&str]) -> ColumnValues {
        ColumnValues::Utf8(v.iter().map(|s| s.to_string()).collect())
    }

    /// Four categories plus a null one, sized so that averaging the group averages gives a
    /// different answer from aggregating the underlying rows.
    fn cats() -> Table {
        Table {
            columns: vec![
                col(
                    "region",
                    strings(&["a", "a", "b", "c", "c", "d", "ignored"]),
                    vec![false, false, false, false, false, false, true],
                ),
                col(
                    "amount",
                    ColumnValues::Float64(vec![10.0, 30.0, 100.0, 2.0, 6.0, 8.0, 50.0]),
                    vec![false; 7],
                ),
            ],
            row_count: 7,
        }
    }

    fn all(t: &Table) -> Vec<usize> {
        (0..t.row_count).collect()
    }

    fn labels(s: &CategoryScene) -> Vec<Option<String>> {
        s.points.iter().map(|p| p.label.clone()).collect()
    }

    // --- display order (M1.4 task 1.4.2) -------------------------------------------------

    fn ordered(t: &Table, limit: usize, order: CategoryOrder) -> CategoryScene {
        category_scene_ordered(
            t,
            &all(t),
            "region",
            &Aggregate {
                op: "avg",
                field: Some("amount"),
            },
            limit,
            order,
        )
        .unwrap()
    }

    #[test]
    fn label_order_does_not_change_which_bars_survive_the_cut() {
        // cats(): b=100, a=20, d=8, c=4, null=50. The two biggest are b and a. Sorting by
        // label must reorder those two, NOT promote a and c because they sort first
        // alphabetically — that would silently drop the largest bar.
        let t = cats();
        let by_measure = ordered(&t, 2, CategoryOrder::MeasureDesc);
        let by_label = ordered(&t, 2, CategoryOrder::LabelAsc);
        assert_eq!(labels(&by_measure), vec![Some("b".into()), Some("a".into())]);
        assert_eq!(labels(&by_label), vec![Some("a".into()), Some("b".into())]);
        let mut m: Vec<_> = labels(&by_measure);
        let mut l: Vec<_> = labels(&by_label);
        m.sort();
        l.sort();
        assert_eq!(m, l, "the same categories must survive under every order");
        assert_eq!(by_label.total_categories, by_measure.total_categories);
    }

    #[test]
    fn label_desc_reverses_the_kept_bars() {
        assert_eq!(
            labels(&ordered(&cats(), 2, CategoryOrder::LabelDesc)),
            vec![Some("b".into()), Some("a".into())]
        );
    }

    #[test]
    fn measure_asc_orders_smallest_first_within_the_cut() {
        let s = ordered(&cats(), 2, CategoryOrder::MeasureAsc);
        assert_eq!(labels(&s), vec![Some("a".into()), Some("b".into())]);
        assert_eq!(s.points[0].value, Some(20.0));
        assert_eq!(s.points[1].value, Some(100.0));
    }

    #[test]
    fn nulls_stay_last_under_every_order() {
        let t = cats();
        for order in [
            CategoryOrder::MeasureDesc,
            CategoryOrder::MeasureAsc,
            CategoryOrder::LabelAsc,
            CategoryOrder::LabelDesc,
        ] {
            let s = ordered(&t, 5, order);
            assert_eq!(s.points.last().unwrap().label, None, "{order:?} floated the null");
        }
    }

    #[test]
    fn the_other_bucket_does_not_depend_on_display_order() {
        let t = cats();
        let a = ordered(&t, 2, CategoryOrder::MeasureDesc);
        let b = ordered(&t, 2, CategoryOrder::LabelAsc);
        assert_eq!(a.other, b.other, "the remainder is the same rows either way");
        assert_eq!(a.other.as_ref().unwrap().row_count, 5);
    }

    #[test]
    fn top_n_orders_by_measure_descending() {
        let t = cats();
        let s = category_scene(
            &t,
            &all(&t),
            "region",
            &Aggregate {
                op: "avg",
                field: Some("amount"),
            },
            2,
        )
        .unwrap();
        assert_eq!(labels(&s), vec![Some("b".into()), Some("a".into())]);
        assert_eq!(s.points[0].value, Some(100.0));
        assert_eq!(s.points[1].value, Some(20.0));
        assert_eq!(s.points[1].row_count, 2);
        assert_eq!(s.total_categories, 5);
        assert_eq!(s.measure, "avg_amount");
    }

    #[test]
    fn other_is_reaggregated_not_averaged_from_group_averages() {
        let t = cats();
        let s = category_scene(
            &t,
            &all(&t),
            "region",
            &Aggregate {
                op: "avg",
                field: Some("amount"),
            },
            2,
        )
        .unwrap();
        let other = s.other.expect("four categories were left over");
        // Remaining rows are 2, 6, 8, 50 -> 66/4 = 16.5. Averaging the remaining *group*
        // averages (4, 8, 50) would give 20.67, and weighting them wrongly is the classic bug.
        assert_eq!(other.value, Some(16.5));
        assert_eq!(other.row_count, 4);
        assert_eq!(other.label, Some(OTHER_LABEL.into()));
    }

    #[test]
    fn null_category_sorts_last_regardless_of_its_value() {
        let t = cats();
        // The null category averages 50, which would place it second by value alone.
        let s = category_scene(
            &t,
            &all(&t),
            "region",
            &Aggregate {
                op: "avg",
                field: Some("amount"),
            },
            5,
        )
        .unwrap();
        assert_eq!(labels(&s).last(), Some(&None));
        assert_eq!(s.points.len(), 5);
        // By value alone the null category (50) would have come second.
        assert_eq!(labels(&s)[1], Some("a".into()));
    }

    #[test]
    fn ties_break_on_label_so_bars_never_reorder() {
        let t = cats();
        let s = category_scene(
            &t,
            &all(&t),
            "region",
            &Aggregate {
                op: "count",
                field: None,
            },
            2,
        )
        .unwrap();
        // "a" and "c" both have two rows; the label decides, not encounter order.
        assert_eq!(labels(&s), vec![Some("a".into()), Some("c".into())]);
    }

    #[test]
    fn no_other_bucket_when_every_category_fits() {
        let t = cats();
        let s = category_scene(
            &t,
            &all(&t),
            "region",
            &Aggregate {
                op: "count",
                field: None,
            },
            50,
        )
        .unwrap();
        assert!(s.other.is_none());
        assert_eq!(s.points.len(), 5);
        assert!(!s.truncated);
    }

    #[test]
    fn other_is_exact_for_count_too() {
        let t = cats();
        let s = category_scene(
            &t,
            &all(&t),
            "region",
            &Aggregate {
                op: "count",
                field: None,
            },
            2,
        )
        .unwrap();
        let other = s.other.unwrap();
        assert_eq!(other.value, Some(3.0));
        assert_eq!(other.row_count, 3);
    }

    #[test]
    fn auto_bucket_picks_the_finest_step_that_fits() {
        // Five seconds across two points cannot use 1s buckets; 5s fits exactly.
        let b = auto_bucket(5_000, 2);
        assert_eq!(b.bucket_ms, 5_000);
        assert!(!b.downsampled);
        // With room for 2000 points the finest step is chosen.
        assert_eq!(auto_bucket(5_000, 2000).bucket_ms, 1_000);
        assert_eq!(auto_bucket(0, 2000).bucket_ms, 1_000);
    }

    #[test]
    fn auto_bucket_merges_and_admits_it_when_nothing_fits() {
        // A century in two points: no named step is coarse enough.
        let b = auto_bucket(3_153_600_000_000, 2);
        assert!(b.downsampled);
        assert!(b.label.contains("merged"));
        assert!(b.bucket_ms > 31_536_000_000);
    }

    #[test]
    fn bucket_floor_is_euclidean_before_the_epoch() {
        // Truncating division would put -1 and +1 in the same bucket, making the bucket that
        // contains the epoch twice as wide as its neighbours.
        assert_eq!(bucket_floor(1, 1000), 0);
        assert_eq!(bucket_floor(-1, 1000), -1000);
        assert_eq!(bucket_floor(-1000, 1000), -1000);
        assert_eq!(bucket_floor(-1001, 1000), -2000);
    }

    fn times() -> Table {
        Table {
            columns: vec![
                col(
                    "t",
                    ColumnValues::Timestamp(vec![0, 1000, 5000, 0]),
                    vec![false, false, false, true],
                ),
                col(
                    "v",
                    ColumnValues::Float64(vec![10.0, 20.0, 50.0, 999.0]),
                    vec![false; 4],
                ),
                col("g", strings(&["x", "x", "y", "y"]), vec![false; 4]),
            ],
            row_count: 4,
        }
    }

    #[test]
    fn empty_buckets_are_emitted_so_gaps_stay_visible() {
        let t = times();
        let s = series_scene(
            &t,
            &all(&t),
            &SeriesSpec {
                x: "t",
                agg: Aggregate {
                    op: "avg",
                    field: Some("v"),
                },
                group_by: None,
            },
        )
        .unwrap();
        assert!(s.temporal);
        assert_eq!(s.bucketing.bucket_ms, 1_000);
        let pts = &s.series[0].points;
        // Buckets 0..5000 inclusive: six points, three of them empty.
        assert_eq!(pts.len(), 6);
        assert_eq!(pts[0].y, Some(10.0));
        assert_eq!(pts[1].y, Some(20.0));
        // An average of nothing is unknown, not zero — a line must gap here, not dive.
        assert_eq!(pts[2].y, None);
        assert_eq!(pts[5].y, Some(50.0));
    }

    #[test]
    fn count_of_an_empty_bucket_is_zero_not_a_gap() {
        let t = times();
        let s = series_scene(
            &t,
            &all(&t),
            &SeriesSpec {
                x: "t",
                agg: Aggregate {
                    op: "count",
                    field: None,
                },
                group_by: None,
            },
        )
        .unwrap();
        assert_eq!(s.series[0].points[2].y, Some(0.0));
    }

    #[test]
    fn a_null_timestamp_belongs_to_no_bucket() {
        let t = times();
        let s = timeline_scene(
            &t,
            &all(&t),
            &TimelineSpec {
                time_field: "t",
                severity_field: Some("g"),
            },
        )
        .unwrap();
        assert_eq!(s.unbucketed_rows, 1);
        assert_eq!(s.buckets.iter().map(|b| b.count).sum::<usize>(), 3);
    }

    #[test]
    fn timeline_lane_counts_sum_to_the_bucket_count() {
        let t = times();
        let s = timeline_scene(
            &t,
            &all(&t),
            &TimelineSpec {
                time_field: "t",
                severity_field: Some("g"),
            },
        )
        .unwrap();
        assert_eq!(s.total_lanes, 2);
        assert!(!s.truncated_lanes);
        for b in &s.buckets {
            assert_eq!(b.lanes.iter().map(|l| l.count).sum::<usize>(), b.count);
        }
    }

    #[test]
    fn timeline_rejects_a_non_temporal_field() {
        let t = times();
        let e = timeline_scene(
            &t,
            &all(&t),
            &TimelineSpec {
                time_field: "v",
                severity_field: None,
            },
        )
        .unwrap_err();
        assert!(matches!(e, QueryError::NotNumeric { .. }));
    }

    #[test]
    fn series_rejects_a_text_x() {
        let t = times();
        let e = series_scene(
            &t,
            &all(&t),
            &SeriesSpec {
                x: "g",
                agg: Aggregate {
                    op: "count",
                    field: None,
                },
                group_by: None,
            },
        )
        .unwrap_err();
        assert!(matches!(e, QueryError::NotNumeric { .. }));
    }

    #[test]
    fn series_are_capped_at_eight_and_report_the_remainder() {
        let n = 30;
        let names: Vec<String> = (0..n).map(|i| format!("g{i}")).collect();
        let refs: Vec<&str> = names.iter().map(String::as_str).collect();
        let t = Table {
            columns: vec![
                col(
                    "t",
                    ColumnValues::Timestamp((0..n as i64).map(|i| i * 1000).collect()),
                    vec![false; n],
                ),
                col("g", strings(&refs), vec![false; n]),
            ],
            row_count: n,
        };
        let s = series_scene(
            &t,
            &all(&t),
            &SeriesSpec {
                x: "t",
                agg: Aggregate {
                    op: "count",
                    field: None,
                },
                group_by: Some("g"),
            },
        )
        .unwrap();
        assert_eq!(s.series.len(), MAX_SERIES);
        assert_eq!(s.total_series, n);
        assert!(s.truncated_series);
    }

    #[test]
    fn no_series_is_named_when_the_chart_is_ungrouped() {
        let t = times();
        let s = series_scene(
            &t,
            &all(&t),
            &SeriesSpec {
                x: "t",
                agg: Aggregate {
                    op: "count",
                    field: None,
                },
                group_by: None,
            },
        )
        .unwrap();
        assert_eq!(s.series.len(), 1);
        assert_eq!(s.series[0].name, None);
        assert_eq!(s.total_series, 1);
    }

    #[test]
    fn an_empty_selection_produces_an_empty_scene_not_an_error() {
        let t = cats();
        let s = category_scene(
            &t,
            &[],
            "region",
            &Aggregate {
                op: "count",
                field: None,
            },
            12,
        )
        .unwrap();
        assert!(s.points.is_empty());
        assert!(s.other.is_none());
        assert_eq!(s.total_categories, 0);
    }

    #[test]
    fn a_timeline_with_no_usable_times_is_empty_but_honest() {
        let t = Table {
            columns: vec![col(
                "t",
                ColumnValues::Timestamp(vec![0, 0]),
                vec![true, true],
            )],
            row_count: 2,
        };
        let s = timeline_scene(
            &t,
            &all(&t),
            &TimelineSpec {
                time_field: "t",
                severity_field: None,
            },
        )
        .unwrap();
        assert!(s.buckets.is_empty());
        assert_eq!(s.unbucketed_rows, 2);
    }

    #[test]
    fn scenes_serialize_with_a_kind_discriminator() {
        let t = cats();
        let scene = ChartScene::Category(
            category_scene(
                &t,
                &all(&t),
                "region",
                &Aggregate {
                    op: "count",
                    field: None,
                },
                2,
            )
            .unwrap(),
        );
        let j = serde_json::to_value(&scene).unwrap();
        assert_eq!(j["kind"], "category");
        assert_eq!(j["dimension"], "region");
        assert!(j["totalCategories"].is_number());
    }
}
