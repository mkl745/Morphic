library;

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/runtime/value_format.dart';

void main() {
  group('groupInteger', () {
    test('groups thousands', () {
      expect(groupInteger(0), '0');
      expect(groupInteger(999), '999');
      expect(groupInteger(1000), '1,000');
      expect(groupInteger(1234567), '1,234,567');
    });

    test('keeps the sign outside the grouping', () {
      expect(groupInteger(-1234567), '-1,234,567');
      expect(groupInteger(-999), '-999');
    });
  });

  group('formatNumber', () {
    test('integers stay exact', () {
      expect(formatNumber(1234), '1,234');
      expect(formatNumber(9007199254740991), '9,007,199,254,740,991');
    });

    test('whole doubles do not gain a decimal tail', () {
      expect(formatNumber(26.0), '26');
      expect(formatNumber(-4.0), '-4');
    });

    test('fractions keep real digits, not padded zeros', () {
      expect(formatNumber(17.5), '17.5');
      expect(formatNumber(2.98), '2.98');
      expect(formatNumber(1234.5), '1,234.5');
    });

    test('rounds to the display budget without inventing precision', () {
      expect(formatNumber(1.0 / 3.0), '0.333');
      expect(formatNumber(1.0 / 3.0, maxDecimals: 5), '0.33333');
    });

    test('non-finite values are labelled, not silently zeroed', () {
      expect(formatNumber(double.nan), 'NaN');
      expect(formatNumber(double.infinity), '∞');
      expect(formatNumber(double.negativeInfinity), '-∞');
    });
  });

  group('formatCell', () {
    test('null is a glyph, never zero or empty', () {
      expect(formatCell(null), noDataGlyph);
      expect(formatCell(null), isNot('0'));
      expect(formatCell(null), isNot(''));
    });

    test('zero is still zero — distinct from no data', () {
      expect(formatCell(0), '0');
      expect(formatCell(0), isNot(noDataGlyph));
    });

    test('booleans and strings pass through', () {
      expect(formatCell(true), 'true');
      expect(formatCell(false), 'false');
      expect(formatCell('eu'), 'eu');
    });

    test('an empty string reads as no data', () {
      expect(formatCell(''), noDataGlyph);
    });

    test('engine-rendered ISO timestamps are not reformatted', () {
      // Rust already normalized to UTC ISO-8601; Dart must not reinterpret it.
      const iso = '2026-11-05T12:34:56Z';
      expect(formatCell(iso), iso);
    });
  });

  group('aggregationLabel', () {
    test('count without a field reads as rows', () {
      expect(aggregationLabel({'op': 'count', 'field': null}), 'count · rows');
    });

    test('a field aggregation names the operation and the field', () {
      expect(aggregationLabel({'op': 'avg', 'field': 'amount'}), 'average · amount');
      expect(aggregationLabel({'op': 'max', 'field': 'when'}), 'maximum · when');
    });

    test('count with a field is non-null count, so the field is shown', () {
      expect(aggregationLabel({'op': 'count', 'field': 'note'}), 'count · note');
    });

    test('an unknown op is shown verbatim rather than hidden', () {
      expect(aggregationLabel({'op': 'median', 'field': 'x'}), 'median · x');
    });

    test('a missing aggregation yields no label', () {
      expect(aggregationLabel(null), '');
    });
  });

  group('rowRangeLabel', () {
    test('a full page reads as a range of the total', () {
      expect(rowRangeLabel(offset: 0, rowCount: 256, totalRows: 4096),
          '1–256 of 4,096');
    });

    test('a later page starts at its true offset', () {
      expect(rowRangeLabel(offset: 256, rowCount: 100, totalRows: 356),
          '257–356 of 356');
    });

    test('an empty result is not reported as row 1', () {
      expect(rowRangeLabel(offset: 0, rowCount: 0, totalRows: 0), '0 of 0');
      expect(rowRangeLabel(offset: 500, rowCount: 0, totalRows: 10), '0 of 10');
    });
  });
}
