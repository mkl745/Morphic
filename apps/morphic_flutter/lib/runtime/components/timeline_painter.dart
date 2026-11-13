/// Timeline painter (M1.4 task 1.4.4, docs/architecture/04 §2 and 07 §3).
///
/// A density chart: one column per time bucket, height by event count, stacked into severity
/// lanes. Nothing here aggregates — counts, bucket step, lane order and the undated-row total all
/// arrive from Rust's `TimelineScene`.
///
/// **Why one painter, where the line chart has two.** 07 §3 requires that *continuous* gestures
/// repaint an overlay only. The timeline's interactions are a tap (which sets a time-range filter
/// and therefore changes the scene) and a legend toggle (which changes the visible lanes). Both
/// change what the base layer must draw, so a second layer would never save a repaint. Adding one
/// would be ceremony, not the performance property the document asks for.
///
/// Text painters are built once in the constructor, never in `paint`, and every `Paint` is reused.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import 'chart_axis_layout.dart';
import 'chart_format.dart';

/// Plot height, matching the line chart so a workspace of mixed charts has one rhythm.
const double kTimelinePlotHeight = 200;

/// Left gutter for count labels, bottom gutter for time labels.
const double kTimelineAxisLeft = 44;
const double kTimelineAxisBottom = 22;

/// Label for a lane whose severity value was null.
const String kNullLaneLabel = '(none)';

/// A recognised severity level, so `ERROR` looks like an error in every workspace rather than
/// taking whatever palette slot its frequency earned.
enum SeverityBand { error, warning, info, ok, muted, unknown }

/// Classifies a severity label. Matching is on the trimmed, lower-cased text because log sources
/// disagree about case and padding, and never on a substring: `informational` must not read as
/// `form`, and a service literally named `error_handler` is not an error level.
SeverityBand severityBandOf(String? label) {
  final key = label?.trim().toLowerCase() ?? '';
  switch (key) {
    case 'fatal':
    case 'error':
    case 'err':
    case 'critical':
    case 'crit':
    case 'severe':
    case 'emergency':
    case 'alert':
    case 'panic':
      return SeverityBand.error;
    case 'warn':
    case 'warning':
      return SeverityBand.warning;
    case 'info':
    case 'information':
    case 'notice':
      return SeverityBand.info;
    case 'ok':
    case 'success':
    case 'pass':
      return SeverityBand.ok;
    case 'debug':
    case 'trace':
    case 'verbose':
    case 'fine':
      return SeverityBand.muted;
    default:
      return SeverityBand.unknown;
  }
}

/// The colour for a lane. Unrecognised labels — including a null severity — fall back to the
/// series palette by lane index, so an arbitrary `groupBy` still gets distinct colours.
Color severityColor(String? label, {required bool dark, required int index}) {
  switch (severityBandOf(label)) {
    case SeverityBand.error:
      return dark ? MorphicColors.severityErrorDark : MorphicColors.severityErrorLight;
    case SeverityBand.warning:
      return dark ? MorphicColors.severityWarningDark : MorphicColors.severityWarningLight;
    case SeverityBand.info:
      return dark ? MorphicColors.severityInfoDark : MorphicColors.severityInfoLight;
    case SeverityBand.ok:
      return dark ? MorphicColors.severityOkDark : MorphicColors.severityOkLight;
    case SeverityBand.muted:
      return dark ? MorphicColors.severityMutedDark : MorphicColors.severityMutedLight;
    case SeverityBand.unknown:
      final palette = dark ? MorphicColors.seriesDark : MorphicColors.seriesLight;
      return palette[index % palette.length];
  }
}

/// One lane: its display label, its colour, and its position in the engine's order.
class TimelineLane {
  const TimelineLane({
    required this.label,
    required this.color,
    required this.engineIndex,
  });

  /// The engine's label, null when the severity value was null.
  final String? label;
  final Color color;

  /// Index before any lane was hidden, so hiding one never recolours the rest.
  final int engineIndex;

  String get displayLabel => label ?? kNullLaneLabel;
}

/// A segment of a column: how many events of one lane fell in this bucket.
class TimelineSegment {
  const TimelineSegment({required this.laneIndex, required this.count});

  /// Index into [TimelineGeometry.lanes].
  final int laneIndex;
  final int count;
}

/// One density column.
class TimelineColumn {
  const TimelineColumn({
    required this.startMs,
    required this.count,
    required this.segments,
  });

  final int startMs;

  /// Every event in the bucket, including lanes that are currently hidden. The column's height
  /// is drawn from the visible segments, but the table and the tooltip must still be able to say
  /// what the bucket actually held.
  final int count;
  final List<TimelineSegment> segments;

  int get visibleCount => segments.fold(0, (n, s) => n + s.count);
}

/// Pixel mapping and extents, computed once per scene so the painter and the hit test agree.
class TimelineGeometry {
  /// A factory rather than a generative constructor because the tick scale derives from the
  /// tallest column, and the painter's tick labels are built in its initializer list — which runs
  /// before any constructor body. Computing the scale here keeps every field final and already
  /// set by the time anything reads it.
  factory TimelineGeometry({
    required List<TimelineLane> lanes,
    required List<TimelineColumn> columns,
    required int bucketMs,
    required bool hasSeveritySplit,
    TextStyle? axisTextStyle,
    TextScaler axisTextScaler = TextScaler.noScaling,
  }) {
    final maxCount =
        columns.fold<int>(0, (m, c) => math.max(m, c.visibleCount));
    // Integer count ticks. A count axis labelled "1.7" would name a number of events that cannot
    // happen, so the step is rounded up and the top of the axis sits at or above the tallest
    // column rather than exactly on it.
    final step = math.max(1, (maxCount / 3).ceil());
    return TimelineGeometry._(
      lanes: lanes,
      columns: columns,
      bucketMs: bucketMs,
      hasSeveritySplit: hasSeveritySplit,
      maxCount: maxCount,
      countStep: step,
      countTop: step * 3,
      axisLeft: measureChartAxisInset(
        labels: [for (var i = 0; i < 4; i++) formatChartValue((step * i).toDouble())],
        style: axisTextStyle,
        scaler: axisTextScaler,
        minimum: kTimelineAxisLeft,
      ),
    );
  }

  TimelineGeometry._({
    required this.lanes,
    required this.columns,
    required this.bucketMs,
    required this.hasSeveritySplit,
    required int maxCount,
    required this.countStep,
    required this.countTop,
    required double axisLeft,
  })  : _maxCount = maxCount,
        _axisLeft = axisLeft,
        xExtent = columns.isEmpty
            ? null
            : (
                columns.first.startMs.toDouble(),
                columns.last.startMs.toDouble() + math.max(bucketMs, 1),
              );

  final List<TimelineLane> lanes;
  final List<TimelineColumn> columns;
  final int bucketMs;

  /// First bucket start to last bucket *end*, so the final column has its full width.
  final (double, double)? xExtent;
  final int _maxCount;

  /// Measured once when geometry is built, and shared by the painter and hit testing.
  final double _axisLeft;

  final int countStep;
  final int countTop;

  /// Whether the scene actually split by severity. When it did not, the view supplies a single
  /// neutral lane so the painter has one code path, but the legend must not invent a severity
  /// chip for a split that does not exist.
  final bool hasSeveritySplit;

  bool get isEmpty => columns.isEmpty || _maxCount == 0;

  Rect plotIn(Size size) {
    final left = fitChartAxisInset(_axisLeft, kTimelineAxisLeft, size.width);
    return Rect.fromLTRB(
      left,
      2,
      math.max(left + 1, size.width - 2),
      math.max(3, size.height - kTimelineAxisBottom),
    );
  }

  double xToPixel(double ms, Rect plot) {
    final (lo, hi) = xExtent!;
    if (hi <= lo) return plot.left;
    return plot.left + (ms - lo) / (hi - lo) * plot.width;
  }

  /// The column's slot, before any minimum width is applied.
  Rect slotFor(TimelineColumn c, Rect plot) {
    final left = xToPixel(c.startMs.toDouble(), plot);
    final right = xToPixel(c.startMs.toDouble() + math.max(bucketMs, 1), plot);
    final w = right - left;
    // A gutter only when there is room for one. At 2000 buckets on a phone the columns are
    // sub-pixel and must be allowed to touch, which is what a density band should look like.
    final gap = w > 3 ? 1.0 : 0.0;
    return Rect.fromLTRB(left, plot.top, left + math.max(w - gap, 0.5), plot.bottom);
  }

  /// Height in pixels for a count, on the integer-tick scale.
  double heightFor(int count, Rect plot) =>
      countTop == 0 ? 0 : plot.height * count / countTop;

  /// The nearest column that has events, so a tap on an empty stretch still selects real data
  /// rather than filtering the workspace down to nothing.
  int? columnAt(double dx, Rect plot) {
    if (columns.isEmpty) return null;
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < columns.length; i++) {
      final slot = slotFor(columns[i], plot);
      final d = (slot.center.dx - dx).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }
}

/// Draws gridlines, count and time ticks, and the stacked density columns.
class TimelinePainter extends CustomPainter {
  TimelinePainter({
    required this.geometry,
    required this.gridColor,
    required this.textStyle,
    required this.textScaler,
    required this.activeColumn,
    required this.activeColor,
  })  : _yTicks = _buildYTicks(geometry, textStyle, textScaler),
        _xTickIndices = _indicesFor(geometry.columns.length),
        _xTicks = _buildXTicks(geometry, textStyle, textScaler);

  final TimelineGeometry geometry;
  final Color gridColor;
  final TextStyle textStyle;
  final TextScaler textScaler;

  /// Index of the bucket the workspace is filtered to, or null.
  final int? activeColumn;
  final Color activeColor;

  final List<TextPainter> _yTicks;
  final List<int> _xTickIndices;
  final List<TextPainter> _xTicks;

  /// One reusable paint; `Canvas` snapshots it at each call.
  final Paint _paint = Paint();

  static List<TextPainter> _buildYTicks(
    TimelineGeometry g,
    TextStyle style,
    TextScaler scaler,
  ) =>
      [
        for (var i = 0; i < 4; i++)
          _text(formatChartValue((g.countStep * i).toDouble()), style, scaler),
      ];

  static List<TextPainter> _buildXTicks(
    TimelineGeometry g,
    TextStyle style,
    TextScaler scaler,
  ) =>
      [
        for (final i in _indicesFor(g.columns.length))
          _text(
            formatAxisTick(
              g.columns[i].startMs.toDouble(),
              temporal: true,
              bucketMs: g.bucketMs,
            ),
            style,
            scaler,
          ),
      ];

  static TextPainter _text(String s, TextStyle style, TextScaler scaler) => TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
        textScaler: scaler,
      );

  static List<int> _indicesFor(int n) {
    if (n == 0) return const [];
    if (n == 1) return const [0];
    if (n == 2) return const [0, 1];
    return [0, n ~/ 2, n - 1];
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (geometry.isEmpty) return;
    final plot = geometry.plotIn(size);

    for (var i = 0; i < _yTicks.length; i++) {
      final y = plot.bottom - plot.height * i / (_yTicks.length - 1);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        _paint
          ..color = gridColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      final tp = _yTicks[i]..layout(maxWidth: plot.left - chartAxisLabelGap);
      tp.paint(canvas, Offset(plot.left - chartAxisLabelGap - tp.width, y - tp.height / 2));
    }

    for (var i = 0; i < _xTicks.length && i < _xTickIndices.length; i++) {
      final slot = geometry.slotFor(geometry.columns[_xTickIndices[i]], plot);
      final tp = _xTicks[i]..layout(maxWidth: plot.width / 2);
      final dx = (slot.center.dx - tp.width / 2)
          .clamp(plot.left, math.max(plot.left, plot.right - tp.width))
          .toDouble();
      tp.paint(canvas, Offset(dx, plot.bottom + 4));
    }

    _paint.style = PaintingStyle.fill;
    for (var i = 0; i < geometry.columns.length; i++) {
      final c = geometry.columns[i];
      final slot = geometry.slotFor(c, plot);
      if (c.visibleCount == 0) continue;
      // Stack bottom-up in engine lane order, so the same severity sits at the same height in
      // every column and the eye can follow one band across the chart.
      var y = plot.bottom;
      for (final s in c.segments) {
        final h = geometry.heightFor(s.count, plot);
        if (h <= 0) continue;
        canvas.drawRect(
          Rect.fromLTRB(slot.left, y - h, slot.right, y),
          _paint..color = geometry.lanes[s.laneIndex].color,
        );
        y -= h;
      }
    }

    final active = activeColumn;
    if (active != null && active >= 0 && active < geometry.columns.length) {
      final slot = geometry.slotFor(geometry.columns[active], plot);
      // Widen the ring so a sub-pixel column is still visibly the selected one.
      final centre = slot.center.dx;
      final half = math.max(slot.width / 2, 4);
      final ring = Rect.fromLTRB(centre - half, plot.top, centre + half, plot.bottom)
          .inflate(2);
      canvas.drawRect(
        ring,
        _paint
          ..color = activeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      _paint.style = PaintingStyle.fill;
    }
  }

  @override
  bool shouldRepaint(covariant TimelinePainter oldDelegate) =>
      // Identity: the view memoises the geometry, so an unrelated ancestor rebuild is not a
      // reason to repaint 2000 columns.
      !identical(oldDelegate.geometry, geometry) ||
      oldDelegate.activeColumn != activeColumn ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.textStyle != textStyle ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.activeColor != activeColor;
}