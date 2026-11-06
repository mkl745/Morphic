/// The clipboard seam (M1.2 task 1.2.5).
///
/// Clipboard import needs no plugin and no permission: `Clipboard` ships with Flutter. It
/// still sits behind an interface for the same reason `file_picker` does — the screen and
/// controller stay testable without a platform, and a future platform channel touches one
/// file.
///
/// **Platform behaviour worth knowing.** Android 10+ only lets the focused app read the
/// clipboard, so this is called from a user tap while Morphic is in the foreground. Android
/// 13+ shows its own system notice when an app reads the clipboard; that notice is the OS
/// being transparent, not a Morphic prompt, and the UI says so rather than letting it look
/// like something unexpected.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'file_source.dart';

/// Text read from the clipboard, already encoded and size-checked.
class ClipboardContent {
  const ClipboardContent({required this.text, required this.bytes});

  final String text;
  final Uint8List bytes;

  int get byteLength => bytes.length;

  /// The first non-empty line, trimmed and shortened, for the file card. Never the whole
  /// payload: a clipboard can hold megabytes and the card is one line tall.
  String get preview {
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      return trimmed.length <= 60 ? trimmed : '${trimmed.substring(0, 57)}…';
    }
    return '';
  }
}

class ClipboardReadException implements Exception {
  const ClipboardReadException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class PlatformClipboardSource {
  /// Returns null when the clipboard holds no usable text. An empty clipboard is an ordinary
  /// outcome, not a failure — same contract as cancelling the file picker.
  Future<ClipboardContent?> readText();
}

class SystemClipboardSource implements PlatformClipboardSource {
  const SystemClipboardSource({this.maxBytes = FilePickerSource.defaultMaxBytes});

  /// The same ceiling the picker uses, so the two import paths cannot disagree about what
  /// this build can hold.
  final int maxBytes;

  @override
  Future<ClipboardContent?> readText() async {
    final ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (e) {
      throw ClipboardReadException('Morphic was unable to read the clipboard: $e');
    }
    final text = data?.text;
    // Whitespace-only is nothing to import, and saying "the file is empty" after a paste
    // would be a confusing way to learn that.
    if (text == null || text.trim().isEmpty) return null;

    // Measure UTF-8 bytes, not Dart code units: a CJK or emoji payload is several bytes per
    // character, and the engine's budget is in bytes.
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > maxBytes) {
      final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      final limit = (maxBytes / (1024 * 1024)).round();
      throw ClipboardReadException(
        'The clipboard holds $mb MB of text. This build reads up to $limit MB at once; '
        'save it to a file and import a smaller part.',
      );
    }
    return ClipboardContent(text: text, bytes: bytes);
  }
}
