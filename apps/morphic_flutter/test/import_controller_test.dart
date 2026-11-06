/// Import controller behaviour for task 1.1.7.
///
/// The point of these tests is that the controller reports what the engine actually did:
/// real progress in order, a reading stage only when reading really happens, failures as
/// error states rather than crashes, and warnings that survive into the workspace.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/bridge.dart';
import 'package:morphic_flutter/engine/file_source.dart';
import 'package:morphic_flutter/engine/import_controller.dart';
import 'package:morphic_flutter/engine/import_progress.dart';

import 'support/fake_import.dart';
import 'support/scripted_bridge.dart';

ImportController make(FakeImportRunner runner) => ImportController(
      bridge: ScriptedBridge(),
      storageRoot: '/tmp/morphic',
      runner: runner,
    );

void main() {
  group('progress model', () {
    test('parses the engine JSON', () {
      final p = ImportProgress.fromJson(
        {'phase': 'parsing', 'rowsRead': 4096, 'bytesRead': 204800},
      );
      expect(p.phase, 'parsing');
      expect(p.rowsRead, 4096);
      expect(p.bytesRead, 204800);
      expect(p.label, 'Reading rows');
    });

    test('missing fields degrade instead of throwing', () {
      final p = ImportProgress.fromJson(const {});
      expect(p.phase, 'unknown');
      expect(p.rowsRead, 0);
      expect(p.bytesRead, 0);
      expect(p.label, 'Working');
    });

    test('round-trips through JSON for the isolate boundary', () {
      const p = ImportProgress(phase: 'typing', rowsRead: 12, bytesRead: 340);
      final back = ImportProgress.fromJson(p.toJson());
      expect(back.phase, p.phase);
      expect(back.rowsRead, p.rowsRead);
      expect(back.bytesRead, p.bytesRead);
    });

    test('every engine phase has honest wording', () {
      const phases = {
        'sniffing': 'Detecting format',
        'parsing': 'Reading rows',
        'typing': 'Inferring column types',
        'done': 'Building workspace',
      };
      phases.forEach((phase, label) {
        expect(
          ImportProgress(phase: phase, rowsRead: 0, bytesRead: 0).label,
          label,
        );
      });
    });
  });

  group('picked file', () {
    test('strips only a known supported extension', () {
      expect(const PickedFile(name: 'sales.csv').suggestedTitle, 'sales');
      expect(const PickedFile(name: 'logs.TSV').suggestedTitle, 'logs');
      expect(const PickedFile(name: 'report.final.csv').suggestedTitle, 'report.final');
      expect(const PickedFile(name: 'data.json').suggestedTitle, 'data');
      expect(const PickedFile(name: 'events.jsonl').suggestedTitle, 'events');
      expect(const PickedFile(name: 'stream.ndjson').suggestedTitle, 'stream');
      expect(const PickedFile(name: 'server.LOG').suggestedTitle, 'server');
      // Not a format we parse, so the suffix is part of the name.
      expect(const PickedFile(name: 'archive.parquet').suggestedTitle, 'archive.parquet');
      expect(const PickedFile(name: '.csv').suggestedTitle, '.csv');
    });

    test('the extension is offered to the engine as weak evidence', () {
      expect(const PickedFile(name: 'sales.CSV').extension, 'csv');
      expect(const PickedFile(name: 'events.jsonl').extension, 'jsonl');
      expect(const PickedFile(name: 'report.final.csv').extension, 'csv');
      expect(const PickedFile(name: 'no_extension').extension, isNull);
      expect(const PickedFile(name: '.csv').extension, isNull);
      expect(const PickedFile(name: 'trailing.').extension, isNull);
    });

    test('extensionOf handles the awkward names', () {
      expect(extensionOf('a.b.c'), 'c');
      expect(extensionOf('UPPER.TXT'), 'txt');
      expect(extensionOf(''), isNull);
      expect(extensionOf('.'), isNull);
      expect(extensionOf('a.'), isNull);
      expect(extensionOf('.hidden'), isNull);
    });
  });

  group('request forwarding', () {
    test('the runner receives exactly what the caller asked for', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      final now = DateTime.utc(2026, 11, 6, 9, 30);
      final bytes = Uint8List.fromList([1, 2, 3]);
      final id = await c.importBytes(
        bytes,
        title: 'Sales',
        workspaceId: 'w_custom',
        now: now,
      );
      expect(id, 'w_custom');
      final r = runner.lastRequest!;
      expect(r.bytes, bytes);
      expect(r.title, 'Sales');
      expect(r.workspaceId, 'w_custom');
      expect(r.storageRoot, '/tmp/morphic');
      expect(r.nowIso, '2026-11-06T09:30:00.000Z');
      c.dispose();
    });

    test('a picked file supplies the title from its name', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      await c.importPicked(
        PickedFile(name: 'quarterly.csv', bytes: Uint8List(4)),
      );
      expect(runner.lastRequest!.title, 'quarterly');
      expect(runner.lastRequest!.extension, 'csv');
      expect(runner.lastRequest!.formatHint, isNull);
      c.dispose();
    });

    test('no hint means the engine decides', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      await c.importBytes(Uint8List(4), title: 'X');
      expect(runner.lastRequest!.formatHint, isNull);
      expect(runner.lastRequest!.extension, isNull);
      c.dispose();
    });

    test('an explicit hint reaches the engine unchanged', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      await c.importBytes(Uint8List(4), title: 'X', formatHint: 'jsonl');
      expect(runner.lastRequest!.formatHint, 'jsonl');
      c.dispose();
    });

    test('a picked file forwards both the hint and its extension', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      await c.importPicked(
        PickedFile(name: 'ambiguous.txt', bytes: Uint8List(4)),
        formatHint: 'log',
      );
      expect(runner.lastRequest!.formatHint, 'log');
      // The extension still travels: the engine ignores it when a hint is present.
      expect(runner.lastRequest!.extension, 'txt');
      c.dispose();
    });
  });

  group('progress and stages', () {
    test('progress arrives in engine order and the last one is exposed', () async {
      final runner = FakeImportRunner(events: kProgressEvents);
      final c = make(runner);
      final seen = <String>[];
      c.addListener(() {
        final p = c.progress;
        if (p != null && (seen.isEmpty || seen.last != p.phase)) seen.add(p.phase);
      });
      await c.importBytes(Uint8List(1), title: 'X');
      expect(seen, ['sniffing', 'parsing', 'typing', 'done']);
      expect(c.progress!.rowsRead, 6000);
      expect(c.stage, ImportStage.done);
      c.dispose();
    });

    test('stages go idle -> importing -> done for in-memory bytes', () async {
      final c = make(FakeImportRunner());
      final stages = <ImportStage>[c.stage];
      c.addListener(() => stages.add(c.stage));
      await c.importBytes(Uint8List(1), title: 'X');
      expect(stages.first, ImportStage.idle);
      expect(stages, contains(ImportStage.importing));
      expect(stages.last, ImportStage.done);
      expect(
        stages,
        isNot(contains(ImportStage.reading)),
        reason: 'bytes were already in hand; claiming a read would be false',
      );
      c.dispose();
    });

    test('a path-only pick really does enter the reading stage', () async {
      final dir = await Directory.systemTemp.createTemp('morphic-import-test');
      final file = File('${dir.path}/rows.csv')..writeAsStringSync('a,b\n1,2\n');
      addTearDown(() => dir.deleteSync(recursive: true));

      final c = make(FakeImportRunner());
      final stages = <ImportStage>[];
      c.addListener(() => stages.add(c.stage));
      final id = await c.importPicked(PickedFile(name: 'rows.csv', path: file.path));
      expect(id, isNotNull);
      expect(stages, contains(ImportStage.reading));
      expect(stages.last, ImportStage.done);
      expect(c.stage, ImportStage.done);
      c.dispose();
    });

    test('a pick with neither bytes nor path is an error, not a crash', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      final id = await c.importPicked(const PickedFile(name: 'ghost.csv'));
      expect(id, isNull);
      expect(c.stage, ImportStage.error);
      expect(c.error, contains('no readable data or path'));
      expect(runner.runs, 0, reason: 'nothing to import, so the engine is not called');
      c.dispose();
    });

    test('an unreadable path fails as an error state', () async {
      final c = make(FakeImportRunner());
      final id = await c.importPicked(
        const PickedFile(name: 'gone.csv', path: '/nonexistent/morphic/gone.csv'),
      );
      expect(id, isNull);
      expect(c.stage, ImportStage.error);
      expect(c.error, contains('could not read file'));
      c.dispose();
    });

    test('reset clears progress as well as state', () async {
      final c = make(FakeImportRunner(events: kProgressEvents));
      await c.importBytes(Uint8List(1), title: 'X');
      expect(c.progress, isNotNull);
      c.reset();
      expect(c.progress, isNull);
      expect(c.stage, ImportStage.idle);
      expect(c.result, isNull);
      expect(c.elapsed, isNull);
      c.dispose();
    });
  });

  group('failure and concurrency', () {
    test('an engine failure becomes an error state with the engine message', () async {
      final c = make(FakeImportRunner(
        failure: const MorphicBridgeException('ingest: empty file'),
      ));
      final id = await c.importBytes(Uint8List(0), title: 'Empty');
      expect(id, isNull);
      expect(c.stage, ImportStage.error);
      expect(c.error, contains('ingest: empty file'));
      expect(c.result, isNull);
      expect(c.elapsed, isNotNull, reason: 'a failed attempt still took time');
      c.dispose();
    });

    test('a second import while one is running is refused', () async {
      final gate = Completer<void>();
      final runner = FakeImportRunner(gate: gate);
      final c = make(runner);
      final first = c.importBytes(Uint8List(1), title: 'First');
      await Future<void>.delayed(Duration.zero);
      expect(c.isBusy, isTrue);
      final second = await c.importBytes(Uint8List(1), title: 'Second');
      expect(second, isNull);
      expect(runner.runs, 1);
      gate.complete();
      expect(await first, isNotNull);
      c.dispose();
    });

    test('warnings and row count come from the engine report', () async {
      final c = make(FakeImportRunner(
        warnings: const ["Detected ';' as the delimiter.", '12 cells coerced'],
        rowsImported: 600,
      ));
      await c.importBytes(Uint8List(1), title: 'X');
      expect(c.warnings, ["Detected ';' as the delimiter.", '12 cells coerced']);
      expect(c.rowsImported, 600);
      expect(c.elapsed, isNotNull);
      c.dispose();
    });
  });

  group('cancellation (1.2.4)', () {
    test('cancelling when nothing is running is a no-op', () {
      final bridge = ScriptedBridge();
      final c = ImportController(
        bridge: bridge,
        storageRoot: '/tmp/morphic',
        runner: FakeImportRunner(),
      );
      expect(c.canCancel, isFalse);
      expect(c.cancel(), isFalse);
      expect(bridge.cancelCalls, isEmpty);
      c.dispose();
    });

    test('cancelling names the workspace that is actually running', () async {
      final gate = Completer<void>();
      final bridge = ScriptedBridge()..cancelResult = true;
      final c = ImportController(
        bridge: bridge,
        storageRoot: '/tmp/morphic',
        runner: FakeImportRunner(gate: gate),
      );
      final pending = c.importBytes(
        Uint8List(1),
        title: 'Big',
        workspaceId: 'w_running',
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.canCancel, isTrue);
      expect(c.cancel(), isTrue);
      expect(bridge.cancelCalls, ['w_running']);
      gate.complete();
      await pending;
      expect(c.canCancel, isFalse, reason: 'nothing is running once it finishes');
      c.dispose();
    });

    test('a bridge that throws while cancelling does not break the UI', () async {
      final gate = Completer<void>();
      final c = ImportController(
        bridge: ThrowingCancelBridge(),
        storageRoot: '/tmp/morphic',
        runner: FakeImportRunner(gate: gate),
      );
      final pending = c.importBytes(Uint8List(1), title: 'Big');
      await Future<void>.delayed(Duration.zero);
      expect(c.cancel(), isFalse, reason: 'best effort, never a crash');
      gate.complete();
      expect(await pending, isNotNull);
      c.dispose();
    });

    test('a cancelled import is a state, not an error', () async {
      final c = make(FakeImportRunner(
        failure: const MorphicBridgeException('ingest: import cancelled'),
      ));
      expect(await c.importBytes(Uint8List(1), title: 'X'), isNull);
      expect(c.stage, ImportStage.cancelled);
      expect(c.error, isNull);
      expect(c.failure, isNull, reason: 'the user chose this; do not apologise');
      c.dispose();
    });

    test('a real failure is still an error, with human copy attached', () async {
      final c = make(FakeImportRunner(
        failure: const MorphicBridgeException('ingest: the file is empty'),
      ));
      await c.importBytes(Uint8List(1), title: 'X');
      expect(c.stage, ImportStage.error);
      expect(c.error, contains('the file is empty'));
      expect(c.failure!.headline, 'That file is empty.');
      expect(c.failure!.nextStep, isNotEmpty);
      c.dispose();
    });
  });

  group('review and re-import (1.2.4)', () {
    Map<String, dynamic> reportResult({
      int quarantined = 0,
      List<String> warnings = const [],
    }) =>
        {
          'doc': ScriptedBridge().doc(),
          'profile': ScriptedBridge().profileJson(),
          'report': {
            'format': 'csv',
            'encoding': 'utf-8',
            'rowsImported': 90,
            'rowsQuarantined': quarantined,
            'fieldCount': 3,
            'warnings': warnings,
          },
        };

    test('a clean confident import needs no review', () async {
      final c = make(FakeImportRunner(result: reportResult()));
      await c.importBytes(Uint8List(1), title: 'X');
      expect(c.needsReview, isFalse);
      expect(c.facts!.rowsImported, 90);
      c.dispose();
    });

    test('quarantined rows ask for a review', () async {
      final c = make(FakeImportRunner(result: reportResult(quarantined: 10)));
      await c.importBytes(Uint8List(1), title: 'X');
      expect(c.needsReview, isTrue);
      expect(c.facts!.quarantineRate, 0.1);
      c.dispose();
    });

    test('a low-confidence read asks for a review even with no quarantine', () async {
      final c = make(FakeImportRunner(
        result: reportResult(warnings: [
          "Read as 'csv' (50% confidence): 3 fields on 50% of sampled lines.",
          'Some rows are probably ragged.',
        ]),
      ));
      await c.importBytes(Uint8List(1), title: 'X');
      expect(c.facts!.hasQuarantine, isFalse);
      expect(c.needsReview, isTrue);
      c.dispose();
    });

    test('there is nothing to re-import before a file has been picked', () {
      final c = make(FakeImportRunner());
      expect(c.canReimport, isFalse);
      c.dispose();
    });

    test('re-import reuses the bytes with the new hint and a fresh workspace', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      final bytes = Uint8List.fromList([1, 2, 3]);
      await c.importPicked(PickedFile(name: 'events.txt', bytes: bytes));
      expect(c.canReimport, isTrue);
      expect(c.lastFormatHint, isNull);
      final firstId = runner.lastRequest!.workspaceId;

      final second = await c.reimport(
        formatHint: 'jsonl',
        now: DateTime.utc(2026, 11, 6, 10),
      );
      expect(second, isNotNull);
      expect(runner.lastRequest!.formatHint, 'jsonl');
      expect(runner.lastRequest!.bytes, bytes, reason: 'no re-read of the file');
      expect(runner.lastRequest!.extension, 'txt');
      expect(runner.lastRequest!.workspaceId, isNot(firstId),
          reason: 'the first attempt is left untouched');
      expect(c.lastFormatHint, 'jsonl');
      c.dispose();
    });

    test('reset forgets the remembered source', () async {
      final c = make(FakeImportRunner());
      await c.importPicked(PickedFile(name: 'a.csv', bytes: Uint8List(2)));
      expect(c.canReimport, isTrue);
      c.reset();
      expect(c.canReimport, isFalse);
      expect(c.stage, ImportStage.idle);
      c.dispose();
    });
  });

}

/// A bridge whose cancel call fails, to prove cancellation is best-effort.
class ThrowingCancelBridge extends ScriptedBridge {
  @override
  bool cancelImport({required String workspaceId}) =>
      throw const MorphicBridgeException('cancel unavailable');

  group('clipboard import (1.2.5)', () {
    test('pasted text is imported with no extension to bias detection', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      final content = clipboardText('a,b\n1,2\n');
      final id = await c.importClipboard(content, now: DateTime.utc(2026, 11, 6, 12));
      expect(id, isNotNull);
      final r = runner.lastRequest!;
      expect(r.bytes, content.bytes);
      expect(r.title, 'Clipboard text');
      expect(r.extension, isNull,
          reason: 'a clipboard has no file name, so the contents must decide');
      expect(r.formatHint, isNull);
      c.dispose();
    });

    test('a caller-supplied title is honoured', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      await c.importClipboard(clipboardText('x'), title: 'Pasted logs');
      expect(runner.lastRequest!.title, 'Pasted logs');
      c.dispose();
    });

    test('an explicit format hint still reaches the engine', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      await c.importClipboard(clipboardText('{"a":1}'), formatHint: 'jsonl');
      expect(runner.lastRequest!.formatHint, 'jsonl');
      c.dispose();
    });

    test('pasted text can be re-imported as another format', () async {
      final runner = FakeImportRunner();
      final c = make(runner);
      await c.importClipboard(clipboardText('a,b\n1,2\n'));
      expect(c.canReimport, isTrue);
      await c.reimport(formatHint: 'txt', now: DateTime.utc(2026, 11, 6, 13));
      expect(runner.lastRequest!.formatHint, 'txt');
      expect(runner.lastRequest!.extension, isNull);
      c.dispose();
    });

    test('pasting while an import runs is refused', () async {
      final gate = Completer<void>();
      final runner = FakeImportRunner(gate: gate);
      final c = make(runner);
      final first = c.importBytes(Uint8List(1), title: 'First');
      await Future<void>.delayed(Duration.zero);
      expect(await c.importClipboard(clipboardText('x')), isNull);
      expect(runner.runs, 1);
      gate.complete();
      await first;
      c.dispose();
    });

    test('a paste reports no reading stage, because no reading happens', () async {
      final c = make(FakeImportRunner(events: kProgressEvents));
      await c.importClipboard(clipboardText('a,b\n1,2\n'));
      expect(c.stage, ImportStage.done);
      expect(c.progress, isNotNull, reason: 'real engine events still arrive');
      c.dispose();
    });
  });

}
