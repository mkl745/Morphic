/// Measured chart-axis gutters shared by the painter and its interaction geometry.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Space between a y-axis label and the plot's gridline.
const double chartAxisLabelGap = 6;

/// Keep the historical minimum for short labels, but make room for longer labels and larger
/// text. The scene owns the tick values; this only measures their already-formatted labels.
double measureChartAxisInset({
  required Iterable<String> labels,
  required TextStyle? style,
  required TextScaler scaler,
  required double minimum,
}) {
  if (style == null) return minimum;
  var width = 0.0;
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: scaler,
    )..layout();
    width = math.max(width, painter.width);
    painter.dispose();
  }
  // A small rounding allowance keeps a label measured unconstrained from wrapping when
  // Flutter lays it out against the finite gutter during paint.
  return math.max(minimum, width + chartAxisLabelGap + 1);
}

/// An unusually narrow card still needs a plot. Its text table exposes the bucket and series
/// data when axis labels cannot fit within this bound.
double fitChartAxisInset(double measured, double minimum, double availableWidth) =>
    math.min(measured, math.max(minimum, availableWidth * 0.4));
