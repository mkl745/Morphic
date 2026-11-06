/// Contract tests for the Dart controllers against a recording fake bridge.
///
/// These assert the *contract* — what the UI asks the engine for and how it handles the
/// answer — without loading the native library. The Rust half of the same contract is
/// covered by the bridge crate's FFI tests.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/bridge.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/import_controller.dart';

/// Records every call so tests can assert the controller never computes data itself.
class RecordingBridge implements MorphicBridge {
  final List<String> calls = [];
  final List<Map<String, dynamic>> plans = [];
  bool failImport = false;
  bool failQuery = false;
  Object? metricValue = 42;
  List<String> importWarnings = [];

  Map<String, dynamic> _doc() => {
        'schemaVersion': '1.0',
        'workspace': {
          'id': 'w1',
          'title': 'Sales',
          'revision': 7,
          'layout': {
            'order': ['data_table', 'total_records'],
          },
          'components': [
            {'id': 'total_records', 'type': 'metric_card', 'title': 'Records'},
            {'id': 'data_table', 'type': 'data_table', 'title': 'Data'},
          ],
        },
      };

  @override
  EngineInfo engineInfo() =>
      const EngineInfo(apiVersion: 2, coreVersion: '0.1.0', engine: 'morphic');

  @override
  Map<String, dynamic> profileCsv(Uint8List bytes) => {'rowCount': 3, 'fieldCount': 2};

  @override
  Map<String, dynamic> createWorkspace({
    required Uint8List bytes,
    required String storageRoot,
    required String title,
    required String workspaceId,
    required String nowIso,
  }) =>
      _doc();

  @override
  Map<String, dynamic> loadWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) =>
      _doc();

  @override
  List<dynamic> listWorkspaces(String storageRoot) {
    calls.add('list');
    return [
      {'id': 'w1', 'title': 'Sales', 'modifiedAt': '2026-11-05T00:00:00Z'},
    ];
  }

  @override
  Map<String, dynamic> importCsv({
    required Uint8List bytes,
    required String storageRoot,
    required String title,
    required String workspaceId,
    required String nowIso,
  }) {
    calls.add('import:$workspaceId');
    if (failImport) throw const MorphicBridgeException('ingest: empty file');
    return {
      'doc': _doc(),
      'profile': {'rowCount': 3, 'fieldCount': 2},
      'report': {'rowsImported': 3, 'warnings': importWarnings},
    };
  }

  @override
  Map<String, dynamic> snapshot({
    required String storageRoot,
    required String workspaceId,
  }) {
    calls.add('snapshot:$workspaceId');
    return {'doc': _doc(), 'profile': {'rowCount': 3}, 'revision': 7};
  }

  @override
  Map<String, dynamic> queryPage({
    required String storageRoot,
    required String workspaceId,
    Map<String, dynamic>? plan,
  }) {
    calls.add('query:$workspaceId');
    plans.add(plan ?? {});
    if (failQuery) throw const MorphicBridgeException('query: unknown field');
    return {
      'rows': [
        ['eu', 10],
        ['us', 20],
      ],
      'totalRows': 5,
      'offset': plan?['offset'] ?? 0,
      'limit': plan?['limit'] ?? 256,
      'hasMore': true,
    };
  }

  @override
  Map<String, dynamic> metricData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  }) {
    calls.add('metric:$componentId');
    return {'componentId': componentId, 'value': metricValue, 'revision': 7};
  }

  @override
  Map<String, dynamic> closeWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) {
    calls.add('close:$workspaceId');
    return {'closed': true};
  }
}

void main() {
  group('ImportController', () {
    test('happy path reaches done and exposes the engine report', () async {
      final bridge = RecordingBridge();
      final c = ImportController(bridge: bridge, storageRoot: '/tmp/m');
      final stages = <ImportStage>[];
      c.addListener(() => stages.add(c.stage));

      final id = await c.importBytes(
        Uint8List.fromList([1, 2, 3]),
        title: 'Sales',
        workspaceId: 'w1',
        now: DateTime.utc(2026, 11, 5),
      );

      expect(id, 'w1');
      expect(c.stage, ImportStage.done);
      expect(c.error, isNull);
      expect(c.rowsImported, 3);
      expect(c.result, isNotNull);
      expect(stages, [ImportStage.importing, ImportStage.done]);
      expect(bridge.calls, ['import:w1']);
      expect(c.elapsed, isNotNull);
    });

    test('engine errors become an error state, never a crash', () async {
      final bridge = RecordingBridge()..failImport = true;
      final c = ImportController(bridge: bridge, storageRoot: '/tmp/m');
      final id = await c.importBytes(Uint8List(0), title: 'Empty');
      expect(id, isNull);
      expect(c.stage, ImportStage.error);
      expect(c.error, contains('empty file'));
      expect(c.result, isNull);
    });

    test('engine warnings are surfaced, not swallowed', () async {
      final bridge = RecordingBridge()
        ..importWarnings = ['encoding fell back to latin-1', "column 'd' is ambiguous"];
      final c = ImportController(bridge: bridge, storageRoot: '/tmp/m');
      await c.importBytes(Uint8List(1), title: 'X', workspaceId: 'w1');
      expect(c.warnings.length, 2);
      expect(c.warnings.first, contains('latin-1'));
    });

    test('a generated workspace id is stable for a given clock', () async {
      final bridge = RecordingBridge();
      final c = ImportController(bridge: bridge, storageRoot: '/tmp/m');
      final now = DateTime.utc(2026, 11, 5);
      final id = await c.importBytes(Uint8List(1), title: 'X', now: now);
      expect(id, 'w_${now.millisecondsSinceEpoch}');
    });

    test('reset clears state', () async {
      final c = ImportController(bridge: RecordingBridge(), storageRoot: '/tmp/m');
      await c.importBytes(Uint8List(1), title: 'X', workspaceId: 'w1');
      c.reset();
      expect(c.stage, ImportStage.idle);
      expect(c.result, isNull);
      expect(c.rowsImported, isNull);
      expect(c.warnings, isEmpty);
    });

    test('a missing file is an error state', () async {
      final c = ImportController(bridge: RecordingBridge(), storageRoot: '/tmp/m');
      final id = await c.importFile(_nonexistentFile());
      expect(id, isNull);
      expect(c.stage, ImportStage.error);
      expect(c.error, contains('could not read file'));
    });
  });

  group('EngineController', () {
    test('open adopts the engine snapshot and revision', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      expect(await c.open('w1'), isTrue);
      expect(c.workspaceId, 'w1');
      expect(c.revision, 7);
      expect(c.doc, isNotNull);
      expect(c.busy, isFalse);
      expect(bridge.calls, ['snapshot:w1']);
    });

    test('components are returned in layout order, not document order', () async {
      final c = EngineController(bridge: RecordingBridge(), storageRoot: '/tmp/m');
      await c.open('w1');
      expect(c.components.map((e) => e['id']).toList(),
          ['data_table', 'total_records']);
    });

    test('adoptImport avoids a redundant snapshot round trip', () {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      c.adoptImport({
        'doc': {
          'workspace': {'id': 'w1', 'revision': 3, 'components': []}
        },
        'profile': {'rowCount': 3},
      }, 'w1');
      expect(c.revision, 3);
      expect(bridge.calls, isEmpty);
    });

    test('page forwards the plan to Rust instead of slicing locally', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      final page = await c.page(offset: 2, limit: 2, search: 'eu');
      expect(page, isNotNull);
      expect(page!.totalRows, 5);
      expect(page.offset, 2);
      expect(page.limit, 2);
      expect(page.hasMore, isTrue);
      expect(bridge.plans.last, {'offset': 2, 'limit': 2, 'search': 'eu'});
    });

    test('an empty search is omitted from the plan', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      await c.page(search: '');
      expect(bridge.plans.last.containsKey('search'), isFalse);
    });

    test('page before open is a guarded error, not a crash', () async {
      final c = EngineController(bridge: RecordingBridge(), storageRoot: '/tmp/m');
      expect(await c.page(), isNull);
      expect(c.error, contains('no workspace open'));
    });

    test('query failures surface as controller errors', () async {
      final bridge = RecordingBridge()..failQuery = true;
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      expect(await c.page(), isNull);
      expect(c.error, contains('unknown field'));
    });

    test('metric values come from Rust, including null for no data', () async {
      final bridge = RecordingBridge()..metricValue = null;
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      expect(await c.metric('total_records'), isNull);
      expect(bridge.calls, contains('metric:total_records'));
    });

    test('close releases the session and clears the view', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      await c.closeWorkspace();
      expect(c.workspaceId, isNull);
      expect(c.doc, isNull);
      expect(c.revision, 0);
      expect(bridge.calls, contains('close:w1'));
    });

    test('library lists persisted workspaces', () {
      final c = EngineController(bridge: RecordingBridge(), storageRoot: '/tmp/m');
      expect(c.library().length, 1);
    });
  });

  group('PageResult', () {
    test('parses a missing payload defensively', () {
      final p = PageResult.fromJson({});
      expect(p.rows, isEmpty);
      expect(p.totalRows, 0);
      expect(p.hasMore, isFalse);
      expect(p.isEmpty, isTrue);
    });
  });
}

// A path that cannot exist, so importFile exercises its read-error branch.
File _nonexistentFile() => File('/nonexistent/morphic/definitely-missing.csv');
