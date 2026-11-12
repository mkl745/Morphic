/// An approximate snapshot of files in MORPHIC's local storage root.
library;

import 'dart:io';

/// Counts file lengths, not disk blocks or free space. Symlinks are not traversed. An I/O
/// error fails the scan rather than returning a deceptively small, partial total.
Future<int> measureStorageBytes(String root) async {
  final type = await FileSystemEntity.type(root, followLinks: false);
  if (type == FileSystemEntityType.notFound) return 0;
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException('Storage root is not a directory', root);
  }
  final directory = Directory(root);
  var bytes = 0;
  await for (final entity in directory.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final stat = await entity.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('A file changed while measuring storage', entity.path);
    }
    bytes += stat.size;
  }
  return bytes;
}

/// Binary units, matching the picker. This is a display helper, not an engine measurement.
String formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
