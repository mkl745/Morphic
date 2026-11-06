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

  /// Import a file and open a session. Returns `{doc, profile, report}`.
  Map<String, dynamic> importCsv({
    required Uint8List bytes,
    required String storageRoot,
    required String title,
    required String workspaceId,
    required String nowIso,
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

  /// The computed value behind a metric_card; Rust resolves the binding.
  Map<String, dynamic> metricData({
    required String storageRoot,
    required String workspaceId,
    required String componentId,
  });

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

typedef _ImportCsvNative = Pointer<Utf8> Function(Pointer<Uint8>, IntPtr,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>);
typedef _ImportCsvDart = Pointer<Utf8> Function(
    Pointer<Uint8>, int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>);

typedef _TwoStringNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _TwoStringDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _ThreeStringNative = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _ThreeStringDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _FreeStringNative = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);

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
  late final _importCsv =
      _lib.lookupFunction<_ImportCsvNative, _ImportCsvDart>('morphic_import_csv');
  late final _snapshot =
      _lib.lookupFunction<_TwoStringNative, _TwoStringDart>('morphic_snapshot');
  late final _queryPage =
      _lib.lookupFunction<_ThreeStringNative, _ThreeStringDart>('morphic_query_page');
  late final _metricData =
      _lib.lookupFunction<_ThreeStringNative, _ThreeStringDart>('morphic_metric_data');
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
  Map<String, dynamic> importCsv({
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
      // The native progress slot is left null: cross-isolate callback delivery is wired
      // with the import UI in task 1.1.7. The capability is contract-tested on the Rust side.
      return _withResponse(
          () => _importCsv(buf, bytes.length, root, t, id, now, nullptr), _decodeMap);
    } finally {
      calloc.free(buf);
      calloc.free(root);
      calloc.free(t);
      calloc.free(id);
      calloc.free(now);
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
