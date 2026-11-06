/// The file-picking seam (M1.1 task 1.1.7).
///
/// `file_picker` is the one community plugin in the import path, so it sits behind
/// [PlatformFileSource] — the exit path named in dependency-strategy §2. Swapping it for
/// `file_selector` or a hand-written platform channel touches this file only, and the
/// import screen and controller are testable without any plugin at all.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// The lowercase extension of [name] without the dot, or null when there is not one.
///
/// Only the final suffix counts, so `report.final.csv` gives `csv`. A dotfile (`.csv`) has
/// no extension — it is a name, not a suffix.
String? extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// A file the user chose. Either [bytes] or a readable [path] must be present; which one
/// depends on the platform, so the controller handles both rather than assuming.
class PickedFile {
  const PickedFile({
    required this.name,
    this.bytes,
    this.path,
    this.sizeBytes,
  });

  final String name;
  final Uint8List? bytes;
  final String? path;
  final int? sizeBytes;

  /// The extension the engine may use as a last-resort format tie-break.
  String? get extension => extensionOf(name);

  /// A workspace title derived from the file name. Only a *known* supported extension is
  /// stripped, so `report.final.csv` becomes `report.final`, not `report`.
  String get suggestedTitle {
    final lower = name.toLowerCase();
    for (final ext in const [
      '.csv',
      '.tsv',
      '.txt',
      '.json',
      '.jsonl',
      '.ndjson',
      '.log',
    ]) {
      if (lower.endsWith(ext) && name.length > ext.length) {
        return name.substring(0, name.length - ext.length);
      }
    }
    return name;
  }
}

/// A selection that could not be used. The message is shown to the user verbatim.
class FileSelectionException implements Exception {
  const FileSelectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class PlatformFileSource {
  /// Returns null when the user cancels — cancelling is not an error.
  Future<PickedFile?> pick();
}

/// SAF-backed picker. Needs no storage permission and no network permission.
///
/// Pinned to file_picker **12**: version 11 applies the Kotlin Gradle Plugin, which Flutter
/// 3.47's Built-in Kotlin (AGP 9) no longer compiles, so its `FilePickerPlugin` class was
/// missing from the APK and the build failed. v12 detects Built-in Kotlin and federates the
/// Android implementation. See dependency-strategy §2.
class FilePickerSource implements PlatformFileSource {
  const FilePickerSource({this.maxBytes = defaultMaxBytes});

  /// Ceiling until ingest streams from disk.
  ///
  /// The engine decodes the source in one pass, so an unbounded import can exhaust a 4 GB
  /// phone. v12 exposes `length()` before any read, so this is checked *before* the bytes
  /// are pulled into memory — refusing with an explanation beats an OOM kill. The M1.1
  /// perf budget is 10 MB, well inside this.
  static const int defaultMaxBytes = 64 * 1024 * 1024;

  /// Every format the engine can parse as of M1.2 1.2.3. The engine detects which one from
  /// the content, so this list only widens what the OS lets the user choose.
  static const List<String> extensions = [
    'csv',
    'tsv',
    'txt',
    'json',
    'jsonl',
    'ndjson',
    'log',
  ];

  final int maxBytes;

  @override
  Future<PickedFile?> pick() async {
    final PlatformFile? file;
    try {
      // `pickFile` is v12's single-selection API; `pickFiles` now defaults to multi-select.
      file = await FilePicker.pickFile(
        dialogTitle: 'Choose a data file',
        type: FileType.custom,
        allowedExtensions: extensions,
      );
    } catch (e) {
      throw FileSelectionException('could not open the file picker: $e');
    }
    // Cancelling is a normal outcome, not an error.
    if (file == null) return null;

    final int size;
    try {
      size = await file.length();
    } catch (e) {
      throw FileSelectionException('could not determine the file size: $e');
    }
    if (size > maxBytes) {
      final mb = (size / (1024 * 1024)).toStringAsFixed(1);
      final limit = (maxBytes / (1024 * 1024)).round();
      throw FileSelectionException(
        'That file is $mb MB. This build reads up to $limit MB at once; '
        'streaming larger files arrives in a later update.',
      );
    }

    // Prefer a real filesystem path: the controller then performs the read, so the
    // `reading` stage describes work that actually happens. Android SAF usually hands back
    // a content URI instead, where `path` is null and the bytes must be read here.
    final path = file.path;
    if (path != null) {
      return PickedFile(name: file.name, path: path, sizeBytes: size);
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      throw FileSelectionException('could not read the chosen file: $e');
    }
    return PickedFile(name: file.name, bytes: bytes, sizeBytes: size);
  }
}
