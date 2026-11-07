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
    Map<String, String>? dtypes,
    Map<String, List<String>>? topValues,
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
                'interactions': {
                  'search': true,
                  'sort': true,
                  'filter': true,
                  'drillDown': true,
                },
                'explanation': {'detail': 'Keeps every record reachable.'},
              },
            ],
        order = order ?? ['total_records', 'data_table'],
        dtypes = dtypes ?? const {},
        topValues = topValues ?? const {};

  final Map<String, Object?> metrics;
  final List<List<dynamic>> rows;
  final List<String> fields;
  final Map<String, String> dtypes;
  final Map<String, List<String>> topValues;
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

  /// Every command batch, so a test can prove the widget sends state instead of computing.
  final List<List<Map<String, dynamic>>> commandBatches = [];

  /// Every component page request, with the state it was resolved against.
  final List<Map<String, dynamic>> pageCalls = [];

  /// Set to reject the next command batch, the way the engine rejects an invalid one.
  bool failCommands = false;
  String commandError = "filter references unknown field 'nope'";

  int _revision = 1;

  Map<String, dynamic>? _component(String id) {
    for (final c in components) {
      if (c['id'] == id) return c;
    }
    return null;
  }

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
          'revision': _revision,
          'layout': {'mode': 'adaptive', 'order': order},
          'components': components,
        },
      };

  Map<String, dynamic> profileJson() => {
        'rowCount': rows.length,
        'fieldCount': fields.length,
        'fields': [
          for (final f in fields)
            {
              'name': f,
              'dtype': dtypes[f] ?? 'utf8',
              if (topValues[f] != null)
                'topValues': [
                  for (final v in topValues[f]!) {'value': v, 'count': 1},
                ],
            },
        ],
      };

  @override
  EngineInfo engineInfo() =>
      const EngineInfo(apiVersion: 5, coreVersion: '0.1.0', engine: 'morphic');

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
  Map<String, dynamic> applyCommands({
    required String storageRoot,
    required String workspaceId,
    required List<Map<String, dynamic>> commands,
    required String nowIso,
  }) {
    commandBatches.add(commands);
    if (failCommands) throw MorphicBridgeException(commandError);
    var changed = false;
    final affected = <String>[];
    for (final cmd in commands) {
      switch (cmd['kind'] as String) {
        case 'setComponentSort':
          final c = _component(cmd['componentId'] as String);
          if (c == null) throw const MorphicBridgeException('unknown component');
          final state = _stateOf(c);
          final sort = cmd['sort'] as List?;
          if (sort == null || sort.isEmpty) {
            state.remove('sort');
          } else {
            state['sort'] = sort;
          }
          affected.add(c['id'] as String);
          changed = true;
        case 'setComponentFilter':
          final c = _component(cmd['componentId'] as String);
          if (c == null) throw const MorphicBridgeException('unknown component');
          final state = _stateOf(c);
          if (cmd['filter'] == null) {
            state.remove('filter');
          } else {
            state['filter'] = cmd['filter'];
          }
          affected.add(c['id'] as String);
          changed = true;
        case 'setSearch':
          final c = _component(cmd['componentId'] as String);
          if (c == null) throw const MorphicBridgeException('unknown component');
          final state = _stateOf(c);
          final text = (cmd['text'] as String?)?.trim();
          if (text == null || text.isEmpty) {
            state.remove('search');
          } else {
            state['search'] = text;
          }
          affected.add(c['id'] as String);
          changed = true;
        case 'setGlobalFilter':
          affected.addAll(order);
          changed = true;
        default:
          throw MorphicBridgeException('unknown command ${cmd['kind']}');
      }
    }
    if (changed) _revision++;
    return {
      'revision': _revision,
      'affected': affected,
      'changed': changed,
      'doc': doc(),
    };
  }

  Map<String, dynamic> _stateOf(Map<String, dynamic> component) {
    final existing = (component['state'] as Map?)?.cast<String, dynamic>();
    final state = existing ?? <String, dynamic>{};
    component['state'] = state;
    return state;
  }

  @override
  Map<String, dynamic> componentPage({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
    required int offset,
    required int limit,
  }) {
    if (failQuery) throw const MorphicBridgeException('query: unknown field');
    if (sourceUnavailable) {
      throw const MorphicBridgeException(
          "core: source data for workspace 'w1' is unavailable");
    }
    final c = _component(componentId);
    final state = (c?['state'] as Map?)?.cast<String, dynamic>() ?? const {};
    final search = state['search'] as String?;
    final filter = (state['filter'] as Map?)?.cast<String, dynamic>();
    final sort = (state['sort'] as List?) ?? const [];
    pageCalls.add({
      'componentId': componentId,
      'offset': offset,
      'limit': limit,
      'search': search,
      'filter': filter,
      'sort': sort,
    });
    final matched = _matching(search).where((r) => _passes(r, filter)).toList();
    if (sort.isNotEmpty) {
      final rule = (sort.first as Map).cast<String, dynamic>();
      final idx = fields.indexOf(rule['field'] as String);
      final desc = rule['dir'] == 'desc';
      final nullsFirst = rule['nulls'] == 'first';
      if (idx >= 0) {
        matched.sort((a, b) {
          final x = a[idx], y = b[idx];
          if (x == null || y == null) {
            if (x == null && y == null) return 0;
            final nullFirst = x == null ? nullsFirst : !nullsFirst;
            return nullFirst ? -1 : 1;
          }
          final cmp = (x is num && y is num)
              ? x.compareTo(y)
              : x.toString().compareTo(y.toString());
          return desc ? -cmp : cmp;
        });
      }
    }
    final start = offset.clamp(0, matched.length);
    final end = (offset + limit).clamp(0, matched.length);
    return {
      'rows': matched.sublist(start, end),
      'totalRows': matched.length,
      'offset': offset,
      'limit': limit,
      'hasMore': end < matched.length,
    };
  }

  /// A deliberately small stand-in for the engine's predicate evaluator. The authoritative
  /// semantics live in `morphic-query` and are pinned by its property tests; this exists so a
  /// widget test can observe a page change without a native library.
  bool _passes(List<dynamic> row, Map<String, dynamic>? filter) {
    if (filter == null) return true;
    final op = filter['op'] as String?;
    if (op == 'and') {
      return (filter['args'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .every((f) => _passes(row, f));
    }
    final idx = fields.indexOf(filter['field'] as String? ?? '');
    if (idx < 0 || idx >= row.length) return true;
    final cell = row[idx];
    final bound = filter['value'];
    switch (op) {
      case 'is_null':
        return cell == null;
      case 'not_null':
        return cell != null;
      case 'contains':
        return cell != null &&
            cell.toString().toLowerCase().contains('$bound'.toLowerCase());
      case 'in':
        // The engine reads `in`'s candidates from `value` as an array, not from `args`.
        return (bound as List? ?? const []).contains(cell);
    }
    if (cell == null || bound == null) return false;
    final cmp = (cell is num && bound is num)
        ? cell.compareTo(bound)
        : cell.toString().compareTo(bound.toString());
    switch (op) {
      case 'eq':
        return cmp == 0;
      case 'neq':
        return cmp != 0;
      case 'gt':
        return cmp > 0;
      case 'gte':
        return cmp >= 0;
      case 'lt':
        return cmp < 0;
      case 'lte':
        return cmp <= 0;
    }
    return true;
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

  /// What [cancelImport] reports, and every id it was asked to cancel.
  bool cancelResult = false;
  final List<String> cancelCalls = [];

  @override
  bool cancelImport({required String workspaceId}) {
    cancelCalls.add(workspaceId);
    return cancelResult;
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

  @override
  Future<PageResult?> componentPage(String componentId,
          {int offset = 0, int limit = 0}) =>
      pageGate.future;
}
