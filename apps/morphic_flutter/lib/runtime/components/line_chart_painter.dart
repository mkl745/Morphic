/// Line-chart painters (M1.4 task 1.4.3, docs/architecture/04 §2 and 07 §3).
///
/// Two painters, deliberately. `LineChartPainter` draws axes and lines and repaints only when
/// the scene, the visible set or the size changes. `ScrubOverlayPainter` draws the crosshair and
/// point markers and repaints on pointer moves. Each sits in its own `RepaintBoundary`, so
/// scrubbing a 2000-point chart never re-rasterises the lines — the requirement in 07 §3 that
/// "gestures repaint overlay layer only".
///
/// The tooltip itself is a widget, not painted text: that keeps text layout in the render tree
/// where Flutter caches it, keeps it readable to a screen reader, and keeps `paint` free of
/// per-move `TextPainter` allocation.
///
/// Nothing here aggregates. Points, bucket step and totals all arrive from Rust.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../engine/chart_scene.dart';
import 'chart_axis_layout.dart';
import 'chart_format.dart';

/// Plot height. Tall enough to read a trend on a phone, short enough that the legend and the
/// table link stay above the fold.
const double kLinePlotHeight = 200;

/// Scrub marker radius. The plot is inset by this so an edge point's marker is not clipped.
const double _markerRadius = 4;

/// Left gutter for y tick labels, and bottom gutter for x tick labels.
const double kLineAxisLeft = 44;
const double kLineAxisBottom = 22;

/// A series ready to draw: its engine points plus the colour the legend and the line share.
class LineSeriesDatum {
  const LineSeriesDatum({
    required this.name,
    required this.points,
    required this.color,
  });

  final String name;
  final List<SeriesPoint> points;
  final Color color;

  /// Indices of defined points with no defined neighbour on either side.
  ///
  /// A line is drawn between two points, so a lone measurement sitting between gaps has no
  /// segment to render it and would vanish from the chart entirely. The painter marks these
  /// with a dot instead. A single-point series is the degenerate case of the same rule.
  Iterable<int> get isolatedIndices sync* {
    for (var i = 0; i < points.length; i++) {
      if (points[i].y == null) continue;
      final before = i > 0 && points[i - 1].y != null;
      final after = i + 1 < points.length && points[i + 1].y != null;
      if (!before && !after) yield i;
    }
  }
}

/// The x/y extent and pixel mapping shared by both painters, computed once per scene so the
/// overlay's markers land exactly on the base layer's line.
class LineGeometry {
  LineGeometry({
    required this.series,
    required this.temporal,
    required this.bucketMs,
    TextStyle? axisTextStyle,
    TextScaler axisTextScaler = TextScaler.noScaling,
  })  : xExtent = _extent(series.expand((s) => s.points).map((p) => p.x)),
        yExtent = _yExtent(series) {
    _axisLeft = _measureAxisLeft(axisTextStyle, axisTextScaler);
  }

  final List<LineSeriesDatum> series;
  final bool temporal;
  final int bucketMs;

  /// (min, max) of x across every visible point, or null when nothing is visible.
  final (double, double)? xExtent;

  /// (min, max) of y across every visible non-null point, padded so a flat series is not drawn
  /// on the very edge of the plot. Null when every visible value is absent.
  final (double, double)? yExtent;

  static (double, double)? _extent(Iterable<double> xs) {
    double? lo;
    double? hi;
    for (final x in xs) {
      if (lo == null || x < lo) lo = x;
      if (hi == null || x > hi) hi = x;
    }
    return lo == null || hi == null ? null : (lo, hi);
  }

  static (double, double)? _yExtent(List<LineSeriesDatum> series) {
    double? lo;
    double? hi;
    for (final s in series) {
      for (final p in s.points) {
        final y = p.y;
        if (y == null) continue;
        if (lo == null || y < lo) lo = y;
        if (hi == null || y > hi) hi = y;
      }
    }
    if (lo == null || hi == null) return null;
    // A zero baseline is only forced when the data straddles or touches it. Forcing zero on a
    // series that runs 990..1000 would flatten the very variation the chart exists to show.
    if (hi == lo) return (lo - 0.5, lo + 0.5); // a flat series reads better centred
    final bottom = lo > 0 ? math.max(0.0, lo - (hi - lo) * 0.1) : lo;
    return (bottom, hi + (hi - bottom) * 0.05);
  }

  bool get isEmpty => xExtent == null || yExtent == null;

  /// Measured once per geometry (not during painting). The inset is shared by the base
  /// painter, scrub overlay and hit testing, so all three agree when text scales change.
  late final double _axisLeft;

  double _measureAxisLeft(TextStyle? style, TextScaler scaler) {
    final extent = yExtent;
    if (style == null || extent == null) return kLineAxisLeft;
    final (lo, hi) = extent;
    return measureChartAxisInset(
      labels: [for (var i = 0; i < 4; i++) formatChartValue(lo + (hi - lo) * i / 3)],
      style: style,
      scaler: scaler,
      minimum: kLineAxisLeft,
    );
  }

  /// The plot rectangle inside a given canvas size.
  Rect plotIn(Size size) {
    final left = fitChartAxisInset(_axisLeft, kLineAxisLeft, size.width);
    return Rect.fromLTRB(
      left,
      _markerRadius + 2,
      math.max(left + 1, size.width - _markerRadius - 2),
      math.max(_markerRadius + 3, size.height - kLineAxisBottom),
    );
  }

  double xToPixel(double x, Rect plot) {
    final (lo, hi) = xExtent!;
    if (hi == lo) return plot.center.dx;
    return plot.left + (x - lo) / (hi - lo) * plot.width;
  }

  double yToPixel(double y, Rect plot) {
    final (lo, hi) = yExtent!;
    if (hi == lo) return plot.center.dy;
    return plot.bottom - (y - lo) / (hi - lo) * plot.height;
  }

  /// The bucket nearest a pixel x. Returns null when there is nothing to scrub.
  ///
  /// Every series is bucketed on the same ladder by the engine, so the first visible series
  /// carries the canonical bucket list.
  int? bucketAt(double dx, Rect plot) {
    final points = firstPoints;
    if (points.isEmpty) return null;
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final d = (xToPixel(points[i].x, plot) - dx).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  List<SeriesPoint> get firstPoints =>
      series.isEmpty ? const [] : series.first.points;
}

class LineChartPainter extends CustomPainter {
  LineChartPainter({
    required this.geometry,
    required this.gridColor,
    required this.textStyle,
    required this.textScaler,
  })  : _yTicks = _buildYTicks(geometry, textStyle, textScaler),
        _xTickIndices = _indicesFor(geometry.firstPoints.length),
        _xTicks = _buildXTicks(geometry, textStyle, textScaler);

  final LineGeometry geometry;
  final Color gridColor;
  final TextStyle textStyle;
  final TextScaler textScaler;

  final List<TextPainter> _yTicks;
  final List<int> _xTickIndices;
  final List<TextPainter> _xTicks;

  /// One reusable paint object; `Canvas` snapshots it at each draw.
  final Paint _paint = Paint();

  /// Paths are pixel-space, so they are rebuilt only when the size changes. A repaint at the
  /// same size reuses them, and `shouldRepaint` means an unchanged chart is not painted at all.
  Size? _pathSize;
  List<Path> _paths = const [];
  List<List<Offset>> _isolated = const [];

  static List<TextPainter> _buildYTicks(
    LineGeometry g,
    TextStyle style,
    TextScaler scaler,
  ) {
    final extent = g.yExtent;
    if (extent == null) return const [];
    final (lo, hi) = extent;
    return [
      for (var i = 0; i < 4; i++)
        _text(formatChartValue(lo + (hi - lo) * i / 3), style, scaler),
    ];
  }

  static List<TextPainter> _buildXTicks(
    LineGeometry g,
    TextStyle style,
    TextScaler scaler,
  ) {
    final points = g.firstPoints;
    if (points.isEmpty) return const [];
    // Three labels: first, middle, last. More would collide at phone width, and the scrub
    // tooltip is where an exact bucket is read.
    return [
      for (final i in _indicesFor(points.length))
        _text(
          formatAxisTick(points[i].x, temporal: g.temporal, bucketMs: g.bucketMs),
          style,
          scaler,
        ),
    ];
  }

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

  void _rebuildPaths(Size size) {
    if (_pathSize == size) return;
    _pathSize = size;
    final plot = geometry.plotIn(size);
    _paths = [
      for (final s in geometry.series) _pathFor(s, plot),
    ];
    _isolated = [
      for (final s in geometry.series)
        [
          for (final i in s.isolatedIndices)
            Offset(
              geometry.xToPixel(s.points[i].x, plot),
              geometry.yToPixel(s.points[i].y!, plot),
            ),
        ],
    ];
  }

  /// A null y is a **gap**, not a zero. Dropping to the axis would invent a measurement the
  /// engine never made, so the path lifts the pen and resumes at the next defined point.
  Path _pathFor(LineSeriesDatum s, Rect plot) {
    final path = Path();
    var penDown = false;
    for (final p in s.points) {
      final y = p.y;
      if (y == null) {
        penDown = false;
        continue;
      }
      final offset = Offset(
        geometry.xToPixel(p.x, plot),
        geometry.yToPixel(y, plot),
      );
      if (penDown) {
        path.lineTo(offset.dx, offset.dy);
      } else {
        path.moveTo(offset.dx, offset.dy);
        penDown = true;
      }
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (geometry.isEmpty) return;
    _rebuildPaths(size);
    final plot = geometry.plotIn(size);

    // Gridlines and their labels share the same fractions, so a label can never drift off the
    // line it names.
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

    final indices = _xTickIndices;
    for (var i = 0; i < _xTicks.length && i < indices.length; i++) {
      final tp = _xTicks[i]..layout(maxWidth: plot.width / 2);
      final x = geometry.xToPixel(geometry.firstPoints[indices[i]].x, plot);
      // Clamp the end labels inside the plot so the first and last do not hang off the card.
      final dx = (x - tp.width / 2).clamp(plot.left, plot.right - tp.width).toDouble();
      tp.paint(canvas, Offset(dx, plot.bottom + 4));
    }

    _paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < _paths.length; i++) {
      canvas.drawPath(_paths[i], _paint..color = geometry.series[i].color);
    }
    // A lone point between gaps has no segment, so it gets a dot rather than disappearing.
    _paint.style = PaintingStyle.fill;
    for (var i = 0; i < _isolated.length; i++) {
      if (_isolated[i].isEmpty) continue;
      _paint.color = geometry.series[i].color;
      for (final o in _isolated[i]) {
        canvas.drawCircle(o, 2.5, _paint);
      }
    }
  }

  @override
  bool shouldRepaint(LineChartPainter oldDelegate) =>
      // Identity: the geometry is rebuilt only when the scene or the visible set changes.
      !identical(oldDelegate.geometry, geometry) ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.textStyle != textStyle ||
      oldDelegate.textScaler != textScaler;

  @override
  bool shouldRebuildSemantics(LineChartPainter oldDelegate) => false;
}

/// Crosshair and markers only. Repaints per scrub step; the lines beneath it do not.
class ScrubOverlayPainter extends CustomPainter {
  ScrubOverlayPainter({
    required this.geometry,
    required this.bucketIndex,
    required this.crosshairColor,
    required this.markerFill,
  });

  final LineGeometry geometry;

  /// Reused across draws: this painter runs on every scrub step, so allocating per marker
  /// would be exactly the per-frame churn 07 §3 forbids.
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  final Paint _fill = Paint();

  /// Null hides the overlay entirely.
  final int? bucketIndex;
  final Color crosshairColor;
  final Color markerFill;

  @override
  void paint(Canvas canvas, Size size) {
    final index = bucketIndex;
    if (index == null || geometry.isEmpty) return;
    final points = geometry.firstPoints;
    if (index < 0 || index >= points.length) return;
    final plot = geometry.plotIn(size);
    final x = geometry.xToPixel(points[index].x, plot);

    canvas.drawLine(
      Offset(x, plot.top),
      Offset(x, plot.bottom),
      _stroke..color = crosshairColor,
    );

    for (final s in geometry.series) {
      if (index >= s.points.length) continue;
      final y = s.points[index].y;
      if (y == null) continue; // a gap has no point to mark
      final centre = Offset(x, geometry.yToPixel(y, plot));
      canvas.drawCircle(centre, _markerRadius, _fill..color = markerFill);
      canvas.drawCircle(centre, _markerRadius - 1, _fill..color = s.color);
    }
  }

  @override
  bool shouldRepaint(ScrubOverlayPainter oldDelegate) =>
      oldDelegate.bucketIndex != bucketIndex ||
      !identical(oldDelegate.geometry, geometry) ||
      oldDelegate.crosshairColor != crosshairColor ||
      oldDelegate.markerFill != markerFill;

  @override
  bool shouldRebuildSemantics(ScrubOverlayPainter oldDelegate) => false;
}