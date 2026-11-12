/// Key-screen snapshots in both themes, using the shipped fonts and deterministic fakes.
@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/theme_preference.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/bridge_scope.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/features/home/home_screen.dart';
import 'package:morphic_flutter/features/import/import_screen.dart';
import 'package:morphic_flutter/features/settings/settings_screen.dart';
import 'package:morphic_flutter/features/workspace/workspace_screen.dart';

import '../support/fake_import.dart';
import '../support/golden_fonts.dart';
import '../support/scripted_bridge.dart';

class _GoldenThemeStore implements ThemePreferenceStore {
  _GoldenThemeStore(this.value);
  ThemeMode value;
  @override
  ThemeMode read() => value;
  @override
  void write(ThemeMode mode) => value = mode;
}

void _surface(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ThemeData _theme(Brightness brightness) =>
    brightness == Brightness.dark ? MorphicTheme.dark() : MorphicTheme.light();

Widget _host(ScriptedBridge bridge, Brightness brightness, Widget screen) => BridgeScope(
      bridge: bridge,
      storageRoot: '/local/morphic',
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(brightness),
        home: screen,
      ),
    );

void main() {
  setUpAll(loadMorphicGoldenFonts);
  for (final entry in {'dark': Brightness.dark, 'light': Brightness.light}.entries) {
    final name = entry.key;
    final brightness = entry.value;
    testWidgets('home with recent workspace $name', (tester) async {
      _surface(tester);
      final bridge = ScriptedBridge();
      bridge.workspaceIndex.single.addAll({
        'datasetId': 'abcdef0123456789',
        'modifiedAt': '2026-11-05T12:34:00Z',
      });
      await tester.pumpWidget(_host(
          bridge,
          brightness,
          HomeScreen(
            fileSource: FakeFileSource(),
            sampleLauncher: FakeSampleLauncher(),
          )));
      await tester.pumpAndSettle();
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/screen_home_$name.png'));
    });

    testWidgets('home first-run $name', (tester) async {
      _surface(tester);
      final bridge = ScriptedBridge()..workspaceIndex.clear();
      await tester.pumpWidget(_host(
          bridge,
          brightness,
          HomeScreen(
            fileSource: FakeFileSource(),
            sampleLauncher: FakeSampleLauncher(),
          )));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(Scaffold), matchesGoldenFile('goldens/screen_home_empty_$name.png'));
    });

    testWidgets('import chooser $name', (tester) async {
      _surface(tester);
      await tester.pumpWidget(_host(
          ScriptedBridge(),
          brightness,
          ImportScreen(
            fileSource: FakeFileSource(),
            runner: FakeImportRunner(),
            sampleLauncher: FakeSampleLauncher(),
          )));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(Scaffold), matchesGoldenFile('goldens/screen_import_$name.png'));
    });

    testWidgets('workspace chrome $name', (tester) async {
      _surface(tester);
      final bridge = ScriptedBridge();
      final engine = EngineController(bridge: bridge, storageRoot: '/local/morphic');
      await engine.open('w1');
      await tester.pumpWidget(_host(bridge, brightness, WorkspaceScreen(controller: engine)));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(Scaffold), matchesGoldenFile('goldens/screen_workspace_$name.png'));
    });

    testWidgets('settings appearance and storage $name', (tester) async {
      _surface(tester);
      final bridge = ScriptedBridge();
      final preference = MorphicThemePreference(_GoldenThemeStore(
        brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      ));
      addTearDown(preference.dispose);
      await tester.pumpWidget(MorphicThemeScope(
        preference: preference,
        child: _host(
            bridge,
            brightness,
            SettingsScreen(
              storageUsage: (_) async => 15360,
            )),
      ));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(Scaffold), matchesGoldenFile('goldens/screen_settings_$name.png'));
      await tester.drag(find.byType(ListView), const Offset(0, -560));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(Scaffold), matchesGoldenFile('goldens/screen_settings_more_$name.png'));
    });
  }
}
