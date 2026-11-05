/// Phase 0 runtime smoke test — runs on a real Android emulator/device with the actual
/// native library. Proves the Dart↔Rust FFI works at *runtime* (not just that it compiles):
/// the engine connects, and a bundled CSV is profiled by Rust.
///
/// Run: `flutter test integration_test/poc_smoke_test.dart` (CI: android-runtime-smoke job).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:morphic_flutter/app.dart';
import 'package:morphic_flutter/engine/bridge.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Rust engine connects and profiles a real CSV over FFI', (tester) async {
    final docs = await getApplicationDocumentsDirectory();
    await tester.pumpWidget(MorphicApp(
      bridge: FfiBridge(),
      storageRoot: '${docs.path}/morphic_smoke',
    ));

    // Let the engine-info future (a real FFI call) complete.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Rust engine connected'), findsOneWidget,
        reason: 'The Flutter app must load libmorphic_bridge and call Rust.');

    // Run the proof of concept: loads a bundled CSV and profiles it in Rust.
    await tester.tap(find.text('Run proof of concept'));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.text('Detected schema').evaluate().isNotEmpty) break;
    }

    expect(find.text('Detected schema'), findsOneWidget,
        reason: 'Rust must profile the sample CSV and return a schema.');
    expect(find.textContaining('rows'), findsWidgets);
  });
}
