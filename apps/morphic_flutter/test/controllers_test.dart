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
  @override
  Map<String, dynamic> applyCommands({
    required String storageRoot,
    required String workspaceId,
    required List<Map<String, dynamic>> commands,
    required String nowIso,
  }) {
    commandBatches.add(commands);
    lastNowIso = nowIso;
    if (failCommands) {
      throw const MorphicBridgeException("commands: filter field 'nope' is unknown");
    }
    return commandOutcome ??
        {
          'revision': 8,
          'affected': ['data_table'],
          'changed': true,
          'doc': _doc(),
        };
  }

  @override
  Map<String, dynamic> undo({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  }) {
    undoCalls++;
    calls.add('undo:$workspaceId');
    return undoOutcome ??
        {
          'revision': 9,
          'affected': <String>[],
          'changed': true,
          'doc': _doc(),
          'stateHash': 'undo-hash',
          'undoDepth': 0,
          'redoDepth': 1,
          'undoLabel': '',
          'redoLabel': 'Applied changes',
          'label': 'Undid Applied changes',
        };
  }

  @override
  Map<String, dynamic> redo({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  }) {
    redoCalls++;
    calls.add('redo:$workspaceId');
    return redoOutcome ??
        {
          'revision': 10,
          'affected': <String>[],
          'changed': true,
          'doc': _doc(),
          'stateHash': 'redo-hash',
          'undoDepth': 1,
          'redoDepth': 0,
          'undoLabel': 'Applied changes',
          'redoLabel': '',
          'label': 'Redid Applied changes',
        };
  }

  @override
  Map<String, dynamic> componentPage({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
    required int offset,
    required int limit,
  }) {
    componentPageCalls.add({
      'componentId': componentId,
      'offset': offset,
      'limit': limit,
    });
    if (failQuery) throw const MorphicBridgeException('query: unknown field');
    return {
      'rows': [
        ['eu', 10],
      ],
      'totalRows': 5,
      'offset': offset,
      'limit': limit,
      'hasMore': true,
    };
  }

  final List<String> calls = [];
  final List<Map<String, dynamic>> plans = [];
  final List<List<Map<String, dynamic>>> commandBatches = [];
  final List<Map<String, dynamic>> componentPageCalls = [];
  bool failCommands = false;
  bool failMetric = false;
  Map<String, dynamic>? commandOutcome;
  Map<String, dynamic>? undoOutcome;
  Map<String, dynamic>? redoOutcome;
  int undoCalls = 0;
  int redoCalls = 0;
  String? lastNowIso;
  bool failImport = false;
  bool failQuery = false;
  Object? metricValue = 42;
  List<String> importWarnings = [];

  /// Off by default so stage-transition assertions keep their meaning: a progress event
  /// notifies listeners without changing the stage. Turned on to test forwarding itself.
  bool emitProgress = false;

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
  Map<String, dynamic> renameWorkspace({
    required String storageRoot,
    required String workspaceId,
    required String title,
    required String nowIso,
  }) {
    calls.add('rename:$workspaceId:$title');
    return _doc();
  }

  @override
  Map<String, dynamic> duplicateWorkspace({
    required String storageRoot,
    required String workspaceId,
    required String newWorkspaceId,
    required String title,
    required String nowIso,
  }) {
    calls.add('duplicate:$workspaceId:$newWorkspaceId:$title');
    return _doc();
  }

  @override
  Map<String, dynamic> deleteWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) {
    calls.add('delete:$workspaceId');
    return {'deleted': true};
  }

  @override
  Map<String, dynamic> relinkWorkspace({
    required Uint8List bytes,
    required String storageRoot,
    required String workspaceId,
  }) {
    calls.add('relink:$workspaceId:${bytes.length}');
    return {'relinked': true};
  }

  @override
  EngineInfo engineInfo() =>
      const EngineInfo(apiVersion: 13, coreVersion: '0.1.0', engine: 'morphic');

  @override
  RecoveryReport recoveryReport(String storageRoot) => const RecoveryReport();

  @override
  Map<String, dynamic> saveWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) =>
      {
        'revision': 1,
        'stateHash': 'fake',
        'dirty': false,
        'compacted': true,
      };

  @override
  Map<String, dynamic> exportBundle({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  }) {
    calls.add('export:$workspaceId');
    return {'bundleJson': '{}', 'bytes': 2, 'manifest': {}};
  }

  @override
  Map<String, dynamic> importBundle({
    required Uint8List bytes,
    required String storageRoot,
    required String workspaceId,
    required String title,
    required String nowIso,
  }) {
    calls.add('import:$workspaceId:$title');
    return {'doc': {}, 'sourceTitle': title, 'datasetCount': 0};
  }

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

  /// What the controller actually forwarded, so the override path is testable end to end.
  String? lastFormatHint;
  String? lastExtension;

  @override
  Map<String, dynamic> importFile({
    required Uint8List bytes,
    required String storageRoot,
    required String title,
    required String workspaceId,
    required String nowIso,
    String? formatHint,
    String? extension,
    void Function(Map<String, dynamic> progress)? onProgress,
  }) {
    calls.add('import:$workspaceId');
    lastFormatHint = formatHint;
    lastExtension = extension;
    if (emitProgress) {
      onProgress?.call({'phase': 'parsing', 'rowsRead': 3, 'bytesRead': 32});
    }
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
    if (failMetric) {
      throw const MorphicBridgeException("core: source data for workspace 'w1' is unavailable");
    }
    return {'componentId': componentId, 'value': metricValue, 'revision': 7};
  }

  bool failChart = false;

  @override
  Map<String, dynamic> chartData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  }) {
    calls.add('chart:$componentId');
    if (failChart) {
      throw const MorphicBridgeException("core: component 'x' is a data_table, not a chart");
    }
    return {
      'componentId': componentId,
      'revision': 7,
      'scene': {
        'kind': 'category',
        'dimension': 'region',
        'measure': 'count',
        'points': [
          {'label': 'eu', 'value': 2, 'rowCount': 2},
        ],
        'other': null,
        'totalCategories': 1,
        'truncated': false,
      },
    };
  }

  bool cancelResult = false;

  @override
  bool cancelImport({required String workspaceId}) {
    calls.add('cancel:$workspaceId');
    return cancelResult;
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

    test('the default inline runner forwards engine progress to the controller',
        () async {
      final bridge = RecordingBridge()..emitProgress = true;
      // No runner passed: this exercises InlineImportRunner, the default.
      final c = ImportController(bridge: bridge, storageRoot: '/tmp/m');
      final phases = <String>[];
      c.addListener(() {
        final p = c.progress;
        if (p != null) phases.add(p.phase);
      });

      await c.importBytes(Uint8List.fromList([1, 2, 3]), title: 'Sales');

      expect(phases, contains('parsing'));
      expect(c.progress!.rowsRead, 3);
      expect(c.progress!.bytesRead, 32);
      expect(c.stage, ImportStage.done);
      c.dispose();
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

    test('applyCommands forwards the batch and adopts the returned document',
        () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      final cmds = [
        {
          'kind': 'setComponentSort',
          'componentId': 'data_table',
          'sort': [
            {'field': 'amount', 'dir': 'desc', 'nulls': 'last'},
          ],
        },
      ];
      final affected = await c.applyCommands(cmds);
      expect(affected, ['data_table']);
      expect(bridge.commandBatches.single, cmds);
      expect(c.revision, 8, reason: 'the engine owns the revision, not the UI');
      expect(c.doc, isNotNull);
      expect(c.error, isNull);
      // Rust stamps the timestamp; Dart only supplies a UTC clock reading.
      expect(bridge.lastNowIso, isNotNull);
      expect(bridge.lastNowIso!, endsWith('Z'));
    });

    test('a rejected batch leaves the previous document current', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      final before = c.revision;
      final docBefore = c.doc;
      bridge.failCommands = true;
      final affected = await c.applyCommands([
        {'kind': 'setComponentFilter', 'componentId': 'data_table', 'filter': null},
      ]);
      expect(affected, isNull);
      expect(c.revision, before, reason: 'a rejected batch must not bump the revision');
      expect(identical(c.doc, docBefore), isTrue,
          reason: 'nothing was applied, so the old document is still the truth');
      expect(c.error, contains('unknown'));
    });

    test('an empty batch is a no-op that never reaches the bridge', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      expect(await c.applyCommands([]), isEmpty);
      expect(bridge.commandBatches, isEmpty);
    });

    test('applyCommands before open is a guarded error, not a crash', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      expect(await c.applyCommands([
        {'kind': 'setSearch', 'componentId': 'data_table', 'text': 'x'},
      ]), isNull);
      expect(c.error, isNotNull);
      expect(bridge.commandBatches, isEmpty);
    });

    test('componentPage asks Rust for the page instead of building a plan', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      final page = await c.componentPage('data_table', offset: 2, limit: 2);
      expect(page, isNotNull);
      expect(page!.rows, [
        ['eu', 10],
      ]);
      expect(page.totalRows, 5);
      expect(bridge.componentPageCalls.single,
          {'componentId': 'data_table', 'offset': 2, 'limit': 2});
      expect(bridge.plans, isEmpty,
          reason: 'the composed plan is Rust\'s job — it must apply global filters too');
    });

    test('a component page failure is null with the error recorded', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      bridge.failQuery = true;
      expect(await c.componentPage('data_table'), isNull);
      expect(c.error, contains('unknown field'));
    });

    test('componentPage before open is a guarded error, not a crash', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      expect(await c.componentPage('data_table'), isNull);
      expect(c.error, isNotNull);
      expect(bridge.componentPageCalls, isEmpty);
    });

    test('a failing read notifies after the caller\'s synchronous frame', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      bridge.failMetric = true;
      var notified = false;
      c.addListener(() => notified = true);

      // A renderer calls this from initState. The bridge is synchronous, so notifying here
      // would mark an ancestor AnimatedBuilder dirty mid-build and throw.
      final pending = c.metric('total_records');
      expect(notified, isFalse, reason: 'notification must not land during the build phase');
      await expectLater(pending, throwsA(isA<MorphicBridgeException>()));
      expect(notified, isTrue, reason: 'the failure is still reported, just after the frame');
    });

    test('a failing component page also defers its notification', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      bridge.failQuery = true;
      var notified = false;
      c.addListener(() => notified = true);
      final pending = c.componentPage('data_table');
      expect(notified, isFalse);
      expect(await pending, isNull);
      expect(notified, isTrue);
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

    test('undo and redo are bridge calls that adopt engine history', () async {
      final bridge = RecordingBridge();
      final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await c.open('w1');
      expect(c.undoDepth, 0);
      expect(c.redoDepth, 0);

      final undo = await c.undo();
      expect(bridge.undoCalls, 1);
      expect(bridge.calls, contains('undo:w1'));
      expect(undo?['label'], 'Undid Applied changes');
      expect(c.stateHash, 'undo-hash');
      expect(c.undoDepth, 0);
      expect(c.redoDepth, 1);
      expect(c.redoLabel, 'Applied changes');

      final redo = await c.redo();
      expect(bridge.redoCalls, 1);
      expect(bridge.calls, contains('redo:w1'));
      expect(redo?['label'], 'Redid Applied changes');
      expect(c.stateHash, 'redo-hash');
      expect(c.undoDepth, 1);
      expect(c.redoDepth, 0);
      expect(c.undoLabel, 'Applied changes');
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
