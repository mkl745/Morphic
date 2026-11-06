/// The file-picking seam (M1.1 task 1.1.7).
///
/// `file_picker` is the one community plugin in the import path, so it sits behind
/// [PlatformFileSource] — the exit path named in dependency-strategy §2. Swapping it for
/// `file_selector` or a hand-written platform channel touches this file only, and the
/// import screen and controller are testable without any plugin at all.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

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

  /// A workspace title derived from the file name. Only a *known* tabular extension is
  /// stripped, so `report.final.csv` becomes `report.final`, not `report`.
  String get suggestedTitle {
    final lower = name.toLowerCase();
    for (final ext in const ['.csv', '.tsv', '.txt']) {
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
class FilePickerSource implements PlatformFileSource {
  const FilePickerSource({this.maxBytes = defaultMaxBytes});

  /// Temporary ceiling until ingest streams from disk (M1.2).
  ///
  /// The picker hands back the whole file in memory and the engine currently decodes it in
  /// one pass, so an unbounded pick can exhaust a 4 GB phone. Refusing with an explanation
  /// is better than an OOM kill. The M1.1 perf budget is 10 MB, well inside this.
  static const int defaultMaxBytes = 64 * 1024 * 1024;

  /// Only formats the engine can actually parse today: delimiter-sniffed text (`,`, `;`,
  /// tab). JSON and structured logs arrive in M1.2 — offering them here would be a promise
  /// the importer cannot keep.
  static const List<String> extensions = ['csv', 'tsv', 'txt'];

  final int maxBytes;

  @override
  Future<PickedFile?> pick() async {
    final FilePickerResult? result;
    try {
      // file_picker 11 replaced the `FilePicker.platform` singleton with static methods
      // on an `abstract final class`. Pinned here so a v12 change fails loudly at this one
      // call site rather than somewhere in the UI.
      result = await FilePicker.pickFiles(
        dialogTitle: 'Choose a CSV file',
        type: FileType.custom,
        allowedExtensions: extensions,
        withData: true,
      );
    } catch (e) {
      throw FileSelectionException('could not open the file picker: $e');
    }
    if (result == null || result.files.isEmpty) return null;
    final f = result.files.single;
    final size = f.bytes?.length ?? f.size;
    if (size > maxBytes) {
      final mb = (size / (1024 * 1024)).toStringAsFixed(1);
      final limit = (maxBytes / (1024 * 1024)).round();
      throw FileSelectionException(
        'That file is $mb MB. This build reads up to $limit MB at once; '
        'streaming larger files arrives in a later update.',
      );
    }
    if (f.bytes == null && f.path == null) {
      throw const FileSelectionException(
        'the picker returned a file with no readable data or path',
      );
    }
    return PickedFile(
      name: f.name,
      bytes: f.bytes,
      path: f.path,
      sizeBytes: size,
    );
  }
}
