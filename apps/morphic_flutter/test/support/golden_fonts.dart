/// Golden tests explicitly load the bundled fonts; Flutter's default test font is boxes.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadMorphicGoldenFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final inter = FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
  final mono = FontLoader('JetBrainsMono')
    ..addFont(rootBundle.load('assets/fonts/JetBrainsMono.ttf'));
  // Flutter's test renderer does not auto-load the Material icon font. Without this,
  // controls render as square glyphs instead of the icons shipped with the app.
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await Future.wait([inter.load(), mono.load(), icons.load()]);
}
