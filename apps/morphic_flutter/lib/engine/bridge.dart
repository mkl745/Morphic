/// The Dart side of the Dart↔Rust bridge (docs/architecture/02).
///
/// Phase 0 uses a hand-written C ABI over `dart:ffi` (ADR-0002 addendum). The abstract
/// [MorphicBridge] lets widget tests inject a fake without loading the native library.
/// M1.1 replaces [FfiBridge] internals with flutter_rust_bridge; callers do not change.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Engine identity returned by Rust.
class EngineInfo {
  const EngineInfo({
    required this.apiVersion,
    required this.coreVersion,
    required this.engine,
  });

  factory EngineInfo.fromJson(Map<String, dynamic> json) => EngineInfo(
        apiVersion: (json['apiVersion'] as num?)?.toInt() ?? 0,
        coreVersion: json['coreVersion'] as String? ?? '?',
        engine: json['engine'] as String? ?? '?',
      );

  final int apiVersion;
  final String coreVersion;
  final String engine;
}

/// The coarse-grained engine contract. Responses are decoded JSON maps/lists.
abstract interface class MorphicBridge {
  EngineInfo engineInfo();
  Map<String, dynamic> profileCsv(Uint8List bytes);
  Map<String, dynamic> createWorkspace({
    required Uint8List bytes,
    required String storageRoot,
    required String title,
    required String workspaceId,
    required String nowIso,
  });
  Map<String, dynamic> loadWorkspace({
    required String storageRoot,
    required String workspaceId,
  });
  List<dynamic> listWorkspaces(String storageRoot);

  /// Rename a persisted workspace. Returns the updated document; the engine bumps the
  /// revision and rewrites the library index and undo seed (M1.5 task 1.5.3).
  Map<String, dynamic> renameWorkspace({
    required String storageRoot,
    required String workspaceId,
    required String title,
    required String nowIso,
  });

  /// Copy a workspace document under a new id. The content-addressed dataset is shared, so
  /// this copies layout/edits, not source bytes. Returns the new document.
  Map<String, dynamic> duplicateWorkspace({
    required String storageRoot,
    required String workspaceId,
    required String newWorkspaceId,
    required String title,
    required String nowIso,
  });

  /// Delete a workspace. Shared datasets survive so other workspaces keep their data.
  Map<String, dynamic> deleteWorkspace({
    required String storageRoot,
    required String workspaceId,
  });

  /// Re-link a degraded workspace to its original source bytes. The engine verifies the
  /// content hash against the dataset id in the document and refuses a different file.
  Map<String, dynamic> relinkWorkspace({
    required Uint8List bytes,
    required String storageRoot,
    required String workspaceId,
  });

  /// Import a file and open a session. Returns `{doc, profile, report}`.
  ///
  /// The engine detects the format from the content. [formatHint] (`csv`, `json`, `jsonl`,
  /// `log`, `txt`) overrides detection — this is the re-import-with-a-hint escape hatch when
  /// a sniff was wrong. [extension] is the weakest evidence, used only when no content probe
  /// was decisive.
  ///
  /// [onProgress] receives the engine's raw progress JSON (`phase`, `rowsRead`,
  /// `bytesRead`) as the import proceeds. It is called on the same thread as the import,
  /// so an implementation must not block in it.
  Map<String, dynamic> importFile({
    required Uint8List bytes,
    required String storageRoot,
    required String title,
    required String workspaceId,
    required String nowIso,
    String? formatHint,
    String? extension,
    void Function(Map<String, dynamic> progress)? onProgress,
  });

  /// A revisioned snapshot of canonical Rust state.
  Map<String, dynamic> snapshot({
    required String storageRoot,
    required String workspaceId,
  });

  /// One bounded page of rows. A null plan means engine defaults.
  Map<String, dynamic> queryPage({
    required String storageRoot,
    required String workspaceId,
    Map<String, dynamic>? plan,
  });

  /// Apply a batch of interaction commands atomically. Returns
  /// `{revision, affected, changed, doc, typeOptions, stateHash, undoDepth, redoDepth,
  /// undoLabel, redoLabel, label}`. A rejected command changes nothing.
  Map<String, dynamic> applyCommands({
    required String storageRoot,
    required String workspaceId,
    required List<Map<String, dynamic>> commands,
    required String nowIso,
  });

  /// Engine-owned undo/redo. Rust restores canonical state from its bounded stacks; Dart
  /// only renders the document and shows [label] in a snackbar. Both return the same
  /// `ApplyResult`-shaped map as [applyCommands].
  Map<String, dynamic> undo({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  });
  Map<String, dynamic> redo({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  });

  /// One page of a component's rows with its persisted filter, sort and search applied, plus
  /// any global filters. [limit] of 0 means the page size the binding declares.
  Map<String, dynamic> componentPage({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
    required int offset,
    required int limit,
  });

  /// The computed value behind a metric_card; Rust resolves the binding.
  Map<String, dynamic> metricData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  });

  /// The pre-aggregated scene behind a chart. Rust groups and buckets; the response carries
  /// points and totals, never rows (docs/architecture/02 §2.5).
  Map<String, dynamic> chartData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  });

  /// Ask an in-flight import to stop. Returns true when a running import was signalled.
  ///
  /// False is a normal answer, not a failure: the import may have finished between the user
  /// tapping Cancel and this call landing. Safe to call from the UI isolate while the import
  /// blocks a worker isolate — the engine keeps cancellation on a separate lock precisely so
  /// this cannot deadlock.
  bool cancelImport({required String workspaceId});

  /// Drop in-memory session state. The persisted workspace is untouched.
  Map<String, dynamic> closeWorkspace({
    required String storageRoot,
    required String workspaceId,
  });
}

// Native signatures.
typedef _EngineInfoNative = Pointer<Utf8> Function();
typedef _EngineInfoDart = Pointer<Utf8> Function();

typedef _ProfileCsvNative = Pointer<Utf8> Function(Pointer<Uint8>, IntPtr);
typedef _ProfileCsvDart = Pointer<Utf8> Function(Pointer<Uint8>, int);

typedef _CreateWorkspaceNative = Pointer<Utf8> Function(
    Pointer<Uint8>, IntPtr, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _CreateWorkspaceDart = Pointer<Utf8> Function(
    Pointer<Uint8>, int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _LoadWorkspaceNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _LoadWorkspaceDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _ListWorkspacesNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ListWorkspacesDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _CancelImportNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _CancelImportDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _ImportFileNative = Pointer<Utf8> Function(
    Pointer<Uint8>,
    IntPtr,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Void>);
typedef _ImportFileDart = Pointer<Utf8> Function(
    Pointer<Uint8>,
    int,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Void>);

typedef _TwoStringNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _TwoStringDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _ThreeStringNative = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _ThreeStringDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _FourStringNative = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FourStringDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _ComponentPageNative = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, IntPtr, IntPtr);
typedef _ComponentPageDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, int);

typedef _FiveStringNative = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FiveStringDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _RelinkNative = Pointer<Utf8> Function(
    Pointer<Uint8>, IntPtr, Pointer<Utf8>, Pointer<Utf8>);
typedef _RelinkDart = Pointer<Utf8> Function(
    Pointer<Uint8>, int, Pointer<Utf8>, Pointer<Utf8>);

typedef _FreeStringNative = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);

/// `MorphicProgressFn` on the Rust side: a borrowed JSON C string, valid only for the call.
typedef _ProgressNative = Void Function(Pointer<Utf8>);

/// Real FFI implementation backed by `libmorphic_bridge`.
class FfiBridge implements MorphicBridge {
  FfiBridge() : _lib = _open();

  final DynamicLibrary _lib;

  static DynamicLibrary _open() {
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libmorphic_bridge.so');
    }
    if (Platform.isMacOS) {
      return DynamicLibrary.open('libmorphic_bridge.dylib');
    }
    if (Platform.isIOS) {
      return DynamicLibrary.process();
    }
    throw UnsupportedError('Morphic bridge: unsupported platform');
  }

  late final _engineInfo =
      _lib.lookupFunction<_EngineInfoNative, _EngineInfoDart>('morphic_engine_info');
  late final _profileCsv =
      _lib.lookupFunction<_ProfileCsvNative, _ProfileCsvDart>('morphic_profile_csv');
  late final _createWorkspace = _lib
      .lookupFunction<_CreateWorkspaceNative, _CreateWorkspaceDart>('morphic_create_workspace');
  late final _loadWorkspace = _lib
      .lookupFunction<_LoadWorkspaceNative, _LoadWorkspaceDart>('morphic_load_workspace');
  late final _listWorkspaces = _lib
      .lookupFunction<_ListWorkspacesNative, _ListWorkspacesDart>('morphic_list_workspaces');
  late final _renameWorkspace = _lib
      .lookupFunction<_FourStringNative, _FourStringDart>('morphic_rename_workspace');
  late final _duplicateWorkspace = _lib
      .lookupFunction<_FiveStringNative, _FiveStringDart>('morphic_duplicate_workspace');
  late final _deleteWorkspace = _lib
      .lookupFunction<_TwoStringNative, _TwoStringDart>('morphic_delete_workspace');
  late final _relinkWorkspace = _lib
      .lookupFunction<_RelinkNative, _RelinkDart>('morphic_relink_workspace');
  late final _cancelImport = _lib
      .lookupFunction<_CancelImportNative, _CancelImportDart>('morphic_cancel_import');
  late final _importFile =
      _lib.lookupFunction<_ImportFileNative, _ImportFileDart>('morphic_import');
  late final _snapshot =
      _lib.lookupFunction<_TwoStringNative, _TwoStringDart>('morphic_snapshot');
  late final _queryPage =
      _lib.lookupFunction<_ThreeStringNative, _ThreeStringDart>('morphic_query_page');
  late final _metricData =
      _lib.lookupFunction<_ThreeStringNative, _ThreeStringDart>('morphic_metric_data');
  late final _chartData =
      _lib.lookupFunction<_ThreeStringNative, _ThreeStringDart>('morphic_chart_data');
  late final _applyCommands = _lib
      .lookupFunction<_FourStringNative, _FourStringDart>('morphic_apply_commands');
  late final _undo = _lib
      .lookupFunction<_ThreeStringNative, _ThreeStringDart>('morphic_undo');
  late final _redo = _lib
      .lookupFunction<_ThreeStringNative, _ThreeStringDart>('morphic_redo');
  late final _componentPage = _lib
      .lookupFunction<_ComponentPageNative, _ComponentPageDart>('morphic_component_page');
  late final _closeWorkspace =
      _lib.lookupFunction<_TwoStringNative, _TwoStringDart>('morphic_close_workspace');
  late final _freeString =
      _lib.lookupFunction<_FreeStringNative, _FreeStringDart>('morphic_free_string');

  /// Copy a Dart string to native, run [body], then free the returned C string.
  T _withResponse<T>(Pointer<Utf8> Function() call, T Function(String) decode) {
    final ptr = call();
    try {
      return decode(ptr.toDartString());
    } finally {
      _freeString(ptr);
    }
  }

  Map<String, dynamic> _decodeMap(String s) {
    final decoded = jsonDecode(s);
    if (decoded is Map<String, dynamic>) {
      if (decoded.containsKey('error')) {
        throw MorphicBridgeException(decoded['error'].toString());
      }
      return decoded;
    }
    throw const MorphicBridgeException('unexpected response shape');
  }

  @override
  EngineInfo engineInfo() =>
      _withResponse(_engineInfo, (s) => EngineInfo.fromJson(_decodeMap(s)));

  @override
  Map<String, dynamic> profileCsv(Uint8List bytes) {
    final buf = calloc<Uint8>(bytes.length);
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      return _withResponse(
          () => _profileCsv(buf, bytes.length), _decodeMap);
    } finally {
      calloc.free(buf);
    }
  }

  @override
  Map<String, dynamic> createWorkspace({
    required Uint8List bytes,
    required String storageRoot,
    required String title,
    required String workspaceId,
    required String nowIso,
  }) {
    final buf = calloc<Uint8>(bytes.length);
    final root = storageRoot.toNativeUtf8();
    final t = title.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    final now = nowIso.toNativeUtf8();
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      return _withResponse(
          () => _createWorkspace(buf, bytes.length, root, t, id, now), _decodeMap);
    } finally {
      calloc.free(buf);
      calloc.free(root);
      calloc.free(t);
      calloc.free(id);
      calloc.free(now);
    }
  }

  @override
  Map<String, dynamic> loadWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    try {
      return _withResponse(() => _loadWorkspace(root, id), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
    }
  }

  @override
  List<dynamic> listWorkspaces(String storageRoot) {
    final root = storageRoot.toNativeUtf8();
    try {
      return _withResponse(() => _listWorkspaces(root), (s) {
        final decoded = jsonDecode(s);
        if (decoded is List) return decoded;
        throw const MorphicBridgeException('unexpected response shape');
      });
    } finally {
      calloc.free(root);
    }
  }

  @override
  Map<String, dynamic> renameWorkspace({
    required String storageRoot,
    required String workspaceId,
    required String title,
    required String nowIso,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    final t = title.toNativeUtf8();
    final now = nowIso.toNativeUtf8();
    try {
      return _withResponse(
          () => _renameWorkspace(root, id, t, now), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
      calloc.free(t);
      calloc.free(now);
    }
  }

  @override
  Map<String, dynamic> duplicateWorkspace({
    required String storageRoot,
    required String workspaceId,
    required String newWorkspaceId,
    required String title,
    required String nowIso,
  }) {
    final root = storageRoot.toNativeUtf8();
    final source = workspaceId.toNativeUtf8();
    final newId = newWorkspaceId.toNativeUtf8();
    final t = title.toNativeUtf8();
    final now = nowIso.toNativeUtf8();
    try {
      return _withResponse(
          () => _duplicateWorkspace(root, source, newId, t, now), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(source);
      calloc.free(newId);
      calloc.free(t);
      calloc.free(now);
    }
  }

  @override
  Map<String, dynamic> deleteWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    try {
      return _withResponse(() => _deleteWorkspace(root, id), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
    }
  }

  @override
  Map<String, dynamic> relinkWorkspace({
    required Uint8List bytes,
    required String storageRoot,
    required String workspaceId,
  }) {
    final buf = calloc<Uint8>(bytes.length);
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      return _withResponse(
          () => _relinkWorkspace(buf, bytes.length, root, id), _decodeMap);
    } finally {
      calloc.free(buf);
      calloc.free(root);
      calloc.free(id);
    }
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
  }) {
    final buf = calloc<Uint8>(bytes.length);
    final root = storageRoot.toNativeUtf8();
    final t = title.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    final now = nowIso.toNativeUtf8();
    final hint = formatHint?.toNativeUtf8();
    final ext = extension?.toNativeUtf8();
    NativeCallable<_ProgressNative>? progress;
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      if (onProgress != null) {
        // `isolateLocal` runs the callback synchronously on this isolate's own thread,
        // which is exactly where Rust invokes it. `listener` would post to this isolate's
        // event loop — and that loop is blocked inside the FFI call, so every event would
        // arrive only after the import finished. Live progress requires isolateLocal.
        progress = NativeCallable<_ProgressNative>.isolateLocal(
          (Pointer<Utf8> json) {
            try {
              final decoded = jsonDecode(json.toDartString());
              if (decoded is Map<String, dynamic>) onProgress(decoded);
            } catch (_) {
              // A progress event is diagnostic. It must never abort an import, and it
              // must never throw across the C boundary.
            }
          },
        );
      }
      return _withResponse(
          () => _importFile(
              buf,
              bytes.length,
              root,
              t,
              id,
              now,
              hint ?? nullptr,
              ext ?? nullptr,
              progress?.nativeFunction.cast<Void>() ?? nullptr),
          _decodeMap);
    } finally {
      // Close before freeing: the callable must not outlive the buffers it could touch.
      progress?.close();
      calloc.free(buf);
      calloc.free(root);
      calloc.free(t);
      calloc.free(id);
      calloc.free(now);
      if (hint != null) calloc.free(hint);
      if (ext != null) calloc.free(ext);
    }
  }

  @override
  Map<String, dynamic> snapshot({
    required String storageRoot,
    required String workspaceId,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    try {
      return _withResponse(() => _snapshot(root, id), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
    }
  }

  @override
  Map<String, dynamic> queryPage({
    required String storageRoot,
    required String workspaceId,
    Map<String, dynamic>? plan,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    final p = plan == null ? nullptr : jsonEncode(plan).toNativeUtf8();
    try {
      return _withResponse(() => _queryPage(root, id, p), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
      if (p != nullptr) calloc.free(p);
    }
  }

  @override
  Map<String, dynamic> applyCommands({
    required String storageRoot,
    required String workspaceId,
    required List<Map<String, dynamic>> commands,
    required String nowIso,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    final body = jsonEncode(commands).toNativeUtf8();
    final now = nowIso.toNativeUtf8();
    try {
      return _withResponse(
          () => _applyCommands(root, id, body, now), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
      calloc.free(body);
      calloc.free(now);
    }
  }

  @override
  Map<String, dynamic> undo({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    final now = nowIso.toNativeUtf8();
    try {
      return _withResponse(() => _undo(root, id, now), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
      calloc.free(now);
    }
  }

  @override
  Map<String, dynamic> redo({
    required String storageRoot,
    required String workspaceId,
    required String nowIso,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    final now = nowIso.toNativeUtf8();
    try {
      return _withResponse(() => _redo(root, id, now), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
      calloc.free(now);
    }
  }

  @override
  Map<String, dynamic> componentPage({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
    required int offset,
    required int limit,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    final comp = componentId.toNativeUtf8();
    try {
      return _withResponse(
          () => _componentPage(root, id, comp, offset, limit), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
      calloc.free(comp);
    }
  }

  @override
  Map<String, dynamic> metricData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    final comp = componentId.toNativeUtf8();
    try {
      return _withResponse(() => _metricData(root, id, comp), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
      calloc.free(comp);
    }
  }

  @override
  Map<String, dynamic> chartData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    final comp = componentId.toNativeUtf8();
    try {
      return _withResponse(() => _chartData(root, id, comp), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
      calloc.free(comp);
    }
  }

  @override
  bool cancelImport({required String workspaceId}) {
    final id = workspaceId.toNativeUtf8();
    try {
      return _withResponse(() => _cancelImport(id), (s) {
        final decoded = jsonDecode(s);
        if (decoded is Map<String, dynamic>) {
          return decoded['cancelled'] == true;
        }
        throw const MorphicBridgeException('unexpected response shape');
      });
    } finally {
      calloc.free(id);
    }
  }

  @override
  Map<String, dynamic> closeWorkspace({
    required String storageRoot,
    required String workspaceId,
  }) {
    final root = storageRoot.toNativeUtf8();
    final id = workspaceId.toNativeUtf8();
    try {
      return _withResponse(() => _closeWorkspace(root, id), _decodeMap);
    } finally {
      calloc.free(root);
      calloc.free(id);
    }
  }
}

class MorphicBridgeException implements Exception {
  const MorphicBridgeException(this.message);
  final String message;
  @override
  String toString() => 'MorphicBridgeException: $message';
}
