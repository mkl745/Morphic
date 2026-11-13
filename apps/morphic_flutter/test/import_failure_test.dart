/// Human error copy for task 1.2.4.
///
/// The inputs here are the engine's real `Display` strings, copied from the Rust sources.
/// If the engine's wording changes, these stop matching and the classifier silently falls
/// back to `internal` — so the assertions are on the *classification*, not just the copy.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/import_failure.dart';

void main() {
  group('classification of real engine errors', () {
    test('cancellation is not a failure', () {
      for (final raw in ['import cancelled', 'ingest: import cancelled']) {
        final f = describeImportFailure(raw);
        expect(f.kind, ImportFailureKind.cancelled);
        expect(f.isCancellation, isTrue);
      }
    });

    test('empty file', () {
      final f = describeImportFailure('ingest: the file is empty');
      expect(f.kind, ImportFailureKind.empty);
      expect(f.nextStep, isNotEmpty);
    });

    test('the byte gate and the memory gate are different problems', () {
      final size = describeImportFailure(
        'ingest: resource limit exceeded: the file is 300 MiB, over the 256 MiB '
        'import limit; import a sample instead',
      );
      expect(size.kind, ImportFailureKind.tooLarge);
      expect(size.suggestSmallerFile, isTrue);
      expect(size.nextStep, contains('Settings'));
      expect(size.nextStep, isNot(contains('256 MiB')),
          reason: 'the production picker and clipboard may impose a smaller limit');
      expect(size.raw, contains('256 MiB'), reason: 'retain the actual engine evidence');

      final memory = describeImportFailure(
        'ingest: resource limit exceeded: the decoded columns exceed the 512 MiB '
        'memory budget; import a sample or fewer fields',
      );
      expect(memory.kind, ImportFailureKind.tooMuchMemory);
      expect(memory.suggestSmallerFile, isTrue);
    });

    test('column and row ceilings', () {
      expect(
        describeImportFailure(
          'ingest: the file has 10001 columns, which exceeds the limit of 10000',
        ).kind,
        ImportFailureKind.tooManyColumns,
      );
      expect(
        describeImportFailure('ingest: the file exceeds the row limit of 2000000').kind,
        ImportFailureKind.tooManyRows,
      );
    });

    test('malformed content offers a format override', () {
      for (final raw in [
        'ingest: JSON parse error: expected value at line 1 column 3',
        'ingest: CSV parse error: record 4 has 2 fields, expected 3',
        'ingest: the file has no header row',
      ]) {
        final f = describeImportFailure(raw);
        expect(f.kind, ImportFailureKind.malformed, reason: raw);
        expect(f.suggestFormatOverride, isTrue, reason: raw);
      }
    });

    test('an unknown hint offers a format override too', () {
      final f = describeImportFailure(
        "unknown format 'parquet'; expected csv, json, jsonl, log or txt",
      );
      expect(f.kind, ImportFailureKind.unknownFormat);
      expect(f.suggestFormatOverride, isTrue);
    });

    test('storage failures point at storage, not at the file', () {
      final f = describeImportFailure('store: No space left on device (os error 28)');
      expect(f.kind, ImportFailureKind.storage);
      expect(f.suggestSmallerFile, isFalse);
      expect(f.suggestFormatOverride, isFalse);
    });

    test('anything unrecognised is internal, and keeps the original text', () {
      const raw = 'MorphicBridgeException: something nobody has seen before';
      final f = describeImportFailure(raw);
      expect(f.kind, ImportFailureKind.internal);
      expect(f.raw, raw);
      expect(f.headline, isNotEmpty);
      expect(f.nextStep, isNotEmpty);
    });
  });

  group('copy invariants', () {
    test('every failure has a headline, a next step and the raw evidence', () {
      for (final raw in [
        'import cancelled',
        'ingest: the file is empty',
        'ingest: resource limit exceeded: the file is 300 MiB, over the 256 MiB import limit',
        'ingest: resource limit exceeded: the decoded columns exceed the 512 MiB memory budget',
        'ingest: the file has 20000 columns, which exceeds the limit of 10000',
        'ingest: the file exceeds the row limit of 2000000',
        'ingest: JSON parse error: truncated',
        "unknown format 'x'; expected csv, json, jsonl, log or txt",
        'store: permission denied',
        'total mystery',
      ]) {
        final f = describeImportFailure(raw);
        expect(f.headline, isNotEmpty, reason: raw);
        expect(f.nextStep, isNotEmpty, reason: raw);
        expect(f.raw, raw, reason: raw);
        // Engine vocabulary must not leak into the headline.
        expect(f.headline.contains('ingest:'), isFalse, reason: raw);
        expect(f.headline.contains('ResourceLimit'), isFalse, reason: raw);
      }
    });

    test('cancellation never suggests a smaller file or a different format', () {
      final f = describeImportFailure('import cancelled');
      expect(f.suggestSmallerFile, isFalse);
      expect(f.suggestFormatOverride, isFalse);
    });
  });
}
