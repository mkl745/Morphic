/// A scriptable bridge for runtime widget tests — no native library required.
///
/// Records the plans it receives so tests can prove the widgets ask the engine for data
/// instead of computing it themselves.
library;

import 'dart:async';
import 'dart:convert';
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
    List<Map<String, dynamic>>? hints,
    Map<String, String>? dtypes,
    Map<String, List<String>>? topValues,
    Map<String, List<String>>? typeOptions,
    this.degraded = false,
    this.notice,
    bool? sourceUnavailable,
  })  : sourceUnavailable = sourceUnavailable ?? degraded,
        metrics = metrics ?? {'total_records': 1234},
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
        hints = hints ?? <Map<String, dynamic>>[],
        dtypes = dtypes ?? const {},
        topValues = topValues ?? const {},
        typeOptions = typeOptions ?? const <String, List<String>>{};

  final Map<String, Object?> metrics;
  final List<List<dynamic>> rows;
  final List<String> fields;
  final Map<String, String> dtypes;
  final Map<String, List<String>> topValues;

  /// Conversion targets the fake engine says are valid. Empty by default so the many existing
  /// widget/golden tests keep rendering exactly the headers they did before 1.4.7.
  final Map<String, List<String>> typeOptions;
  final List<Map<String, dynamic>> components;
  final List<String> order;

  /// Persisted `layout.hints`, mirroring the Rust command handler for widget tests.
  final List<Map<String, dynamic>> hints;

  /// A small stand-in for the engine's library index (M1.5 task 1.5.3). Widget tests
  /// mutate it through the same four bridge calls the home screen uses.
  final List<Map<String, dynamic>> workspaceIndex = [
    {'id': 'w1', 'title': 'Saved workspace'},
  ];
  final List<String> libraryCalls = [];
  Uint8List? lastRelinkBytes;
  bool rejectRelink = false;

  /// Stand-in for the engine's persisted `workspace.fieldOverrides` (M1.5 task 1.5.5).
  final List<Map<String, dynamic>> fieldOverrides = [];

  /// Startup recovery report, injected by recovery-UI tests (M1.5 task 1.5.4).
  RecoveryReport recovery = const RecoveryReport();

  /// Every explicit autosave checkpoint the UI asked for.
  final List<String> saveCalls = [];

  /// Bundle export/import calls (M1.5 task 1.5.6).
  final List<String> bundleCalls = [];
  Map<String, dynamic> bundleExportResult = {
    'bundleJson': '{"format":"morphic/workspace-bundle/1"}',
    'bytes': 43,
    'manifest': {
      'format': 'morphic/workspace-bundle/1',
      'schemaVersion': '1.0',
      'workspaceId': 'w1',
      'title': 'Saved workspace',
      'exportedAt': '2026-11-05T00:00:00Z',
      'datasetCount': 1,
    },
  };
  Object? bundleImportFailure;

  /// Behaviour switches.
  bool failMetric = false;
  bool failQuery = false;
  bool failSnapshot = false;

  /// Mirrors the engine's degraded snapshot (task 1.1.6): the document loads, the data
  /// does not. By default a degraded fixture also fails data calls, as the real engine does.
  /// Tests may explicitly override [sourceUnavailable] to simulate an inconsistent response.
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
  /// Set to make `undo()` fail, so the app bar's error snackbar is testable.
  bool failUndo = false;

  /// When true, `metricData` computes from the rows through the active filters instead of
  /// returning the canned [metrics] value. Off by default so the many tests that assert a
  /// scripted number keep their meaning; on for the filter tests, which need the number to
  /// actually move when the selection changes.
  bool computeMetrics = false;

  List<Map<String, dynamic>> _globalFilters = [];
  String commandError = "filter references unknown field 'nope'";

  int _revision = 1;
  String _title = 'Scripted';

  /// A deliberately small stand-in for the engine's bounded stacks. The authoritative
  /// implementation lives in Rust; widget tests only need the response shape and label.
  final List<_Frame> _undoStack = [];
  final List<_Frame> _redoStack = [];

  Map<String, dynamic> _clone(Map<String, dynamic> m) =>
      (jsonDecode(jsonEncode(m)) as Map).cast<String, dynamic>();

  Map<String, dynamic> _semanticDoc() {
    final d = doc();
    final ws = Map<String, dynamic>.from(d['workspace'] as Map);
    ws.remove('revision');
    ws.remove('modifiedAt');
    return <String, dynamic>{...d, 'workspace': ws};
  }

  /// FNV-1a over the canonical JSON, so two states with the same semantic content hash
  /// alike regardless of the volatile revision (AT-13).
  String _stateHash() {
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8.encode(jsonEncode(_semanticDoc()))) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  void _restore(Map<String, dynamic> snapshot) {
    final ws = snapshot['workspace'] as Map<String, dynamic>;
    _title = ws['title'] as String? ?? 'Scripted';
    for (final entry in workspaceIndex) {
      if (entry['id'] == 'w1') entry['title'] = _title;
    }
    final comps = (ws['components'] as List? ?? const [])
        .map((e) => _clone((e as Map).cast<String, dynamic>()))
        .toList();
    components
      ..clear()
      ..addAll(comps);
    final layout = ws['layout'] as Map<String, dynamic>?;
    final ord = (layout?['order'] as List? ?? const []).whereType<String>().toList();
    order
      ..clear()
      ..addAll(ord);
    final nextHints = (layout?['hints'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => _clone(e.cast<String, dynamic>()))
        .toList();
    hints
      ..clear()
      ..addAll(nextHints);
    _globalFilters = (ws['globalFilters'] as List? ?? const [])
        .map((e) => _clone((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Map<String, dynamic> _historyResponse({
    required bool changed,
    required String label,
  }) =>
      {
        'revision': _revision,
        'affected': changed ? order.toList() : <String>[],
        'changed': changed,
        'doc': doc(),
        'typeOptions': typeOptions,
        'stateHash': _stateHash(),
        'undoDepth': _undoStack.length,
        'redoDepth': _redoStack.length,
        'undoLabel': _undoStack.isEmpty ? '' : _undoStack.last.label,
        'redoLabel': _redoStack.isEmpty ? '' : _redoStack.last.label,
        'label': label,
      };

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
          'title': _title,
          'revision': _revision,
          'layout': {
            'mode': 'adaptive',
            'order': order,
            if (hints.isNotEmpty) 'hints': hints,
          },
          'globalFilters': _globalFilters,
          if (fieldOverrides.isNotEmpty) 'fieldOverrides': fieldOverrides,
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
              'inference': {
                'role': (dtypes[f] == 'int64' || dtypes[f] == 'float64')
                    ? 'measure'
                    : 'dimension',
                'confidence': 0.9,
              },
              if (topValues[f] != null)
                'topValues': [
                  for (final v in topValues[f]!) {'value': v, 'count': 1},
                ],
            },
        ],
      };

  @override
  EngineInfo engineInfo() =>
      const EngineInfo(apiVersion: 14, coreVersion: '0.1.0', engine: 'morphic');

  @override
  RecoveryReport recoveryReport(String storageRoot) => recovery;

  @override
  Map<String, dynamic> saveWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) {
    saveCalls.add(workspaceId);
    return {
      'revision': _revision,
      'stateHash': _stateHash(),
      'dirty': false,
      'compacted': true,
    };
  }

  @override
  Map<String, dynamic> exportBundle({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  }) {
    bundleCalls.add('export:$workspaceId');
    return bundleExportResult;
  }

  @override
  Map<String, dynamic> importBundle({
    required Uint8List bytes,
    required String storageRoot,
    required String workspaceId,
    required String title,
    required String nowIso,
  }) {
    bundleCalls.add('import:$workspaceId:$title');
    if (bundleImportFailure != null) throw bundleImportFailure!;
    workspaceIndex.add({'id': workspaceId, 'title': title});
    return {
      'doc': doc(),
      'sourceTitle': title,
      'datasetCount': 1,
    };
  }

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
  List<dynamic> listWorkspaces(String storageRoot) =>
      workspaceIndex.map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Map<String, dynamic> renameWorkspace({
    required String storageRoot,
    required String workspaceId,
    required String title,
    required String nowIso,
  }) {
    libraryCalls.add('rename:$workspaceId:$title');
    if (title.trim().isEmpty) {
      throw const MorphicBridgeException('generated workspace failed validation: '
          'workspace title is empty');
    }
    for (final e in workspaceIndex) {
      if (e['id'] == workspaceId) e['title'] = title.trim();
    }
    return doc();
  }

  @override
  Map<String, dynamic> duplicateWorkspace({
    required String storageRoot,
    required String workspaceId,
    required String newWorkspaceId,
    required String title,
    required String nowIso,
  }) {
    libraryCalls.add('duplicate:$workspaceId:$newWorkspaceId:$title');
    if (workspaceIndex.any((e) => e['id'] == newWorkspaceId)) {
      throw const MorphicBridgeException("workspace 'w2' already exists");
    }
    workspaceIndex.add({'id': newWorkspaceId, 'title': title});
    return doc();
  }

  @override
  Map<String, dynamic> deleteWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) {
    libraryCalls.add('delete:$workspaceId');
    workspaceIndex.removeWhere((e) => e['id'] == workspaceId);
    return {'deleted': true};
  }

  @override
  Map<String, dynamic> relinkWorkspace({
    required Uint8List bytes,
    required String storageRoot,
    required String workspaceId,
  }) {
    libraryCalls.add('relink:$workspaceId');
    lastRelinkBytes = bytes;
    if (rejectRelink || bytes.isEmpty) {
      throw const MorphicBridgeException(
          'generated workspace failed validation: source does not match workspace');
    }
    degraded = false;
    sourceUnavailable = false;
    notice = null;
    return {'relinked': true};
  }

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
        'typeOptions': typeOptions,
        'stateHash': _stateHash(),
        'undoDepth': 0,
        'redoDepth': 0,
        'undoLabel': '',
        'redoLabel': '',
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
      'typeOptions': typeOptions,
      'stateHash': _stateHash(),
      'undoDepth': _undoStack.length,
      'redoDepth': _redoStack.length,
      'undoLabel': _undoStack.isEmpty ? '' : _undoStack.last.label,
      'redoLabel': _redoStack.isEmpty ? '' : _redoStack.last.label,
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
    final before = _clone(doc());
    var changed = false;
    final affected = <String>[];
    for (final cmd in commands) {
      switch (cmd['kind'] as String) {
        case 'renameWorkspace':
          final title = (cmd['title'] as String? ?? '').trim();
          if (title.isEmpty) {
            throw const MorphicBridgeException('workspace title is empty');
          }
          if (title != _title) {
            _title = title;
            for (final entry in workspaceIndex) {
              if (entry['id'] == workspaceId) entry['title'] = title;
            }
            changed = true;
          }
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
          final next = (cmd['filters'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          if (jsonEncode(next) != jsonEncode(_globalFilters)) {
            _globalFilters = next;
            affected.addAll(order);
            changed = true;
          }
        case 'changeComponentType':
          final c = _component(cmd['componentId'] as String);
          if (c == null) throw const MorphicBridgeException('unknown component');
          final target = cmd['targetType'] as String? ?? '';
          if (target.isEmpty) {
            throw const MorphicBridgeException('empty targetType');
          }
          // The fake deliberately does not invent a converted binding: that is the engine's
          // job. Tests assert the command that was sent, not a second compiler's output.
          affected.add(c['id'] as String);
          changed = true;
        case 'moveComponent':
          final id = cmd['componentId'] as String? ?? '';
          if (!order.contains(id)) {
            throw const MorphicBridgeException('unknown component');
          }
          final to = (cmd['toIndex'] as num?)?.toInt() ?? 0;
          final from = order.indexOf(id);
          final clamped = to.clamp(0, order.length - 1).toInt();
          if (from != clamped) {
            order.removeAt(from);
            order.insert(clamped, id);
            affected.addAll(order);
            changed = true;
          }
        case 'resizeComponent':
          final id = cmd['componentId'] as String? ?? '';
          if (!order.contains(id)) {
            throw const MorphicBridgeException('unknown component');
          }
          final span = (cmd['span'] as num?)?.toInt();
          final height = cmd['height'] as String?;
          if (span == null && height == null) {
            throw const MorphicBridgeException('empty resize');
          }
          Map<String, dynamic>? hint;
          for (final h in hints) {
            if (h['componentId'] == id) hint = h;
          }
          if (hint == null) {
            hint = <String, dynamic>{'componentId': id, 'span': 1, 'height': ''};
            hints.add(hint);
          }
          if (span != null) hint['span'] = span;
          if (height != null) hint['height'] = height;
          affected.addAll(order);
          changed = true;
        case 'overrideFieldRole':
        case 'overrideFieldType':
          final field = cmd['field'] as String? ?? '';
          final raw = cmd['role'] ?? cmd['dtype'];
          final value = raw is String ? raw : '';
          if (field.isEmpty || value.isEmpty) {
            throw const MorphicBridgeException('empty override');
          }
          Map<String, dynamic>? existing;
          for (final o in fieldOverrides) {
            if (o['field'] == field) existing = o;
          }
          final key = cmd['role'] != null ? 'role' : 'dtype';
          if (existing == null) {
            fieldOverrides.add({'field': field, key: value});
          } else {
            existing[key] = value;
          }
          affected.addAll(order);
          changed = true;
        case 'clearFieldOverride':
          final field = cmd['field'] as String? ?? '';
          final countBefore = fieldOverrides.length;
          fieldOverrides.removeWhere((o) => o['field'] == field);
          if (fieldOverrides.length != countBefore) {
            changed = true;
            affected.addAll(order);
          }
        default:
          throw MorphicBridgeException('unknown command ${cmd['kind']}');
      }
    }
    if (changed) {
      _revision++;
      _undoStack.add(_Frame(before, 'Applied changes'));
      _redoStack.clear();
    }
    return _historyResponse(
      changed: changed,
      label: changed ? 'Applied changes' : '',
    )..['affected'] = affected;
  }

  @override
  Map<String, dynamic> undo({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  }) {
    if (failUndo) {
      throw const MorphicBridgeException('undo: no history available');
    }
    if (_undoStack.isEmpty) {
      return _historyResponse(changed: false, label: 'Nothing to undo');
    }
    final current = _clone(doc());
    final frame = _undoStack.removeLast();
    _redoStack.add(_Frame(current, 'Redid ${frame.label}'));
    _restore(frame.doc);
    _revision++;
    return _historyResponse(changed: true, label: 'Undid ${frame.label}');
  }

  @override
  Map<String, dynamic> redo({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  }) {
    if (_redoStack.isEmpty) {
      return _historyResponse(changed: false, label: 'Nothing to redo');
    }
    final current = _clone(doc());
    final frame = _redoStack.removeLast();
    _undoStack.add(_Frame(current, frame.label));
    _restore(frame.doc);
    _revision++;
    return _historyResponse(changed: true, label: frame.label);
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
    final matched = _matching(search)
        .where((r) => _globalFilters.every((g) => _passes(r, g)))
        .where((r) => _passes(r, filter))
        .toList();
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
    if (op == 'not') {
      final args = (filter['args'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      return args.length == 1 && !_passes(row, args.single);
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
    final value = computeMetrics ? _computeMetric(componentId) : metrics[componentId];
    return {'componentId': componentId, 'value': value, 'revision': _revision};
  }

  /// Chart scenes requested, in order. The evidence that a painter asked the engine instead
  /// of aggregating the rows it was handed.
  final List<String> chartCalls = [];

  /// Set to make `chartData` throw, for the degraded/error paths.
  bool failChart = false;

  /// Forces the category scene's accumulation-cap flag. The fake groups rows in memory and
  /// will never breach the engine's 100k cap, so a painter's partial-scene path needs a switch.
  /// This is NOT the same as a `limit` cutting categories — that is the Other bucket.
  bool chartTruncated = false;

  @override
  Map<String, dynamic> chartData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  }) {
    chartCalls.add(componentId);
    if (failChart) throw const MorphicBridgeException('core: not a chart');
    if (sourceUnavailable) {
      throw const MorphicBridgeException("core: source data for workspace 'w1' is unavailable");
    }
    final c = _component(componentId);
    if (c == null) throw const MorphicBridgeException('core: unknown component');
    final type = c['type'] as String?;
    if (type != 'bar_chart' && type != 'line_chart' && type != 'timeline') {
      throw MorphicBridgeException("core: component '$componentId' is a $type, not a chart");
    }
    final Map<String, dynamic> scene;
    switch (type) {
      case 'line_chart':
        scene = _seriesScene(c);
        break;
      case 'timeline':
        scene = _timelineScene(c);
        break;
      default:
        scene = _categoryScene(c);
    }
    return {
      'componentId': componentId,
      'revision': _revision,
      'scene': scene,
    };
  }

  /// Forces the timeline's lane-truncation flag, the way [chartExtraSeries] does for lines.
  int chartExtraLanes = 0;

  /// Knobs for the line scene's partial paths. The fake buckets in memory and will never
  /// overflow the engine's point or series ceilings on a test fixture.
  bool chartDownsampled = false;
  int chartExtraSeries = 0;

  /// Bucket step for the fake's line scenes. Not a binding field — the real engine derives the
  /// step from the data, and a test needs to choose one deterministically.
  int chartBucketMs = 60000;

  /// A bucketed series scene, grouped and filtered the same way the category scene is.
  ///
  /// The engine owns bucketing and downsampling; this exists so a painter test can watch a
  /// filter move the line and a legend toggle hide a series. Buckets are a fixed step on the
  /// x column, which is all a painter needs to be exercised against.
  Map<String, dynamic> _seriesScene(Map<String, dynamic> c) {
    final binding = (c['binding'] as Map?)?.cast<String, dynamic>() ?? {};
    final x = binding['x'] as String? ?? '';
    final ys = (binding['y'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final measure = ys.isEmpty ? <String, dynamic>{} : ys.first;
    // Bindings are snake_case on the wire (serde renames the variant, not its fields).
    final groupBy = binding['group_by'] as String?;
    final step = chartBucketMs;
    final op = measure['op'] as String? ?? 'count';
    final field = measure['field'] as String?;
    final stateFilter = ((c['state'] as Map?)?['filter'] as Map?)?.cast<String, dynamic>();
    final bindingFilter = (measure['filter'] as Map?)?.cast<String, dynamic>();
    final selected = rows
        .where((r) => _globalFilters.every((g) => _passes(r, g)))
        .where((r) => _passes(r, stateFilter))
        .where((r) => _passes(r, bindingFilter))
        .toList();

    final xIdx = fields.indexOf(x);
    final gIdx = groupBy == null ? -1 : fields.indexOf(groupBy);
    final vIdx = fields.indexOf(field ?? '');
    // group -> bucket -> members
    final groups = <String?, Map<int, List<List<dynamic>>>>{};
    for (final r in selected) {
      final cell = xIdx >= 0 && xIdx < r.length ? r[xIdx] : null;
      if (cell is! num) continue; // an unbucketable x belongs to the timeline, not here
      final bucket = (cell.toInt() ~/ step) * step;
      final g = gIdx >= 0 && gIdx < r.length ? r[gIdx]?.toString() : null;
      groups.putIfAbsent(g, () => {}).putIfAbsent(bucket, () => []).add(r);
    }
    final buckets = <int>{
      for (final byBucket in groups.values) ...byBucket.keys,
    }.toList()
      ..sort();

    double? aggOf(List<List<dynamic>> members) {
      if (op == 'count' && field == null) return members.length.toDouble();
      if (vIdx < 0) return null;
      final nums = members
          .map((r) => vIdx < r.length ? r[vIdx] : null)
          .whereType<num>()
          .toList();
      if (nums.isEmpty) return null;
      switch (op) {
        case 'count':
          return nums.length.toDouble();
        case 'sum':
          return nums.fold<num>(0, (a, b) => a + b).toDouble();
        case 'avg':
          return nums.fold<num>(0, (a, b) => a + b) / nums.length;
        case 'min':
          return nums.reduce((a, b) => a < b ? a : b).toDouble();
        case 'max':
          return nums.reduce((a, b) => a > b ? a : b).toDouble();
      }
      return null;
    }

    // Series order: most rows first, so a legend is stable — the engine's rule.
    final names = groups.keys.toList()
      ..sort((a, b) {
        int count(String? k) => groups[k]!.values.fold(0, (n, m) => n + m.length);
        final cmp = count(b).compareTo(count(a));
        return cmp != 0 ? cmp : (a ?? '').compareTo(b ?? '');
      });
    final kept = names.take(8).toList();
    final measureName = field == null ? op : '${op}_$field';
    return {
      'kind': 'series',
      'xField': x,
      'temporal': dtypes[x] == 'timestamp',
      'bucketing': {
        'bucketMs': step,
        'label': step >= 60000 ? '${step ~/ 60000}m' : '${step}ms',
        'downsampled': chartDownsampled,
      },
      'series': [
        for (final name in kept)
          {
            'name': name ?? (groups.length == 1 ? measureName : null),
            // Every series carries every bucket, with a null y where it has no rows: a gap,
            // not a zero. That is what lets a painter test prove gaps are drawn as gaps.
            'points': [
              for (final b in buckets)
                {'x': b, 'y': aggOf(groups[name]![b] ?? const [])},
            ],
          },
      ],
      'totalSeries': names.length + chartExtraSeries,
      'truncatedSeries': names.length > 8 || chartExtraSeries > 0,
      'totalPoints': buckets.length * kept.length,
    };
  }

  /// A category scene computed from the rows through the active filters.
  ///
  /// Only bar charts, and only the operators the compiler emits. The Rust FFI tests are the
  /// authority on aggregation; this exists so a painter test can see a filter actually move the
  /// bars, which a canned scene would hide.
  /// Density buckets with severity lanes, filtered the same way the other scenes are.
  ///
  /// Mirrors `morphic_query::timeline_scene`: lanes come from `severity_field` or, failing that,
  /// `group_by` (morphic-core falls back exactly this way); lanes are ordered by frequency then
  /// key; only non-empty buckets are emitted; and rows with no usable time are counted rather
  /// than dropped. The step is [chartBucketMs] so a test can choose it deterministically.
  Map<String, dynamic> _timelineScene(Map<String, dynamic> c) {
    final binding = (c['binding'] as Map?)?.cast<String, dynamic>() ?? {};
    // Bindings are snake_case on the wire: serde renames the variant, not its fields.
    final timeField = binding['time_field'] as String? ?? '';
    final laneField = (binding['severity_field'] as String?) ??
        (binding['group_by'] as String?);
    final step = chartBucketMs;
    final stateFilter =
        ((c['state'] as Map?)?['filter'] as Map?)?.cast<String, dynamic>();
    final selected = rows
        .where((r) => _globalFilters.every((g) => _passes(r, g)))
        .where((r) => _passes(r, stateFilter))
        .toList();

    final tIdx = fields.indexOf(timeField);
    final lIdx = laneField == null ? -1 : fields.indexOf(laneField);
    final dated = <(int, List<dynamic>)>[];
    for (final r in selected) {
      final cell = tIdx >= 0 && tIdx < r.length ? r[tIdx] : null;
      if (cell is! num) continue;
      dated.add(((cell.toInt() ~/ step) * step, r));
    }
    final unbucketed = selected.length - dated.length;

    // Lane identity is the cell text (null groups as the empty key), its label is null or text.
    final counts = <String, int>{};
    final labels = <String, String?>{};
    for (final (_, r) in dated) {
      if (lIdx < 0) continue;
      final cell = lIdx < r.length ? r[lIdx] : null;
      final key = cell?.toString() ?? '';
      counts[key] = (counts[key] ?? 0) + 1;
      labels.putIfAbsent(key, () => cell?.toString());
    }
    final order = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    final totalLanes = order.length;
    final kept = order.take(8).toList();
    final lanes = [for (final k in kept) labels[k]];
    final lanePos = <String, int>{
      for (var i = 0; i < kept.length; i++) kept[i]: i,
    };

    final perBucket = <int, List<int>>{};
    final totals = <int, int>{};
    for (final (at, r) in dated) {
      final slots = perBucket.putIfAbsent(at, () => List<int>.filled(kept.length, 0));
      totals[at] = (totals[at] ?? 0) + 1;
      if (lIdx < 0) continue;
      final cell = lIdx < r.length ? r[lIdx] : null;
      final pos = lanePos[cell?.toString() ?? ''];
      if (pos != null) slots[pos] += 1;
    }
    final starts = perBucket.keys.toList()..sort();
    return {
      'kind': 'timeline',
      'timeField': timeField,
      'bucketing': {'bucketMs': step, 'label': '1m', 'downsampled': false},
      'lanes': lanes,
      'buckets': [
        for (final at in starts)
          {
            'startMs': at,
            'count': totals[at],
            'lanes': [
              for (var i = 0; i < kept.length; i++)
                if (perBucket[at]![i] > 0)
                  {'lane': lanes[i], 'count': perBucket[at]![i]},
            ],
          },
      ],
      'totalBuckets': starts.length,
      'totalLanes': totalLanes + chartExtraLanes,
      'truncatedLanes': totalLanes > 8 || chartExtraLanes > 0,
      'unbucketedRows': unbucketed,
    };
  }

  Map<String, dynamic> _categoryScene(Map<String, dynamic> c) {
    final binding = (c['binding'] as Map?)?.cast<String, dynamic>() ?? {};
    final dimension = binding['dimension'] as String? ?? '';
    final measure = (binding['measure'] as Map?)?.cast<String, dynamic>() ?? {};
    final limit = (binding['limit'] as num?)?.toInt() ?? 12;
    final op = measure['op'] as String? ?? 'count';
    final field = measure['field'] as String?;
    final bindingFilter = (measure['filter'] as Map?)?.cast<String, dynamic>();
    final stateFilter = ((c['state'] as Map?)?['filter'] as Map?)?.cast<String, dynamic>();
    final selected = rows
        .where((r) => _globalFilters.every((g) => _passes(r, g)))
        .where((r) => _passes(r, stateFilter))
        .where((r) => _passes(r, bindingFilter))
        .toList();

    final dimIdx = fields.indexOf(dimension);
    final groups = <String, List<List<dynamic>>>{};
    final labels = <String, String?>{};
    for (final r in selected) {
      final cell = dimIdx >= 0 && dimIdx < r.length ? r[dimIdx] : null;
      final key = cell?.toString() ?? '\u0000null';
      labels[key] = cell?.toString();
      groups.putIfAbsent(key, () => []).add(r);
    }

    double? aggOf(List<List<dynamic>> members) {
      if (op == 'count' && field == null) return members.length.toDouble();
      final idx = fields.indexOf(field ?? '');
      if (idx < 0) return null;
      final nums = members
          .map((r) => idx < r.length ? r[idx] : null)
          .whereType<num>()
          .toList();
      if (nums.isEmpty) return null;
      switch (op) {
        case 'count':
          return nums.length.toDouble();
        case 'sum':
          return nums.fold<num>(0, (a, b) => a + b).toDouble();
        case 'avg':
          return nums.fold<num>(0, (a, b) => a + b) / nums.length;
        case 'min':
          return nums.reduce((a, b) => a < b ? a : b).toDouble();
        case 'max':
          return nums.reduce((a, b) => a > b ? a : b).toDouble();
      }
      return null;
    }

    final entries = groups.entries.toList();
    // Nulls last regardless of the measure, then descending by value, then by label: the same
    // order the engine promises, so a painter test is not asserting a different contract.
    entries.sort((a, b) {
      final an = labels[a.key] == null;
      final bn = labels[b.key] == null;
      if (an != bn) return an ? 1 : -1;
      final av = aggOf(a.value);
      final bv = aggOf(b.value);
      if (av != null && bv != null && av != bv) return bv.compareTo(av);
      if (av == null && bv != null) return 1;
      if (av != null && bv == null) return -1;
      return (labels[a.key] ?? '').compareTo(labels[b.key] ?? '');
    });

    // Selection is always top-N by measure; a label sort reorders only the survivors. Cutting
    // after a label sort would drop the largest bar, which is why the engine works this way.
    final kept = entries.take(limit).toList();
    final rest = entries.skip(limit).expand((e) => e.value).toList();
    final sort = ((c['state'] as Map?)?['sort'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    if (sort.isNotEmpty && sort.first['field'] == dimension) {
      final asc = sort.first['dir'] != 'desc';
      kept.sort((a, b) {
        final an = labels[a.key] == null;
        final bn = labels[b.key] == null;
        if (an != bn) return an ? 1 : -1; // nulls last under every order
        final cmp = (labels[a.key] ?? '').compareTo(labels[b.key] ?? '');
        return asc ? cmp : -cmp;
      });
    }
    return {
      'kind': 'category',
      'dimension': dimension,
      'measure': field == null ? op : '${op}_$field',
      'points': [
        for (final e in kept)
          {'label': labels[e.key], 'value': aggOf(e.value), 'rowCount': e.value.length},
      ],
      'other': rest.isEmpty
          ? null
          : {'label': 'Other', 'value': aggOf(rest), 'rowCount': rest.length},
      'totalCategories': entries.length,
      'truncated': chartTruncated,
    };
  }

  /// Global ∧ component-state ∧ binding, then the aggregation. The binding filter goes last
  /// for the same reason the engine puts it last: a user filter may narrow what a card means,
  /// never widen it.
  Object? _computeMetric(String componentId) {
    final c = _component(componentId);
    final binding = (c?['binding'] as Map?)?.cast<String, dynamic>();
    final agg = (binding?['aggregation'] as Map?)?.cast<String, dynamic>();
    final op = agg?['op'] as String? ?? 'count';
    final field = agg?['field'] as String?;
    final bindingFilter = (agg?['filter'] as Map?)?.cast<String, dynamic>();
    final stateFilter =
        ((c?['state'] as Map?)?['filter'] as Map?)?.cast<String, dynamic>();
    final selected = rows
        .where((r) => _globalFilters.every((g) => _passes(r, g)))
        .where((r) => _passes(r, stateFilter))
        .where((r) => _passes(r, bindingFilter))
        .toList();
    if (op == 'count' && field == null) return selected.length;
    final idx = fields.indexOf(field ?? '');
    if (idx < 0) return null;
    final cells = selected
        .map((r) => idx < r.length ? r[idx] : null)
        .where((v) => v != null)
        .toList();
    if (op == 'count') return cells.length;
    if (op == 'distinct_count') return cells.map((v) => v.toString()).toSet().length;
    final nums = cells.whereType<num>().toList();
    if (nums.isEmpty) return null;
    switch (op) {
      case 'sum':
        return nums.fold<num>(0, (a, b) => a + b);
      case 'avg':
        return nums.fold<num>(0, (a, b) => a + b) / nums.length;
      case 'min':
        return nums.reduce((a, b) => a < b ? a : b);
      case 'max':
        return nums.reduce((a, b) => a > b ? a : b);
    }
    return null;
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

class _Frame {
  const _Frame(this.doc, this.label);
  final Map<String, dynamic> doc;
  final String label;
}
