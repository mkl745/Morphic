/// A scriptable bridge for runtime widget tests — no native library required.
///
/// Records the plans it receives so tests can prove the widgets ask the engine for data
/// instead of computing it themselves.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:morphic_flutter/engine/bridge.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';

class ScriptedBridge implements MorphicBridge {
  ScriptedBridge({
    Map<String, Object?>? metrics,
    List<List<dynamic>>? rows,
    List<String>? fields,
    List<Map<String, dynamic>>? components,
    List<String>? order,
    this.degraded = false,
    this.notice,
    this.sourceUnavailable = false,
  })  : metrics = metrics ?? {'total_records': 1234},
        rows = rows ??
            [
              ['eu', 10, null],
              ['us', 20, 'note'],
            ],
        fields = fields ?? ['region', 'amount', 'note'],
        components = components ??
            [
              {
                'id': 'total_records',
                'type': 'metric_card',
                'title': 'Records',
                'binding': {
                  'kind': 'metric_card',
                  'aggregation': {'op': 'count', 'field': null},
                },
                'explanation': {'detail': 'A record count orientates fastest.'},
              },
              {
                'id': 'data_table',
                'type': 'data_table',
                'title': 'Data',
                'binding': {
                  'kind': 'data_table',
                  'columns': <String>[],
                  'page_size': 2,
                },
                'interactions': {'search': true},
                'explanation': {'detail': 'Keeps every record reachable.'},
              },
            ],
        order = order ?? ['total_records', 'data_table'];

  final Map<String, Object?> metrics;
  final List<List<dynamic>> rows;
  final List<String> fields;
  final List<Map<String, dynamic>> components;
  final List<String> order;

  /// Behaviour switches.
  bool failMetric = false;
  bool failQuery = false;
  bool failSnapshot = false;

  /// Mirrors the engine's degraded snapshot (task 1.1.6): the document loads, the data
  /// does not. Data calls then fail with the typed engine error.
  bool degraded;
  String? notice;
  bool sourceUnavailable;
  List<String> importWarnings = [];

  /// Every plan the table sent, in order.
  final List<Map<String, dynamic>> plans = [];
  final List<String> metricCalls = [];

  /// Rows matching the current search, so paging maths is exercised realistically.
  List<List<dynamic>> _matching(String? search) {
    if (search == null || search.isEmpty) return rows;
    final needle = search.toLowerCase();
    return rows
        .where((r) => r.any((c) => c?.toString().toLowerCase().contains(needle) ?? false))
        .toList();
  }

  Map<String, dynamic> doc() => {
        'schemaVersion': '1.0',
        'workspace': {
          'id': 'w1',
          'title': 'Scripted',
          'revision': 1,
          'layout': {'mode': 'adaptive', 'order': order},
          'components': components,
        },
      };

  Map<String, dynamic> profileJson() => {
        'rowCount': rows.length,
        'fieldCount': fields.length,
        'fields': [
          for (final f in fields) {'name': f, 'dtype': 'utf8'},
        ],
      };

  @override
  EngineInfo engineInfo() =>
      const EngineInfo(apiVersion: 2, coreVersion: '0.1.0', engine: 'morphic');

  @override
  Map<String, dynamic> profileCsv(Uint8List bytes) => profileJson();

  @override
  Map<String, dynamic> createWorkspace({
    required Uint8List bytes,
    required String storageRoot,
    required String title,
    required String workspaceId,
    required String nowIso,
  }) =>
      doc();

  @override
  Map<String, dynamic> loadWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) =>
      doc();

  @override
  List<dynamic> listWorkspaces(String storageRoot) => [
        {'id': 'w1', 'title': 'Saved workspace'},
      ];

  @override
  Map<String, dynamic> importCsv({
    required Uint8List bytes,
    required String storageRoot,
    required String title,
    required String workspaceId,
    required String nowIso,
    void Function(Map<String, dynamic> progress)? onProgress,
  }) =>
      {
        'doc': doc(),
        'profile': profileJson(),
        'report': {'rowsImported': rows.length, 'warnings': importWarnings},
      };

  @override
  Map<String, dynamic> snapshot({
    required String storageRoot,
    required String workspaceId,
  }) {
    if (failSnapshot) throw const MorphicBridgeException('store: not found');
    return {
      'doc': doc(),
      'profile': degraded ? null : profileJson(),
      'revision': 1,
      'degraded': degraded,
      'notice': notice,
    };
  }

  @override
  Map<String, dynamic> queryPage({
    required String storageRoot,
    required String workspaceId,
    Map<String, dynamic>? plan,
  }) {
    final p = plan ?? const {};
    plans.add(Map<String, dynamic>.from(p));
    if (failQuery) throw const MorphicBridgeException('query: unknown field');
    if (sourceUnavailable) {
      throw const MorphicBridgeException("core: source data for workspace 'w1' is unavailable");
    }
    final matched = _matching(p['search'] as String?);
    final offset = (p['offset'] as num?)?.toInt() ?? 0;
    final limit = (p['limit'] as num?)?.toInt() ?? 256;
    final slice = offset >= matched.length
        ? <List<dynamic>>[]
        : matched.sublist(offset, (offset + limit).clamp(0, matched.length));
    return {
      'rows': slice,
      'totalRows': matched.length,
      'offset': offset,
      'limit': limit,
      'hasMore': offset + slice.length < matched.length,
    };
  }

  @override
  Map<String, dynamic> metricData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  }) {
    metricCalls.add(componentId);
    if (failMetric) throw const MorphicBridgeException('core: not a metric');
    if (sourceUnavailable) {
      throw const MorphicBridgeException("core: source data for workspace 'w1' is unavailable");
    }
    return {'componentId': componentId, 'value': metrics[componentId], 'revision': 1};
  }

  @override
  Map<String, dynamic> closeWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) =>
      {'closed': true};
}

/// Lets a test hold a request open, so the **loading** state is observed deterministically
/// instead of racing a microtask. Overrides only the async seams; no production hook needed.
class GatedEngineController extends EngineController {
  GatedEngineController({required super.bridge, required super.storageRoot});

  final Completer<Object?> metricGate = Completer<Object?>();
  final Completer<PageResult?> pageGate = Completer<PageResult?>();

  @override
  Future<Object?> metric(String componentId) => metricGate.future;

  @override
  Future<PageResult?> page({int offset = 0, int limit = 256, String? search}) =>
      pageGate.future;
}
