/// Owns the view of one open workspace (M1.1 task 1.1.4).
///
/// Rust holds canonical state; this controller only *requests* and *caches* it. It never
/// computes an aggregation, a page, or a type — those come back from the engine so the UI
/// cannot drift from the data.
library;

import 'package:flutter/foundation.dart';

import 'bridge.dart';
import 'chart_scene.dart';

/// One page of rows plus the metadata a pager needs.
class PageResult {
  const PageResult({
    required this.rows,
    required this.totalRows,
    required this.offset,
    required this.limit,
    required this.hasMore,
  });

  factory PageResult.fromJson(Map<String, dynamic> json) => PageResult(
        rows: (json['rows'] as List? ?? const [])
            .map((r) => (r as List).toList())
            .toList(),
        totalRows: (json['totalRows'] as num?)?.toInt() ?? 0,
        offset: (json['offset'] as num?)?.toInt() ?? 0,
        limit: (json['limit'] as num?)?.toInt() ?? 0,
        hasMore: json['hasMore'] as bool? ?? false,
      );

  final List<List<dynamic>> rows;
  final int totalRows;
  final int offset;
  final int limit;
  final bool hasMore;

  bool get isEmpty => rows.isEmpty;
}

class EngineController extends ChangeNotifier {
  EngineController({required this.bridge, required this.storageRoot});

  final MorphicBridge bridge;
  final String storageRoot;

  String? _workspaceId;
  String? get workspaceId => _workspaceId;

  Map<String, dynamic>? _doc;
  Map<String, dynamic>? get doc => _doc;

  Map<String, dynamic>? _profile;
  Map<String, dynamic>? get profile => _profile;

  /// Conversion targets the engine can actually express for each component id. Supplied by
  /// Rust alongside the document, so the UI never offers a switch that would be refused.
  /// Empty in degraded mode and in older snapshots that predate 1.4.7.
  Map<String, List<String>> _typeOptions = const <String, List<String>>{};

  int _revision = 0;
  int get revision => _revision;

  bool _degraded = false;

  /// True when the workspace document loaded but its source data did not. The layout is
  /// still shown; data operations would fail with a typed engine error.
  bool get degraded => _degraded;

  String? _notice;

  /// The engine's explanation for [degraded], shown verbatim — never invented here.
  String? get notice => _notice;

  bool _busy = false;
  bool get busy => _busy;

  String? _error;
  String? get error => _error;

  /// The workspace-wide filters, as persisted by Rust. Every bound component's page and
  /// metric is computed against these, so the bar renders this list and nothing else.
  List<Map<String, dynamic>> get globalFilters {
    final ws = _doc?['workspace'];
    if (ws is! Map<String, dynamic>) return const [];
    return (ws['globalFilters'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// Field names in profile order. Empty in degraded mode, where the data is gone and a
  /// filter menu would have nothing honest to offer.
  List<String> get fieldNames => _profileFields
      .map((f) => f['name'] as String? ?? '')
      .where((n) => n.isNotEmpty)
      .toList();

  /// Engine-authoritative switch targets. An empty list means the menu stays hidden, which
  /// is also what an older engine (or degraded mode) should produce.
  List<String> typeOptionsFor(String componentId) =>
      _typeOptions[componentId] ?? const <String>[];

  static Map<String, List<String>> _parseTypeOptions(Object? raw) {
    if (raw is! Map) return const <String, List<String>>{};
    final out = <String, List<String>>{};
    raw.forEach((key, value) {
      out[key.toString()] = (value is List ? value : const <dynamic>[])
          .whereType<String>()
          .toList();
    });
    return out;
  }

  List<Map<String, dynamic>> get _profileFields =>
      ((_profile?['fields']) as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  /// The engine's inferred type for a field, or null when the profile is unavailable.
  String? dtypeOf(String field) {
    for (final f in _profileFields) {
      if (f['name'] == field) return f['dtype'] as String?;
    }
    return null;
  }

  /// Frequently occurring values, offered as choices by a text column's filter menu.
  List<String> topValuesOf(String field) {
    for (final f in _profileFields) {
      if (f['name'] != field) continue;
      return (f['topValues'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((v) => v['value']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return const [];
  }

  /// Components in layout order, as the runtime should render them.
  List<Map<String, dynamic>> get components {
    final ws = _doc?['workspace'];
    if (ws is! Map<String, dynamic>) return const [];
    final comps = (ws['components'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final layout = ws['layout'];
    if (layout is Map<String, dynamic>) {
      final order = (layout['order'] as List? ?? const []).cast<dynamic>();
      if (order.isNotEmpty) {
        final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
        comps.sort((a, b) =>
            (rank[a['id']] ?? 1 << 30).compareTo(rank[b['id']] ?? 1 << 30));
      }
    }
    return comps;
  }

  void _applySnapshot(Map<String, dynamic> snap) {
    _doc = snap['doc'] as Map<String, dynamic>?;
    _profile = snap['profile'] as Map<String, dynamic>?;
    _revision = (snap['revision'] as num?)?.toInt() ?? 0;
    _degraded = snap['degraded'] == true;
    _notice = snap['notice'] as String?;
    _typeOptions = _parseTypeOptions(snap['typeOptions']);
  }

  /// Adopt a snapshot the importer already produced, avoiding a redundant round trip.
  void adoptImport(Map<String, dynamic> outcome, String workspaceId) {
    _workspaceId = workspaceId;
    _error = null;
    _doc = outcome['doc'] as Map<String, dynamic>?;
    _profile = outcome['profile'] as Map<String, dynamic>?;
    _typeOptions = _parseTypeOptions(outcome['typeOptions']);
    final ws = _doc?['workspace'];
    _revision = ws is Map<String, dynamic>
        ? ((ws['revision'] as num?)?.toInt() ?? 1)
        : 1;
    notifyListeners();
  }

  /// Yield once so a failure cannot notify listeners during the build phase.
  ///
  /// A renderer calls these read paths from `initState`, and the bridge call is synchronous:
  /// an `async` function runs straight through to its first `await`. Without this yield a
  /// failing read would call `notifyListeners()` inside the widget's `initState`, marking an
  /// ancestor `AnimatedBuilder` dirty while the framework is still building, which throws
  /// "setState() or markNeedsBuild() called during build". Degraded mode hit exactly that.
  Future<void> _afterBuildPhase() => Future<void>.value();

  /// Open (or reopen) a workspace. Rust rehydrates the session from persisted source.
  Future<bool> open(String workspaceId) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final snap = bridge.snapshot(
        storageRoot: storageRoot,
        workspaceId: workspaceId,
      );
      _workspaceId = workspaceId;
      _applySnapshot(snap);
      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Fetch one page. Returns null (and sets [error]) rather than throwing into the UI.
  Future<PageResult?> page({int offset = 0, int limit = 256, String? search}) async {
    await _afterBuildPhase();
    final id = _workspaceId;
    if (id == null) {
      _error = 'no workspace open';
      notifyListeners();
      return null;
    }
    try {
      final res = bridge.queryPage(
        storageRoot: storageRoot,
        workspaceId: id,
        plan: {
          'offset': offset,
          'limit': limit,
          if (search != null && search.isNotEmpty) 'search': search,
        },
      );
      return PageResult.fromJson(res);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  /// One page of a component's rows, with its persisted filter/sort/search and any global
  /// filters applied **by Rust**. The UI never assembles that plan.
  ///
  /// Returns null (and sets [error]) on failure, matching [page]'s convention.
  Future<PageResult?> componentPage(
    String componentId, {
    int offset = 0,
    int limit = 0,
  }) async {
    await _afterBuildPhase();
    final id = _workspaceId;
    if (id == null) {
      _error = 'no workspace open';
      notifyListeners();
      return null;
    }
    try {
      final res = bridge.componentPage(
        storageRoot: storageRoot,
        workspaceId: id,
        componentId: componentId,
        offset: offset,
        limit: limit,
      );
      return PageResult.fromJson(res);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  /// The pre-aggregated scene for a chart component.
  ///
  /// Rust does the grouping, bucketing and downsampling; this returns points and totals, never
  /// rows. Returns null (and sets [error]) on failure, matching [componentPage]'s convention.
  Future<ChartResult?> chartData(String componentId) async {
    await _afterBuildPhase();
    final id = _workspaceId;
    if (id == null) {
      _error = 'no workspace open';
      notifyListeners();
      return null;
    }
    try {
      final res = bridge.chartData(
        storageRoot: storageRoot,
        workspaceId: id,
        componentId: componentId,
      );
      return ChartResult.fromJson(res);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  /// Apply interaction commands and adopt the document Rust returns.
  ///
  /// The outcome carries the whole document, so the UI re-renders from canonical state rather
  /// than guessing what changed. Returns the ids of components whose data may have changed,
  /// or null when the batch was rejected — in which case nothing was applied and the previous
  /// document is still current.
  Future<List<String>?> applyCommands(List<Map<String, dynamic>> commands) async {
    final id = _workspaceId;
    if (id == null) {
      _error = 'no workspace open';
      notifyListeners();
      return null;
    }
    if (commands.isEmpty) return const [];
    try {
      final res = bridge.applyCommands(
        storageRoot: storageRoot,
        workspaceId: id,
        commands: commands,
        nowIso: DateTime.now().toUtc().toIso8601String(),
      );
      final doc = res['doc'];
      if (doc is Map<String, dynamic>) _doc = doc;
      // A real engine recomputes the matrix for the *converted* type; a scripted bridge may
      // omit it, in which case the previous options remain the least wrong answer.
      final opts = res['typeOptions'];
      if (opts is Map) _typeOptions = _parseTypeOptions(opts);
      _revision = (res['revision'] as num?)?.toInt() ?? _revision;
      _error = null;
      notifyListeners();
      return (res['affected'] as List? ?? const []).whereType<String>().toList();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  /// The value behind a metric card.
  ///
  /// A returned `null` means **no data** — a real answer, distinct from zero. A *failure*
  /// therefore cannot also be signalled by null, so it is recorded and **rethrown**: the
  /// caller must be able to tell "the engine could not compute this" from "there is nothing
  /// to compute". Compare [page], where an empty page is a value and null means failure.
  Future<Object?> metric(String componentId) async {
    await _afterBuildPhase();
    final id = _workspaceId;
    if (id == null) {
      throw StateError('no workspace open');
    }
    try {
      final res = bridge.metricData(
        storageRoot: storageRoot,
        workspaceId: id,
        componentId: componentId,
      );
      return res['value'];
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// Release the engine's in-memory session. The saved workspace is untouched.
  Future<void> closeWorkspace() async {
    final id = _workspaceId;
    if (id == null) return;
    try {
      bridge.closeWorkspace(storageRoot: storageRoot, workspaceId: id);
    } catch (e) {
      _error = e.toString();
    }
    _workspaceId = null;
    _doc = null;
    _profile = null;
    _typeOptions = const <String, List<String>>{};
    _revision = 0;
    _degraded = false;
    _notice = null;
    notifyListeners();
  }

  List<dynamic> library() {
    try {
      return bridge.listWorkspaces(storageRoot);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return const [];
    }
  }
}
