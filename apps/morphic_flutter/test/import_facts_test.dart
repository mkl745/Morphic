/// The typed view over ImportReport for task 1.2.4.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/import_facts.dart';

Map<String, dynamic> result({
  String format = 'csv',
  String encoding = 'utf-8',
  int rows = 5,
  int quarantined = 0,
  int fields = 3,
  List<String> warnings = const [],
}) =>
    {
      'report': {
        'format': format,
        'encoding': encoding,
        'rowsImported': rows,
        'rowsQuarantined': quarantined,
        'fieldCount': fields,
        'warnings': warnings,
      },
    };

void main() {
  group('reading the report', () {
    test('every fact comes from the engine, not from a guess', () {
      final f = ImportFacts.fromResult(result(
        format: 'jsonl',
        encoding: 'latin-1 (fallback)',
        rows: 120,
        quarantined: 3,
        fields: 7,
      ));
      expect(f.format, 'jsonl');
      expect(f.formatLabel, 'JSON Lines');
      expect(f.encoding, 'latin-1 (fallback)');
      expect(f.encodingNeededFallback, isTrue);
      expect(f.rowsImported, 120);
      expect(f.rowsQuarantined, 3);
      expect(f.fieldCount, 7);
      expect(f.hasQuarantine, isTrue);
    });

    test('a missing report degrades to unknowns instead of throwing', () {
      for (final r in [null, <String, dynamic>{}, {'report': 'nonsense'}]) {
        final f = ImportFacts.fromResult(r);
        expect(f.rowsImported, 0);
        expect(f.formatLabel, 'Unknown');
        expect(f.warnings, isEmpty);
        expect(f.hasQuarantine, isFalse);
        expect(f.confidencePercent, isNull);
      }
    });

    test('an unknown format still shows its raw name', () {
      expect(ImportFacts.fromResult(result(format: 'parquet')).formatLabel, 'parquet');
    });

    test('a clean utf-8 read is not flagged as a fallback', () {
      expect(ImportFacts.fromResult(result()).encodingNeededFallback, isFalse);
    });
  });

  group('quarantine arithmetic', () {
    test('the rate is over attempted rows, not imported rows', () {
      final f = ImportFacts.fromResult(result(rows: 90, quarantined: 10));
      expect(f.quarantineRate, 0.1);
    });

    test('no rows at all is a zero rate, not a division by zero', () {
      final f = ImportFacts.fromResult(result(rows: 0, quarantined: 0));
      expect(f.quarantineRate, 0);
    });

    test('everything quarantined is a rate of one', () {
      final f = ImportFacts.fromResult(result(rows: 0, quarantined: 8));
      expect(f.quarantineRate, 1);
      expect(f.hasQuarantine, isTrue);
    });
  });

  group('the detection headline', () {
    const summary =
        "Read as 'csv' (50% confidence): 3 fields separated by ',' on 50% of sampled lines.";

    test('the first warning is the summary and the rest are notes', () {
      final f = ImportFacts.fromResult(result(warnings: [summary, 'Some rows are ragged.']));
      expect(f.detectionSummary, summary);
      expect(f.notes, ['Some rows are ragged.']);
    });

    test('confidence is read from the headline, never invented', () {
      expect(
        ImportFacts.fromResult(result(warnings: [summary])).confidencePercent,
        50,
      );
      expect(ImportFacts.fromResult(result()).confidencePercent, isNull);
    });

    test('a confident read is not low confidence', () {
      final f = ImportFacts.fromResult(result(warnings: [
        "Read as 'csv' (100% confidence): 3 fields separated by ',' on 100% of sampled lines.",
      ]));
      expect(f.confidencePercent, 100);
      expect(f.isLowConfidence, isFalse);
    });

    test('a hesitant read is low confidence', () {
      expect(
        ImportFacts.fromResult(result(warnings: [summary])).isLowConfidence,
        isTrue,
      );
    });

    test('an engine that reports no headline keeps every warning as a note', () {
      final f = ImportFacts.fromResult(result(warnings: ['older engine note']));
      expect(f.detectionSummary, isNull);
      expect(f.notes, ['older engine note']);
      expect(f.isLowConfidence, isFalse);
    });
  });
}
