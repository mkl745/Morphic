/// Bundled sample catalog and import path (M1.6 task 1.6.4).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/sample_import.dart';
import 'package:morphic_flutter/engine/sample_source.dart';

import '../support/fake_import.dart';
import '../support/scripted_bridge.dart';

SampleDataset _sample(String id) =>
    sampleDatasets.firstWhere((sample) => sample.id == id);

void main() {
  test('the catalog has four synthetic samples with honest format facts', () {
    expect(sampleDatasets.length, 4);
    expect(sampleDatasets.map((sample) => sample.id).toSet().length, 4);
    expect(
      sampleDatasets.map((sample) => sample.title),
      containsAll(const <String>['Server logs', 'Sales CSV', 'Sensor JSON']),
    );
    for (final sample in sampleDatasets) {
      expect(sample.description, isNotEmpty);
      expect(sample.assetPath, startsWith('assets/samples/'));
      expect(const <String>['csv', 'json', 'log'], contains(sample.extension));
      expect(sample.formatHint, sample.extension);
    }
  });

  test('a sample reaches the real import controller with its bytes and format', () async {
    final bytes = Uint8List.fromList(utf8.encode('region,amount\neu,10\n'));
    final source = FakeSampleSource(bytes);
    final runner = FakeImportRunner();
    final importer = EngineSampleImporter(
      bridge: ScriptedBridge(),
      storageRoot: '/tmp/morphic-sample-test',
      runner: runner,
      source: source,
      now: DateTime.utc(2026, 11, 6, 9, 30),
    );

    final outcome = await importer.open(_sample('sales'));

    expect(source.calls, 1);
    expect(source.lastDataset!.id, 'sales');
    expect(runner.runs, 1);
    expect(runner.lastRequest!.bytes, same(bytes));
    expect(runner.lastRequest!.title, 'Sales CSV');
    expect(runner.lastRequest!.formatHint, 'csv');
    expect(runner.lastRequest!.extension, 'csv');
    expect(runner.lastRequest!.nowIso, '2026-11-06T09:30:00.000Z');
    expect(outcome.workspaceId, isNotEmpty);
    expect(outcome.controller.doc?['workspace'], isNotNull);
    expect(outcome.warnings, isEmpty);
  });

  test('a missing asset is surfaced without ever calling the engine', () async {
    final runner = FakeImportRunner();
    final importer = EngineSampleImporter(
      bridge: ScriptedBridge(),
      storageRoot: '/tmp/morphic-sample-test',
      runner: runner,
      source: FakeSampleSource(
        Uint8List(0),
        failure: StateError('missing asset'),
      ),
    );

    await expectLater(
      importer.open(_sample('sensors')),
      throwsA(isA<StateError>()),
    );
    expect(runner.runs, 0);
  });

  test('an engine refusal is surfaced instead of opening an empty workspace', () async {
    final importer = EngineSampleImporter(
      bridge: ScriptedBridge(),
      storageRoot: '/tmp/morphic-sample-test',
      runner: FakeImportRunner(failure: StateError('engine refused')),
      source: FakeSampleSource(Uint8List.fromList(utf8.encode('a,b\n1,2\n'))),
    );

    await expectLater(
      importer.open(_sample('server-logs')),
      throwsA(isA<StateError>()),
    );
  });
}
