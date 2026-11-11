import 'package:path_provider/path_provider.dart';

/// Where an exported `.morphic` bundle is written (M1.5 task 1.5.6).
///
/// Kept as a seam so widget tests never need the platform channel: they inject a fixed path
/// while production writes into the app's private documents directory.
abstract interface class BundlePathResolver {
  Future<String> exportPath(String workspaceId);
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
