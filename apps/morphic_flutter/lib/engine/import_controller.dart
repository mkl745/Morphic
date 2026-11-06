/// Drives an import and exposes its real state to the UI (M1.1 task 1.1.4).
///
/// Stages mirror what actually happens — no invented sub-steps. The Rust engine performs
/// analyze → compile → validate → persist inside a single coarse-grained call, so that
/// whole span is reported as [ImportStage.importing] rather than being split into stages
/// the bridge cannot yet observe. Fine-grained Rust progress events exist and are
/// contract-tested on the native side; forwarding them across isolates is wired with the
/// import UI in task 1.1.7.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'bridge.dart';

enum ImportStage { idle, reading, importing, done, error }

class ImportController extends ChangeNotifier {
  ImportController({required this.bridge, required this.storageRoot});

  final MorphicBridge bridge;
  final String storageRoot;

  ImportStage _stage = ImportStage.idle;
  ImportStage get stage => _stage;

  String? _error;
  String? get error => _error;

  Map<String, dynamic>? _result;

  /// `{doc, profile, report}` from the engine, or null before a successful import.
  Map<String, dynamic>? get result => _result;

  /// Warnings the engine surfaced (encoding fallbacks, coerced cells, ambiguous dates…).
  /// These are shown to the user, never swallowed.
  List<String> get warnings {
    final report = _result?['report'];
    if (report is Map<String, dynamic>) {
      final w = report['warnings'];
      if (w is List) return w.map((e) => e.toString()).toList();
    }
    return const [];
  }

  int? get rowsImported {
    final report = _result?['report'];
    if (report is Map<String, dynamic>) {
      return (report['rowsImported'] as num?)?.toInt();
    }
    return null;
  }

  DateTime? _startedAt;
  DateTime? _finishedAt;

  /// Wall-clock duration of the last import, for the perf budget and honest reporting.
  Duration? get elapsed => (_startedAt == null || _finishedAt == null)
      ? null
      : _finishedAt!.difference(_startedAt!);

  bool get isBusy =>
      _stage == ImportStage.reading || _stage == ImportStage.importing;

  void _set(ImportStage s) {
    _stage = s;
    notifyListeners();
  }

  /// Import already-read bytes. Returns the new workspace id, or null on failure.
  Future<String?> importBytes(
    Uint8List bytes, {
    required String title,
    String? workspaceId,
    DateTime? now,
  }) async {
    if (isBusy) return null;
    _error = null;
    _result = null;
    _startedAt = DateTime.now();
    _finishedAt = null;
    final clock = now ?? DateTime.now();
    final id = workspaceId ?? 'w_${clock.millisecondsSinceEpoch}';

    return _runImport(bytes, title: title, id: id, clock: clock);
  }

  /// Shared import path. Assumes the caller has already started the clock, so reading
  /// time is included in `elapsed` when the source was a file.
  Future<String?> _runImport(
    Uint8List bytes, {
    required String title,
    required String id,
    required DateTime clock,
  }) async {
    _set(ImportStage.importing);
    try {
      // The FFI call is synchronous. Moving it to a worker isolate (with its own bridge
      // instance against the same process-global engine registry) is task 1.1.7.
      final res = bridge.importCsv(
        bytes: bytes,
        storageRoot: storageRoot,
        title: title,
        workspaceId: id,
        nowIso: clock.toUtc().toIso8601String(),
      );
      _result = res;
      _finishedAt = DateTime.now();
      _set(ImportStage.done);
      return id;
    } catch (e) {
      _error = e.toString();
      _finishedAt = DateTime.now();
      _set(ImportStage.error);
      return null;
    }
  }

  /// Read a file from disk, then import it. The reading stage is genuinely separate work.
  Future<String?> importFile(File file, {String? title, DateTime? now}) async {
    if (isBusy) return null;
    _error = null;
    _result = null;
    _startedAt = DateTime.now();
    _set(ImportStage.reading);
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      _error = 'could not read file: $e';
      _finishedAt = DateTime.now();
      _set(ImportStage.error);
      return null;
    }
    final clock = now ?? DateTime.now();
    final id = 'w_${clock.millisecondsSinceEpoch}';
    final name =
        file.uri.pathSegments.isEmpty ? 'Imported' : file.uri.pathSegments.last;
    return _runImport(bytes, title: title ?? name, id: id, clock: clock);
  }

  void reset() {
    _stage = ImportStage.idle;
    _error = null;
    _result = null;
    _startedAt = null;
    _finishedAt = null;
    notifyListeners();
  }
}
