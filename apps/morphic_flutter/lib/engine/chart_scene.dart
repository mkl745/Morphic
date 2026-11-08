/// The chart scene contract (M1.4 task 1.4.1, docs/architecture/02 §2.5).
///
/// Rust groups, buckets and downsamples; these classes carry the result. **No raw rows cross
/// the boundary** — a painter receives points and totals, never a table it could aggregate
/// itself. That is the same invariant the table holds, and it is why a chart cannot drift from
/// the engine's answer.
///
/// The truncation flags are not decoration. A scene that dropped series, merged buckets or
/// chose its top-N from a prefix is a scene the painter must annotate; silently drawing it as
/// complete would be the dishonest-reporting failure this project keeps refusing. Every scene
/// therefore answers [ChartScene.partialNotice] in words a user can read.
library;

/// How the x axis was bucketed.
class Bucketing {
  const Bucketing({
    required this.bucketMs,
    required this.label,
    required this.downsampled,
  });

  factory Bucketing.fromJson(Map<String, dynamic> json) => Bucketing(
        bucketMs: (json['bucketMs'] as num?)?.toInt() ?? 0,
        label: json['label'] as String? ?? '',
        downsampled: json['downsampled'] == true,
      );

  final int bucketMs;

  /// Human label for the step, e.g. `5m`. Comes from the engine so the axis and the tooltip
  /// cannot disagree about what a bucket means.
  final String label;

  /// True when even the coarsest named step overflowed and adjacent buckets were merged.
  final bool downsampled;
}

/// One bar. [label] null is the null-valued category — a real group, not the same as `""`.
class CategoryPoint {
  const CategoryPoint({
    required this.label,
    required this.value,
    required this.rowCount,
  });

  factory CategoryPoint.fromJson(Map<String, dynamic> json) => CategoryPoint(
        label: json['label'] as String?,
        value: (json['value'] as num?)?.toDouble(),
        rowCount: (json['rowCount'] as num?)?.toInt() ?? 0,
      );

  final String? label;

  /// Null when the measure is undefined for the group (every value null), which a painter must
  /// draw as an absent bar rather than a zero one.
  final double? value;
  final int rowCount;
}

class SeriesPoint {
  const SeriesPoint({required this.x, required this.y});

  factory SeriesPoint.fromJson(Map<String, dynamic> json) => SeriesPoint(
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble(),
      );

  /// Bucket start: UTC milliseconds for a temporal x, the lower bound for a numeric one.
  final double x;

  /// Null means "no value here", which a line draws as a gap rather than a drop to zero.
  final double? y;
}

class ChartSeries {
  const ChartSeries({required this.name, required this.points});

  factory ChartSeries.fromJson(Map<String, dynamic> json) => ChartSeries(
        name: json['name'] as String?,
        points: _maps(json['points']).map(SeriesPoint.fromJson).toList(),
      );

  /// The group value, or the measure's name for an ungrouped chart.
  final String? name;
  final List<SeriesPoint> points;
}

class LaneCount {
  const LaneCount({required this.lane, required this.count});

  factory LaneCount.fromJson(Map<String, dynamic> json) => LaneCount(
        lane: json['lane'] as String?,
        count: (json['count'] as num?)?.toInt() ?? 0,
      );

  final String? lane;
  final int count;
}

class TimelineBucket {
  const TimelineBucket({
    required this.startMs,
    required this.count,
    required this.lanes,
  });

  factory TimelineBucket.fromJson(Map<String, dynamic> json) => TimelineBucket(
        startMs: (json['startMs'] as num?)?.toInt() ?? 0,
        count: (json['count'] as num?)?.toInt() ?? 0,
        lanes: _maps(json['lanes']).map(LaneCount.fromJson).toList(),
      );

  final int startMs;
  final int count;
  final List<LaneCount> lanes;
}

/// The tagged union that crosses FFI: one endpoint, three shapes, discriminated by `kind`.
///
/// Sealed so a painter's `switch` is exhaustive: adding a fourth scene kind becomes a compile
/// error at every painter rather than a silently unrendered component.
sealed class ChartScene {
  const ChartScene();

  /// Parses the `scene` member of a `chartData` response. Throws [FormatException] on an
  /// unknown kind rather than returning an empty scene the UI would draw as "no data".
  factory ChartScene.fromJson(Map<String, dynamic> json) {
    switch (json['kind'] as String?) {
      case 'category':
        return CategoryScene.fromJson(json);
      case 'series':
        return SeriesScene.fromJson(json);
      case 'timeline':
        return TimelineScene.fromJson(json);
      default:
        throw FormatException('unknown chart scene kind: ${json['kind']}');
    }
  }

  /// True when the engine had to drop or merge something to fit the ceilings.
  bool get isPartial;

  /// What is missing, in words a user can read, or null when nothing is. A painter that shows
  /// a partial scene must show this.
  String? get partialNotice;
}

/// Top-N categories plus an honest remainder.
class CategoryScene extends ChartScene {
  const CategoryScene({
    required this.dimension,
    required this.measure,
    required this.points,
    required this.other,
    required this.totalCategories,
    required this.truncated,
  });

  factory CategoryScene.fromJson(Map<String, dynamic> json) => CategoryScene(
        dimension: json['dimension'] as String? ?? '',
        measure: json['measure'] as String? ?? '',
        points: _maps(json['points']).map(CategoryPoint.fromJson).toList(),
        other: json['other'] is Map<String, dynamic>
            ? CategoryPoint.fromJson(json['other'] as Map<String, dynamic>)
            : null,
        totalCategories: (json['totalCategories'] as num?)?.toInt() ?? 0,
        truncated: json['truncated'] == true,
      );

  final String dimension;

  /// Output name of the measure, e.g. `avg_amount`.
  final String measure;
  final List<CategoryPoint> points;

  /// Re-aggregated over every row outside the top N — never a total minus the top bars, which
  /// would be wrong for an average and meaningless for min/max.
  final CategoryPoint? other;
  final int totalCategories;

  /// True when categories exceeded the accumulation cap, so the top N came from a prefix and
  /// is not guaranteed to be the true top N.
  final bool truncated;

  /// Categories without their own bar. Zero when everything fit.
  int get hiddenCategories => _nonNegative(totalCategories - points.length);

  @override
  bool get isPartial => truncated;

  @override
  String? get partialNotice => truncated
      ? 'Too many categories to rank reliably; the top bars come from a prefix.'
      : null;
}

/// Bucketed line-chart data.
class SeriesScene extends ChartScene {
  const SeriesScene({
    required this.xField,
    required this.temporal,
    required this.bucketing,
    required this.series,
    required this.totalSeries,
    required this.truncatedSeries,
    required this.totalPoints,
  });

  factory SeriesScene.fromJson(Map<String, dynamic> json) => SeriesScene(
        xField: json['xField'] as String? ?? '',
        temporal: json['temporal'] == true,
        bucketing: Bucketing.fromJson(
          (json['bucketing'] as Map<String, dynamic>?) ?? const {},
        ),
        series: _maps(json['series']).map(ChartSeries.fromJson).toList(),
        totalSeries: (json['totalSeries'] as num?)?.toInt() ?? 0,
        truncatedSeries: json['truncatedSeries'] == true,
        totalPoints: (json['totalPoints'] as num?)?.toInt() ?? 0,
      );

  final String xField;
  final bool temporal;
  final Bucketing bucketing;
  final List<ChartSeries> series;
  final int totalSeries;

  /// True when groups exceeded the series cap. The dropped series are **not** summed into an
  /// "Other" line: adding averages is meaningless, and a fabricated total is worse than an
  /// honest count of what is missing.
  final bool truncatedSeries;
  final int totalPoints;

  int get hiddenSeries => _nonNegative(totalSeries - series.length);

  @override
  bool get isPartial => truncatedSeries || bucketing.downsampled;

  @override
  String? get partialNotice {
    if (truncatedSeries) {
      return 'Showing ${series.length} of $totalSeries series; '
          '$hiddenSeries not drawn.';
    }
    if (bucketing.downsampled) {
      return 'Buckets merged to stay under the point ceiling; '
          'each is ${bucketing.label}.';
    }
    return null;
  }
}

/// Density buckets with severity lanes.
class TimelineScene extends ChartScene {
  const TimelineScene({
    required this.timeField,
    required this.bucketing,
    required this.lanes,
    required this.buckets,
    required this.totalBuckets,
    required this.totalLanes,
    required this.truncatedLanes,
    required this.unbucketedRows,
  });

  factory TimelineScene.fromJson(Map<String, dynamic> json) => TimelineScene(
        timeField: json['timeField'] as String? ?? '',
        bucketing: Bucketing.fromJson(
          (json['bucketing'] as Map<String, dynamic>?) ?? const {},
        ),
        lanes: (json['lanes'] as List? ?? const []).map((e) => e as String?).toList(),
        buckets: _maps(json['buckets']).map(TimelineBucket.fromJson).toList(),
        totalBuckets: (json['totalBuckets'] as num?)?.toInt() ?? 0,
        totalLanes: (json['totalLanes'] as num?)?.toInt() ?? 0,
        truncatedLanes: json['truncatedLanes'] == true,
        unbucketedRows: (json['unbucketedRows'] as num?)?.toInt() ?? 0,
      );

  final String timeField;
  final Bucketing bucketing;

  /// Lane order, most frequent first, so a legend is stable across revisions.
  final List<String?> lanes;
  final List<TimelineBucket> buckets;
  final int totalBuckets;
  final int totalLanes;
  final bool truncatedLanes;

  /// Rows whose time was null and so belong to no bucket. Surfaced rather than dropped: a
  /// timeline that quietly ignores undated events understates the data.
  final int unbucketedRows;

  @override
  bool get isPartial => truncatedLanes || unbucketedRows > 0;

  @override
  String? get partialNotice {
    final parts = <String>[
      if (truncatedLanes) 'Showing ${lanes.length} of $totalLanes lanes',
      if (unbucketedRows > 0) '$unbucketedRows undated rows not placed',
    ];
    return parts.isEmpty ? null : '${parts.join("; ")}.';
  }
}

/// A scene and the revision that produced it.
///
/// The revision travels for the same reason it travels with a metric: a reader must be able to
/// tell which selection it is looking at, and discard one the document has left (task 1.3.5).
class ChartResult {
  const ChartResult({
    required this.componentId,
    required this.scene,
    required this.revision,
  });

  factory ChartResult.fromJson(Map<String, dynamic> json) => ChartResult(
        componentId: json['componentId'] as String? ?? '',
        scene: ChartScene.fromJson(
          (json['scene'] as Map<String, dynamic>?) ?? const {},
        ),
        revision: (json['revision'] as num?)?.toInt() ?? 0,
      );

  final String componentId;
  final ChartScene scene;
  final int revision;
}

List<Map<String, dynamic>> _maps(Object? value) =>
    (value as List? ?? const []).whereType<Map<String, dynamic>>().toList();

/// `int.clamp` is statically `num`, which cannot be returned as an int. Say it plainly instead.
int _nonNegative(int n) => n < 0 ? 0 : n;