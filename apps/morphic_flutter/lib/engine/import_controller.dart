/// Drives an import and exposes its real state to the UI (M1.1 tasks 1.1.4 and 1.1.7).
///
/// Stages mirror what actually happens — no invented sub-steps. [ImportStage.reading] is
/// only entered when bytes genuinely have to be read from disk; a picker that already
/// returned bytes goes straight to importing.
///
/// The import itself runs through an [ImportRunner]. The app passes [IsolateImportRunner]
/// so the synchronous FFI call cannot freeze the frame loop, and the engine's progress
/// events are forwarded live. The default is [InlineImportRunner] so unit tests (and any
/// host without the native library) exercise the same controller logic.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'bridge.dart';
import 'file_source.dart';
import 'import_progress.dart';
import 'import_runner.dart';

enum ImportStage { idle, reading, importing, done, error }

class ImportController extends ChangeNotifier {
  ImportController({
    required this.bridge,
    required this.storageRoot,
    ImportRunner? runner,
  }) : runner = runner ?? InlineImportRunner(bridge);

  final MorphicBridge bridge;
  final String storageRoot;
  final ImportRunner runner;

  ImportStage _stage = ImportStage.idle;
  ImportStage get stage => _stage;

  String? _error;
  String? get error => _error;

  Map<String, dynamic>? _result;

  /// `{doc, profile, report}` from the engine, or null before a successful import.
  Map<String, dynamic>? get result => _result;

  ImportProgress? _progress;

  /// The latest real observation from the engine, or null before the first event.
  ImportProgress? get progress => _progress;

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

  void _begin() {
    _error = null;
    _result = null;
    _progress = null;
    _startedAt = DateTime.now();
    _finishedAt = null;
  }

  /// Import already-read bytes. Returns the new workspace id, or null on failure.
  Future<String?> importBytes(
    Uint8List bytes, {
    required String title,
    String? workspaceId,
    DateTime? now,
  }) async {
    if (isBusy) return null;
    _begin();
    final clock = now ?? DateTime.now();
    final id = workspaceId ?? 'w_${clock.millisecondsSinceEpoch}';
    return _runImport(bytes, title: title, id: id, clock: clock);
  }

  /// Import a file the user picked. Handles both picker outcomes: bytes already in hand,
  /// or a path that still has to be read.
  Future<String?> importPicked(
    PickedFile file, {
    String? title,
    DateTime? now,
  }) async {
    if (isBusy) return null;
    _begin();
    final clock = now ?? DateTime.now();
    final id = 'w_${clock.millisecondsSinceEpoch}';
    final name = title ?? file.suggestedTitle;

    var bytes = file.bytes;
    if (bytes == null) {
      final path = file.path;
      if (path == null) {
        _error = 'the picker returned a file with no readable data or path';
        _finishedAt = DateTime.now();
        _set(ImportStage.error);
        return null;
      }
      _set(ImportStage.reading);
      try {
        bytes = await File(path).readAsBytes();
      } catch (e) {
        _error = 'could not read file: $e';
        _finishedAt = DateTime.now();
        _set(ImportStage.error);
        return null;
      }
    }
    return _runImport(bytes, title: name, id: id, clock: clock);
  }

  /// Read a file from disk, then import it. The reading stage is genuinely separate work.
  Future<String?> importFile(File file, {String? title, DateTime? now}) async {
    if (isBusy) return null;
    _begin();
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

  /// Shared import path. Assumes the clock already started, so reading time is included
  /// in `elapsed` when the source was a file.
  Future<String?> _runImport(
    Uint8List bytes, {
    required String title,
    required String id,
    required DateTime clock,
  }) async {
    _set(ImportStage.importing);
    try {
      final res = await runner.run(
        ImportRequest(
          bytes: bytes,
          storageRoot: storageRoot,
          title: title,
          workspaceId: id,
          nowIso: clock.toUtc().toIso8601String(),
        ),
        (p) {
          _progress = p;
          notifyListeners();
        },
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

  void reset() {
    _stage = ImportStage.idle;
    _error = null;
    _result = null;
    _progress = null;
    _startedAt = null;
    _finishedAt = null;
    notifyListeners();
  }
}
