/// Clipboard import for task 1.2.5.
///
/// [SystemClipboardSource] is exercised against a mocked platform channel rather than a fake
/// replacement, so the empty-clipboard contract, the UTF-8 byte measurement and the size
/// ceiling are all tested on the real code path.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/clipboard_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Installs a clipboard that answers with [text], or throws like a platform refusal.
  void mockClipboard({String? text, Object? failure}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method != 'Clipboard.getData') return null;
      if (failure != null) throw failure!;
      if (text == null) return null;
      return <String, dynamic>{'text': text};
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('reading the system clipboard', () {
    test('text arrives encoded as UTF-8', () async {
      mockClipboard(text: 'a,b\n1,2\n');
      final content = await const SystemClipboardSource().readText();
      expect(content, isNotNull);
      expect(content!.text, 'a,b\n1,2\n');
      expect(content.bytes, utf8.encode('a,b\n1,2\n'));
      expect(content.byteLength, 8);
    });

    test('an empty clipboard is an ordinary outcome, not an error', () async {
      mockClipboard();
      expect(await const SystemClipboardSource().readText(), isNull);
    });

    test('whitespace-only is also nothing to import', () async {
      mockClipboard(text: '   \n\t\n  ');
      expect(await const SystemClipboardSource().readText(), isNull);
    });

    test('the ceiling counts UTF-8 bytes, not characters', () async {
      // Each 'é' is two bytes, so 40 characters is 80 bytes and must exceed a 64-byte cap.
      final text = 'é' * 40;
      mockClipboard(text: text);
      expect(text.length, 40);
      expect(utf8.encode(text).length, 80);
      await expectLater(
        const SystemClipboardSource(maxBytes: 64).readText(),
        throwsA(isA<ClipboardReadException>()),
      );
    });

    test('a payload inside the ceiling is accepted', () async {
      mockClipboard(text: 'é' * 32);
      final content = await const SystemClipboardSource(maxBytes: 64).readText();
      expect(content, isNotNull);
      expect(content!.byteLength, 64);
    });

    test('the refusal explains the size and what to do', () async {
      mockClipboard(text: 'x' * 200);
      try {
        await const SystemClipboardSource(maxBytes: 100).readText();
        fail('should have refused');
      } on ClipboardReadException catch (e) {
        expect(e.message, contains('clipboard'));
        expect(e.message, contains('save it to a file'));
      }
    });

    test('a platform failure becomes a typed exception, never a crash', () async {
      mockClipboard(failure: PlatformException(code: 'denied'));
      await expectLater(
        const SystemClipboardSource().readText(),
        throwsA(isA<ClipboardReadException>()),
      );
    });
  });

  group('the preview line', () {
    test('the first non-empty line is used, trimmed', () {
      final c = ClipboardContent(text: '\n  \n  id,name  \n1,alice\n', bytes: _empty);
      expect(c.preview, 'id,name');
    });

    test('a long line is shortened rather than overflowing the card', () {
      final text = 'x' * 200;
      final c = ClipboardContent(text: text, bytes: _empty);
      expect(c.preview.length, 60);
      expect(c.preview.endsWith('…'), isTrue);
    });

    test('a short line is left alone', () {
      final c = ClipboardContent(text: 'a,b', bytes: _empty);
      expect(c.preview, 'a,b');
    });

    test('blank content has an empty preview, not a crash', () {
      final c = ClipboardContent(text: '\n \n', bytes: _empty);
      expect(c.preview, '');
    });
  });
}

final Uint8List _empty = Uint8List(0);
