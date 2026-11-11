import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where an exported `.morphic` bundle is written (M1.5 task 1.5.6).
///
/// Kept as a seam so widget tests never need the platform channel: they inject a fixed path
/// while production writes into the app's private documents directory.
abstract interface class BundlePathResolver {
  Future<String> exportPath(String workspaceId);
}

/// Where the bytes actually go. Kept separate from the path resolver so widget tests stay
/// inside the fake-async test zone and never wait on real disk I/O.
abstract interface class BundleWriter {
  Future<void> write(String path, List<int> bytes);
}

class DocumentsBundlePathResolver implements BundlePathResolver {
  const DocumentsBundlePathResolver();

  @override
  Future<String> exportPath(String workspaceId) async {
    final dir = await getApplicationDocumentsDirectory();
    final safe = workspaceId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '${dir.path}/$safe.morphic';
  }
}

class FileBundleWriter implements BundleWriter {
  const FileBundleWriter();

  @override
  Future<void> write(String path, List<int> bytes) =>
      File(path).writeAsBytes(bytes);
}
