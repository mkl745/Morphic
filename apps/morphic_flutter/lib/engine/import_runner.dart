/// Where the import actually runs (M1.1 task 1.1.7).
///
/// The FFI import is a **synchronous** C call. Running it on the UI isolate freezes the
/// frame loop for the whole parse — on a low-end phone importing a 10 MB file that is a
/// visible, multi-second freeze. [IsolateImportRunner] moves the call to a worker isolate
/// and streams the engine's real progress back over a port.
///
/// The seam exists for two reasons: the app can choose a runner, and tests can drive the
/// controller with a fake — `flutter test` on the host has no `libmorphic_bridge.so`, so a
/// test that spawned a real worker could not run in CI at all.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'bridge.dart';
import 'import_progress.dart';

/// Everything one import needs. Immutable and sendable across isolates.
class ImportRequest {
  const ImportRequest({
    required this.bytes,
    required this.storageRoot,
    required this.title,
    required this.workspaceId,
    required this.nowIso,
    this.formatHint,
    this.extension,
  });

  final Uint8List bytes;
  final String storageRoot;
  final String title;
  final String workspaceId;
  final String nowIso;

  /// Forces the engine's parser, bypassing detection. Null means auto-detect.
  final String? formatHint;

  /// The source extension; the engine's weakest evidence, used only as a tie-break.
  final String? extension;
}

/// Runs one import, reporting the engine's progress as it happens.
abstract interface class ImportRunner {
  Future<Map<String, dynamic>> run(
    ImportRequest request,
    void Function(ImportProgress) onProgress,
  );
}

/// Calls the bridge on the current isolate.
///
/// Correct but blocking; used by unit tests and by any host without a worker-capable
/// embedding. The app itself uses [IsolateImportRunner].
class InlineImportRunner implements ImportRunner {
  const InlineImportRunner(this.bridge);

  final MorphicBridge bridge;

  @override
  Future<Map<String, dynamic>> run(
    ImportRequest request,
    void Function(ImportProgress) onProgress,
  ) async =>
      bridge.importFile(
        bytes: request.bytes,
        storageRoot: request.storageRoot,
        title: request.title,
        workspaceId: request.workspaceId,
        nowIso: request.nowIso,
        formatHint: request.formatHint,
        extension: request.extension,
        onProgress: (json) => onProgress(ImportProgress.fromJson(json)),
      );
}

/// Runs the import on a dedicated worker isolate, so the UI keeps rendering.
///
/// The engine registry is process-global and guarded by a mutex on the Rust side, so the
/// worker's own bridge handle addresses the same sessions the UI isolate later queries.
/// The worker opens its own `DynamicLibrary` handle; handles are per-isolate.
class IsolateImportRunner implements ImportRunner {
  const IsolateImportRunner();

  @override
  Future<Map<String, dynamic>> run(
    ImportRequest request,
    void Function(ImportProgress) onProgress,
  ) async {
    // One port for results, progress, uncaught errors AND the exit notification. Using
    // separate ports would leave a race: cross-port delivery order is unspecified, so an
    // exit notification could overtake the result it followed and fail a successful import.
    // On a single port the queue is FIFO, so `null` (exit) always arrives last.
    final receive = ReceivePort();
    final completer = Completer<Map<String, dynamic>>();

    void fail(Object error) {
      if (!completer.isCompleted) completer.completeError(error);
    }

    receive.listen((message) {
      // onExit delivers null. If a result already arrived the completer is done and this
      // is a no-op; otherwise the worker died without answering.
      if (message == null) {
        fail(const MorphicBridgeException(
            'import worker exited before returning a result'));
        return;
      }
      // onError delivers [errorString, stackTraceString].
      if (message is List) {
        final detail = message.isNotEmpty ? message.first.toString() : 'unknown';
        fail(MorphicBridgeException('import worker failed: $detail'));
        return;
      }
      if (message is! Map) {
        fail(const MorphicBridgeException('malformed message from import worker'));
        return;
      }
      if (message.containsKey('progress')) {
        final p = message['progress'];
        if (p is Map) {
          onProgress(ImportProgress.fromJson(Map<String, dynamic>.from(p)));
        }
        return;
      }
      if (message.containsKey('result')) {
        final r = message['result'];
        if (r is Map && !completer.isCompleted) {
          completer.complete(Map<String, dynamic>.from(r));
        }
        return;
      }
      if (message.containsKey('error')) {
        fail(MorphicBridgeException(message['error'].toString()));
      }
    });

    Isolate? worker;
    try {
      worker = await Isolate.spawn(
        _importWorkerMain,
        _WorkerInit(receive.sendPort, request),
        onError: receive.sendPort,
        onExit: receive.sendPort,
        errorsAreFatal: true,
        debugName: 'morphic-import',
      );
      return await completer.future;
    } finally {
      worker?.kill(priority: Isolate.immediate);
      receive.close();
    }
  }
}

class _WorkerInit {
  const _WorkerInit(this.reply, this.request);

  final SendPort reply;
  final ImportRequest request;
}

/// Worker entry point. Must be top-level so it can be sent to `Isolate.spawn`.
///
/// Progress is forwarded with `SendPort.send` from inside a `NativeCallable.isolateLocal`
/// callback, which Rust invokes synchronously on this isolate's own thread. That is what
/// makes the events genuinely live: a `NativeCallable.listener` would queue them to this
/// isolate's event loop, which is blocked inside the FFI call until the import finishes.
void _importWorkerMain(_WorkerInit init) {
  try {
    final bridge = FfiBridge();
    final result = bridge.importFile(
      bytes: init.request.bytes,
      storageRoot: init.request.storageRoot,
      title: init.request.title,
      workspaceId: init.request.workspaceId,
      nowIso: init.request.nowIso,
      formatHint: init.request.formatHint,
      extension: init.request.extension,
      onProgress: (json) => init.reply.send({'progress': json}),
    );
    init.reply.send({'result': result});
  } catch (e) {
    // Send the failure as data so the parent gets the engine's own message rather than a
    // generic isolate error.
    init.reply.send({'error': e.toString()});
  }
}
