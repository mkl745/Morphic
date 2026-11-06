/// Display-only formatting (M1.1 task 1.1.5).
///
/// Rust already decides *what* a value is: `queryPage` renders timestamps as ISO-8601 UTC
/// strings and nulls as JSON null. This file only decides how a value *looks*. It never
/// coerces a type, and it never turns "no data" into zero.
library;

/// Shown for a null/absent value. Deliberately not `0` and not an empty string.
const String noDataGlyph = '—';

/// Group an integer with thin separators, e.g. `1234567` -> `1,234,567`.
String groupInteger(int value) {
  final negative = value < 0;
  final digits = value.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return negative ? '-$buf' : buf.toString();
}

/// Format a number for display without inventing precision.
///
/// Integers stay exact (grouped). Doubles keep up to [maxDecimals] places, trailing zeros
/// trimmed, because `26.0` should read as `26` and `17.5` as `17.5` — not `17.500000`.
String formatNumber(num value, {int maxDecimals = 3}) {
  if (value is int) return groupInteger(value);
  final d = value.toDouble();
  if (d.isNaN) return 'NaN';
  if (d.isInfinite) return d.isNegative ? '-∞' : '∞';
  if (d == d.roundToDouble() && d.abs() < 1e15) {
    return groupInteger(d.toInt());
  }
  var s = d.toStringAsFixed(maxDecimals);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  // Group only the integer part so the fractional digits are untouched.
  final parts = s.split('.');
  final negative = parts[0].startsWith('-');
  final intPart = int.tryParse(negative ? parts[0].substring(1) : parts[0]);
  if (intPart == null) return s;
  final grouped = groupInteger(negative ? -intPart : intPart);
  return parts.length == 1 ? grouped : '$grouped.${parts[1]}';
}

/// Format any engine cell value. Null is [noDataGlyph], never `0` or `''`.
String formatCell(Object? value) {
  if (value == null) return noDataGlyph;
  if (value is num) return formatNumber(value);
  if (value is bool) return value ? 'true' : 'false';
  final s = value.toString();
  return s.isEmpty ? noDataGlyph : s;
}

/// A human label for an aggregation, e.g. `avg · reading` or `count · rows`.
String aggregationLabel(Map<String, dynamic>? aggregation) {
  if (aggregation == null) return '';
  final op = aggregation['op'] as String? ?? '';
  final field = aggregation['field'] as String?;
  const labels = {
    'count': 'count',
    'sum': 'sum',
    'avg': 'average',
    'min': 'minimum',
    'max': 'maximum',
    'distinct_count': 'distinct',
  };
  final opLabel = labels[op] ?? op;
  if (field == null || field.isEmpty) {
    return op == 'count' ? 'count · rows' : opLabel;
  }
  return '$opLabel · $field';
}

/// A row range for a pager, e.g. `1–256 of 4,096`. Empty results read as `0 of 0`.
String rowRangeLabel({
  required int offset,
  required int rowCount,
  required int totalRows,
}) {
  if (rowCount == 0) return '0 of ${groupInteger(totalRows)}';
  final first = offset + 1;
  final last = offset + rowCount;
  return '${groupInteger(first)}–${groupInteger(last)} of ${groupInteger(totalRows)}';
}
