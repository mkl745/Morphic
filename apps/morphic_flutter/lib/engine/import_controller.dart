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
import 'clipboard_source.dart';
import 'file_source.dart';
import 'import_failure.dart';
import 'import_facts.dart';
import 'import_progress.dart';
import 'import_runner.dart';

enum ImportStage { idle, reading, importing, done, error, cancelled }

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

  /// The engine's own error text, kept verbatim. The UI shows [failure] instead; this is the
  /// evidence a bug report needs.
  String? get error => _error;

  /// The last failure in human terms, or null when the last attempt did not fail.
  /// Cancellation is deliberately not a failure and yields null here.
  ImportFailure? get failure =>
      _error == null ? null : describeImportFailure(_error!);

  /// What the engine reported about the last successful import.
  ImportFacts? get facts =>
      _result == null ? null : ImportFacts.fromResult(_result);

  /// The workspace id of the attempt currently running, so Cancel can name it.
  String? _activeId;

  /// Ask the running import to stop. Returns true when the engine signalled one.
  ///
  /// Safe to call while the import blocks a worker isolate. A false return is normal: the
  /// import may have finished first, in which case its result stands.
  bool cancel() {
    final id = _activeId;
    if (!isBusy || id == null) return false;
    try {
      return bridge.cancelImport(workspaceId: id);
    } catch (_) {
      // Cancellation is best-effort. Failing to signal it must not crash the UI or mask
      // the import's own outcome.
      return false;
    }
  }

  // The last source, retained so the user can re-import it with a different format hint
  // without going back to the picker.
  Uint8List? _lastBytes;
  String? _lastTitle;
  String? _lastExtension;
  String? _lastFormatHint;

  /// True when the result deserves a look before the user trusts it: rows were quarantined,
  /// or the engine was not confident about the format. A clean, confident import goes
  /// straight to the workspace — the spec asks for no ceremony when nothing is wrong.
  bool get needsReview {
    final f = facts;
    return f != null && (f.hasQuarantine || f.isLowConfidence);
  }

  /// True when there is a remembered source to re-import.
  bool get canReimport => _lastBytes != null;

  /// The format hint used for the last attempt, null when the engine detected it.
  String? get lastFormatHint => _lastFormatHint;

  /// Re-read the same bytes with a different format. Creates a **new** workspace: the
  /// earlier attempt is left untouched rather than silently overwritten.
  Future<String?> reimport({String? formatHint, DateTime? now}) async {
    final bytes = _lastBytes;
    final title = _lastTitle;
    if (bytes == null || title == null || isBusy) return null;
    _begin();
    final clock = now ?? DateTime.now();
    return _runImport(
      bytes,
      title: title,
      id: 'w_${clock.millisecondsSinceEpoch}',
      clock: clock,
      formatHint: formatHint,
      extension: _lastExtension,
    );
  }

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

  /// True while the user can still stop the import. Reading is local and fast; the engine
  /// call is the long part, and only it can be cancelled.
  bool get canCancel => _stage == ImportStage.importing && _activeId != null;

  void _set(ImportStage s) {
    _stage = s;
    notifyListeners();
  }

  void _begin() {
    _activeId = null;
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
    String? formatHint,
  }) async {
    if (isBusy) return null;
    _begin();
    final clock = now ?? DateTime.now();
    final id = workspaceId ?? 'w_${clock.millisecondsSinceEpoch}';
    return _runImport(bytes, title: title, id: id, clock: clock, formatHint: formatHint);
  }

  /// Import a file the user picked. Handles both picker outcomes: bytes already in hand,
  /// or a path that still has to be read.
  Future<String?> importPicked(
    PickedFile file, {
    String? title,
    DateTime? now,
    String? formatHint,
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
    _lastBytes = bytes;
    _lastTitle = name;
    _lastExtension = file.extension;
    return _runImport(
      bytes,
      title: name,
      id: id,
      clock: clock,
      formatHint: formatHint,
      extension: file.extension,
    );
  }

  /// Import text the user pasted. The bytes are already encoded and size-checked by the
  /// clipboard source, so there is no reading stage to report — inventing one would be a
  /// fake progress step.
  ///
  /// No extension is offered: a clipboard has no file name, so the contents must decide the
  /// format. That is the detector's job and it does it better than a guess from context.
  Future<String?> importClipboard(
    ClipboardContent content, {
    String? title,
    DateTime? now,
    String? formatHint,
  }) async {
    if (isBusy) return null;
    _begin();
    final clock = now ?? DateTime.now();
    final id = 'w_${clock.millisecondsSinceEpoch}';
    final name = title ?? 'Clipboard text';
    _lastBytes = content.bytes;
    _lastTitle = name;
    _lastExtension = null;
    return _runImport(
      content.bytes,
      title: name,
      id: id,
      clock: clock,
      formatHint: formatHint,
    );
  }

  /// Read a file from disk, then import it. The reading stage is genuinely separate work.
  Future<String?> importFile(
    File file, {
    String? title,
    DateTime? now,
    String? formatHint,
  }) async {
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
    return _runImport(
      bytes,
      title: title ?? name,
      id: id,
      clock: clock,
      formatHint: formatHint,
      extension: extensionOf(name),
    );
  }

  /// Shared import path. Assumes the clock already started, so reading time is included
  /// in `elapsed` when the source was a file.
  Future<String?> _runImport(
    Uint8List bytes, {
    required String title,
    required String id,
    required DateTime clock,
    String? formatHint,
    String? extension,
  }) async {
    _activeId = id;
    _lastFormatHint = formatHint;
    _set(ImportStage.importing);
    try {
      final res = await runner.run(
        ImportRequest(
          bytes: bytes,
          storageRoot: storageRoot,
          title: title,
          workspaceId: id,
          nowIso: clock.toUtc().toIso8601String(),
          formatHint: formatHint,
          extension: extension,
        ),
        (p) {
          _progress = p;
          notifyListeners();
        },
      );
      _result = res;
      _activeId = null;
      _finishedAt = DateTime.now();
      _set(ImportStage.done);
      return id;
    } catch (e) {
      final raw = e.toString();
      _activeId = null;
      _finishedAt = DateTime.now();
      // A cancelled import is a decision the user made, not an error to apologise for.
      if (describeImportFailure(raw).isCancellation) {
        _error = null;
        _set(ImportStage.cancelled);
        return null;
      }
      _error = raw;
      _set(ImportStage.error);
      return null;
    }
  }

  void reset() {
    _stage = ImportStage.idle;
    _error = null;
    _result = null;
    _progress = null;
    _activeId = null;
    _startedAt = null;
    _finishedAt = null;
    // The remembered source goes too: reset means "start over", and offering to re-import
    // a file the user has moved on from would be confusing.
    _lastBytes = null;
    _lastTitle = null;
    _lastExtension = null;
    _lastFormatHint = null;
    notifyListeners();
  }
}
