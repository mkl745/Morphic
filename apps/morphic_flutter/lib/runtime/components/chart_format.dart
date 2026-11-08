/// Shared chart formatting (M1.4 tasks 1.4.2–1.4.3).
///
/// One place decides how a number and a bucket read, so a bar's value, a line's axis tick and
/// a tooltip cannot describe the same quantity three different ways. Formatting is presentation,
/// not data logic: every value here already came from Rust.
library;

/// Compact, locale-independent value label. Compactness matters on a phone: a y axis has room
/// for about six characters, and `1234567` would collide with the plot.
String formatChartValue(double? value) {
  if (value == null) return '—';
  final abs = value.abs();
  if (abs >= 1000000) return '${_trim(value / 1000000)}M';
  if (abs >= 10000) return '${_trim(value / 1000)}k';
  if (abs >= 100) return value.toStringAsFixed(0);
  if (abs >= 1) return _trim(value);
  if (abs == 0) return '0';
  return value.toStringAsFixed(2);
}

String _trim(double v) {
  final s = v.toStringAsFixed(2);
  if (!s.contains('.')) return s;
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

const int _minuteMs = 60 * 1000;
const int _hourMs = 60 * _minuteMs;
const int _dayMs = 24 * _hourMs;

String _two(int v) => v.toString().padLeft(2, '0');

/// A short x-axis tick. Three of these share a phone-width axis, so the step decides the field
/// width: a day step needs a date, a minute step needs a clock, and neither has room for both.
///
/// [bucketMs] comes from the engine's `Bucketing`, so the axis and the tooltip agree on what a
/// bucket means. Zero means a numeric x, which is formatted as a number instead.
String formatAxisTick(double x, {required bool temporal, required int bucketMs}) {
  if (!temporal) return formatChartValue(x);
  final t = DateTime.fromMillisecondsSinceEpoch(x.round(), isUtc: true);
  if (bucketMs >= _dayMs) return '${t.month}/${t.day}';
  if (bucketMs >= _hourMs) return '${_two(t.hour)}:00';
  if (bucketMs >= _minuteMs) return '${_two(t.hour)}:${_two(t.minute)}';
  return '${_two(t.minute)}:${_two(t.second)}';
}

/// The full bucket label for a tooltip, where width is not the constraint and precision is.
/// Always UTC: the engine buckets in UTC, and rendering a bucket in local time would name an
/// instant the engine never computed.
String formatBucketLabel(double x, {required bool temporal, required int bucketMs}) {
  if (!temporal) return formatChartValue(x);
  final t = DateTime.fromMillisecondsSinceEpoch(x.round(), isUtc: true);
  final date = '${t.year}-${_two(t.month)}-${_two(t.day)}';
  if (bucketMs >= _dayMs) return date;
  return '$date ${_two(t.hour)}:${_two(t.minute)} UTC';
}