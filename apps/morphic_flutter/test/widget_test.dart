import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/app.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/bridge.dart';
import 'package:morphic_flutter/features/workspace/workspace_screen.dart';

/// A fake bridge so widget tests run without the native library.
class FakeBridge implements MorphicBridge {
  @override
  Map<String, dynamic> applyCommands({
    required String storageRoot,
    required String workspaceId,
    required List<Map<String, dynamic>> commands,
    required String nowIso,
  }) {
    return {'revision': 1, 'affected': <String>[], 'changed': false, 'doc': _sampleDoc()};
  }

  @override
  Map<String, dynamic> undo({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  }) =>
      {
        'revision': 1,
        'affected': <String>[],
        'changed': false,
        'doc': _sampleDoc(),
        'stateHash': '',
        'undoDepth': 0,
        'redoDepth': 0,
        'undoLabel': '',
        'redoLabel': '',
        'label': 'Nothing to undo',
      };

  @override
  Map<String, dynamic> redo({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  }) =>
      {
        'revision': 1,
        'affected': <String>[],
        'changed': false,
        'doc': _sampleDoc(),
        'stateHash': '',
        'undoDepth': 0,
        'redoDepth': 0,
        'undoLabel': '',
        'redoLabel': '',
        'label': 'Nothing to redo',
      };

  @override
  Map<String, dynamic> componentPage({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
    required int offset,
    required int limit,
  }) {
    return {
      'rows': <List<dynamic>>[],
      'totalRows': 0,
      'offset': offset,
      'limit': limit,
      'hasMore': false,
    };
  }

  @override
  EngineInfo engineInfo() =>
      const EngineInfo(apiVersion: 10, coreVersion: '0.1.0', engine: 'morphic');

  @override
  Map<String, dynamic> profileCsv(Uint8List bytes) => {
        'rowCount': 12,
        'fieldCount': 5,
        'fields': [
          {
            'name': 'level',
            'dtype': 'utf8',
            'inference': {'role': 'severity'},
          },
        ],
      };

  @override
  Map<String, dynamic> createWorkspace({
    required Uint8List bytes,
    required String storageRoot,
    required String title,
    required String workspaceId,
    required String nowIso,
  }) =>
      _sampleDoc();

  @override
  Map<String, dynamic> loadWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) =>
      _sampleDoc();

  @override
  List<dynamic> listWorkspaces(String storageRoot) => [];

  @override
  Map<String, dynamic> renameWorkspace({
    required String storageRoot,
    required String workspaceId,
    required String title,
    required String nowIso,
  }) =>
      _sampleDoc();

  @override
  Map<String, dynamic> duplicateWorkspace({
    required String storageRoot,
    required String workspaceId,
    required String newWorkspaceId,
    required String title,
    required String nowIso,
  }) =>
      _sampleDoc();

  @override
  Map<String, dynamic> deleteWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) =>
      {'deleted': true};

  @override
  Map<String, dynamic> relinkWorkspace({
    required Uint8List bytes,
    required String storageRoot,
    required String workspaceId,
  }) =>
      {'relinked': true};

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
  }) =>
      {
        'doc': _sampleDoc(),
        'profile': profileCsv(bytes),
        'report': {'rowsImported': 12, 'warnings': <String>[]},
      };

  @override
  Map<String, dynamic> snapshot({
    required String storageRoot,
    required String workspaceId,
  }) =>
      {'doc': _sampleDoc(), 'profile': profileCsv(Uint8List(0)), 'revision': 1};

  @override
  Map<String, dynamic> queryPage({
    required String storageRoot,
    required String workspaceId,
    Map<String, dynamic>? plan,
  }) =>
      {
        'rows': [
          ['eu', 10],
          ['us', 20],
        ],
        'totalRows': 2,
        'offset': 0,
        'limit': 256,
        'hasMore': false,
      };

  @override
  Map<String, dynamic> metricData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  }) =>
      {'componentId': componentId, 'value': 12, 'revision': 1};

  @override
  Map<String, dynamic> chartData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  }) =>
      {
        'componentId': componentId,
        'revision': 1,
        'scene': {
          'kind': 'category',
          'dimension': 'region',
          'measure': 'count',
          'points': <Map<String, dynamic>>[],
          'other': null,
          'totalCategories': 0,
          'truncated': false,
        },
      };

  @override
  bool cancelImport({required String workspaceId}) => false;

  @override
  Map<String, dynamic> closeWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) =>
      {'closed': true};
}

Map<String, dynamic> _sampleDoc() => {
      'schemaVersion': '1.0',
      'workspace': {
        'id': 'w_test',
        'title': 'Sample Logs',
        'revision': 1,
        'components': [
          {
            'id': 'total_records',
            'type': 'metric_card',
            'title': 'Records',
            'explanation': {'detail': 'A record count is the fastest orientation signal.'},
          },
          {
            'id': 'data_table',
            'type': 'data_table',
            'title': 'Data',
            'explanation': {'detail': 'A searchable, sortable table keeps records reachable.'},
          },
        ],
      },
    };

void main() {
  testWidgets('home shows engine status and PoC action', (tester) async {
    await tester.pumpWidget(
      MorphicApp(bridge: FakeBridge(), storageRoot: '/tmp/morphic-test'),
    );
    // Explicit pumps (not pumpAndSettle): the loading spinner animates continuously,
    // so we advance just far enough for the fake-bridge futures to complete.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('MORPHIC'), findsOneWidget);
    expect(find.text('Run proof of concept'), findsOneWidget);
    expect(find.text('Rust engine connected'), findsOneWidget);
    expect(find.textContaining('core 0.1.0'), findsOneWidget);
  });

  testWidgets('workspace screen renders generated components', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: WorkspaceScreen(document: _sampleDoc())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sample Logs'), findsOneWidget);
    expect(find.text('Records'), findsOneWidget);
    expect(find.text('Data'), findsOneWidget);
    expect(find.text('metric_card'), findsOneWidget);
  });

  test('design tokens meet 4.5:1 contrast', () {
    double luminance(Color c) {
      double lin(double v) =>
          v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    double contrast(Color a, Color b) {
      final l1 = luminance(a);
      final l2 = luminance(b);
      final lighter = math.max(l1, l2);
      final darker = math.min(l1, l2);
      return (lighter + 0.05) / (darker + 0.05);
    }

    expect(
      contrast(MorphicColors.textPrimaryDark, MorphicColors.bgDark),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      contrast(MorphicColors.textPrimaryLight, MorphicColors.bgLight),
      greaterThanOrEqualTo(4.5),
    );
  });
}
