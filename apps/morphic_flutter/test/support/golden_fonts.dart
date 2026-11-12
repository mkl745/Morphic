/// Golden tests explicitly load the bundled fonts; Flutter's default test font is boxes.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadMorphicGoldenFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final inter = FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
  final mono = FontLoader('JetBrainsMono')
    ..addFont(rootBundle.load('assets/fonts/JetBrainsMono.ttf'));
  await inter.load();
  await mono.load();
}
