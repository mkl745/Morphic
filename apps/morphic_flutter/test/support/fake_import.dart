/// Test doubles for the import path (task 1.1.7).
///
/// `flutter test` on the CI host has no `libmorphic_bridge.so` and no SAF plugin, so the
/// runner and the picker are both injected. These fakes let the tests assert the real
/// controller/screen behaviour — ordering, stages, error handling, navigation — without
/// pretending to exercise native code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:morphic_flutter/engine/bundle_location.dart';
import 'package:morphic_flutter/engine/clipboard_source.dart';
import 'package:morphic_flutter/engine/file_source.dart';
import 'package:morphic_flutter/engine/import_progress.dart';
import 'package:morphic_flutter/engine/import_runner.dart';

import 'scripted_bridge.dart';

/// An [ImportRunner] that emits scripted progress and can be held open mid-import.
class FakeImportRunner implements ImportRunner {
  FakeImportRunner({
    this.events = const [],
    this.failure,
    this.gate,
    Map<String, dynamic>? result,
    List<String> warnings = const [],
    int rowsImported = 600,
  }) : result = result ??
            {
              'doc': ScriptedBridge().doc(),
              'profile': ScriptedBridge().profileJson(),
              'report': {'rowsImported': rowsImported, 'warnings': warnings},
            };

  final List<ImportProgress> events;
  final Map<String, dynamic> result;

  /// Thrown instead of returning, to exercise the failure path.
  final Object? failure;

  /// While incomplete, the import stays running so intermediate UI can be asserted.
  final Completer<void>? gate;

  int runs = 0;
  ImportRequest? lastRequest;
  final List<ImportProgress> delivered = [];

  @override
  Future<Map<String, dynamic>> run(
    ImportRequest request,
    void Function(ImportProgress) onProgress,
  ) async {
    runs++;
    lastRequest = request;
    for (final e in events) {
      delivered.add(e);
      onProgress(e);
    }
    if (gate != null) await gate!.future;
    if (failure != null) throw failure!;
    return result;
  }
}

/// A clipboard that returns a scripted answer, or throws like a platform refusal.
class FakeClipboardSource implements PlatformClipboardSource {
  FakeClipboardSource({this.content, this.failure});

  final ClipboardContent? content;
  final Object? failure;

  int calls = 0;

  @override
  Future<ClipboardContent?> readText() async {
    calls++;
    if (failure != null) throw failure!;
    return content;
  }
}

/// Text content built the way the real source builds it: UTF-8 encoded once.
ClipboardContent clipboardText(String text) =>
    ClipboardContent(text: text, bytes: Uint8List.fromList(utf8.encode(text)));

/// A picker that returns a scripted answer, or throws like the real one does.
class FakeFileSource implements PlatformFileSource {
  FakeFileSource({this.file, this.bundleFile, this.failure});

  final PickedFile? file;
  final PickedFile? bundleFile;
  final Object? failure;

  int calls = 0;
  int bundleCalls = 0;

  @override
  Future<PickedFile?> pick() async {
    calls++;
    if (failure != null) throw failure!;
    return file;
  }

  @override
  Future<PickedFile?> pickBundle() async {
    bundleCalls++;
    if (failure != null) throw failure!;
    return bundleFile;
  }
}

/// A fixed export destination so bundle widget tests never call `path_provider`.
class FakeBundlePathResolver implements BundlePathResolver {
  const FakeBundlePathResolver(this.path);

  final String path;

  @override
  Future<String> exportPath(String workspaceId) async => path;
}

const List<ImportProgress> kProgressEvents = [
  ImportProgress(phase: 'sniffing', rowsRead: 0, bytesRead: 0),
  ImportProgress(phase: 'parsing', rowsRead: 4096, bytesRead: 204800),
  ImportProgress(phase: 'typing', rowsRead: 6000, bytesRead: 307200),
  ImportProgress(phase: 'done', rowsRead: 6000, bytesRead: 307200),
];
