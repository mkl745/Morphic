/// Bar-chart painter (M1.4 task 1.4.2, docs/architecture/04 §2 and 07 §3).
///
/// Paints an already-aggregated `CategoryScene`. It never sees rows and never computes a
/// total: every number here came from Rust.
///
/// # Why horizontal bars
///
/// A phone is narrow and category labels are words. Vertical columns would truncate "average
/// latency by service" into unreadable stubs or rotate them, and rotated text is the first
/// thing to fail at 1.3× text scale. Horizontal bars give the label a real column and keep the
/// value legible at any scale.
///
/// # Rendering rules this follows
///
/// `RepaintBoundary` + `shouldRepaint` on scene identity, so a pointer move or an unrelated
/// rebuild does not repaint the chart. `TextPainter`s are built once in the constructor and
/// laid out against the incoming width; `TextPainter` caches that layout, so a repaint at the
/// same size does no text work. `paint` allocates only rects, never paints or text painters.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_format.dart';

/// One bar's row height. 48 dp is the accessibility contract's minimum tap target, and the
/// gesture layer uses the same constant so paint and hit-testing cannot drift apart.
const double kBarRowHeight = 48;

/// A null category is a real group; it needs a name a screen reader can say.
const String kNullCategoryLabel = '(none)';

/// The remainder bucket's label as the engine sends it.
const String kOtherLabel = 'Other';

/// Everything the painter needs about one bar, resolved before painting.
class BarDatum {
  const BarDatum({
    required this.label,
    required this.value,
    required this.rowCount,
    required this.isOther,
    required this.isNullCategory,
    required this.isActive,
  });

  final String label;
  final double? value;
  final int rowCount;
  final bool isOther;
  final bool isNullCategory;

  /// True when the workspace is already filtered to this bar.
  final bool isActive;
}

class BarChartPainter extends CustomPainter {
  BarChartPainter({
    required this.bars,
    required this.barColor,
    required this.otherColor,
    required this.trackColor,
    required this.textColor,
    required this.mutedColor,
    required this.textStyle,
    required this.valueStyle,
    required this.textScaler,
  })  : _maxValue = bars.fold<double>(
          0,
          (m, b) => b.value == null ? m : math.max(m, b.value!.abs()),
        ),
        _labels = [
          for (final b in bars) _layout(b.label, textStyle, textScaler),
        ],
        _values = [
          for (final b in bars) _layout(formatBarValue(b.value), valueStyle, textScaler),
        ];

  final List<BarDatum> bars;
  final Color barColor;
  final Color otherColor;
  final Color trackColor;
  final Color textColor;
  final Color mutedColor;
  final TextStyle textStyle;
  final TextStyle valueStyle;
  final TextScaler textScaler;

  final double _maxValue;
  final List<TextPainter> _labels;
  final List<TextPainter> _values;

  /// One reusable paint object. `Canvas` snapshots the paint at each draw, so mutating its
  /// colour between bars is safe and keeps `paint` free of per-bar Paint allocations.
  final Paint _paint = Paint();

  static TextPainter _layout(String text, TextStyle style, TextScaler scaler) =>
      TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
        textScaler: scaler,
      );

  /// Label column width: a third of the card, bounded so a tiny card still draws a bar and a
  /// wide one does not spend all its space on words.
  static double labelWidthFor(double width) =>
      (width * 0.34).clamp(72.0, 168.0).toDouble();

  static const double _valueWidth = 64;
  static const double _gap = 8;
  static const double _barHeight = 14;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final labelW = labelWidthFor(size.width);
    final trackX = labelW + _gap;
    final trackW = math.max(0.0, size.width - trackX - _valueWidth - _gap);

    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final rowTop = i * kBarRowHeight;
      final midY = rowTop + kBarRowHeight / 2;

      // Label, vertically centred on the row.
      final lp = _labels[i]..layout(maxWidth: labelW);
      lp.paint(canvas, Offset(0, midY - lp.height / 2));

      // Track: a hairline-toned full-width rule so an absent value still reads as a row.
      final track = RRect.fromRectAndRadius(
        Rect.fromLTWH(trackX, midY - _barHeight / 2, trackW, _barHeight),
        const Radius.circular(4),
      );
      canvas.drawRRect(track, _paint..color = trackColor);

      final v = b.value;
      if (v != null && _maxValue > 0) {
        // A non-zero value always gets a visible sliver: a bar of zero width would look like
        // missing data, which is a different claim.
        final w = math.max(2.0, trackW * (v.abs() / _maxValue));
        final rect = Rect.fromLTWH(trackX, midY - _barHeight / 2, w, _barHeight);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(4)),
          _paint..color = b.isOther ? otherColor : barColor,
        );
        if (b.isActive) {
          // An outline, not a dim on the other bars. Dimming to 45% dropped a light-theme bar
          // to 1.75:1 against its surface — below the 3:1 floor for a graphic that carries
          // meaning. Every bar keeps full contrast; the selected one is ringed instead.
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect.inflate(3), const Radius.circular(6)),
            _paint
              ..color = textColor
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
          _paint.style = PaintingStyle.fill;
        }
      }

      final vp = _values[i]..layout(maxWidth: _valueWidth);
      vp.paint(
        canvas,
        Offset(size.width - vp.width, midY - vp.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(BarChartPainter oldDelegate) =>
      // Identity, not deep equality: the scene is immutable and a new one is only built when
      // the engine returns new data, so comparing the list identity is both correct and cheap.
      !identical(oldDelegate.bars, bars) ||
      oldDelegate.barColor != barColor ||
      oldDelegate.otherColor != otherColor ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.textColor != textColor ||
      oldDelegate.mutedColor != mutedColor ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.textStyle != textStyle ||
      oldDelegate.valueStyle != valueStyle;

  @override
  bool shouldRebuildSemantics(BarChartPainter oldDelegate) => false;
}

/// A bar's end label: compact, locale-independent, an em dash for a null measure rather than a
/// zero, and 23.33 rather than a rounded 23.
///
/// The implementation lives in `chart_format.dart` so the line chart's axis and tooltip read
/// the same numbers the same way; this name is kept for the bar chart's callers and tests.
String formatBarValue(double? value) => formatChartValue(value);
