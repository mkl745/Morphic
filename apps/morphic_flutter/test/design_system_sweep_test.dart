/// Design-sweep contracts. These are host tests, not a TalkBack or physical-device pass.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/app.dart';
import 'package:morphic_flutter/design_system/motion.dart';
import 'package:morphic_flutter/design_system/theme_preference.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/bridge_scope.dart';
import 'package:morphic_flutter/engine/clipboard_source.dart';
import 'package:morphic_flutter/engine/file_source.dart';
import 'package:morphic_flutter/engine/import_limits.dart';
import 'package:morphic_flutter/engine/storage_usage.dart';
import 'package:morphic_flutter/features/settings/settings_screen.dart';

import 'support/scripted_bridge.dart';

class _MemoryThemeStore implements ThemePreferenceStore {
  ThemeMode? value;
  bool failRead = false;
  bool failWrite = false;

  @override
  ThemeMode? read() {
    if (failRead) throw StateError('read failed');
    return value;
  }

  @override
  void write(ThemeMode mode) {
    if (failWrite) throw StateError('write failed');
    value = mode;
  }
}

double _contrast(Color a, Color b) {
  final aa = a.computeLuminance();
  final bb = b.computeLuminance();
  return (math.max(aa, bb) + 0.05) / (math.min(aa, bb) + 0.05);
}

void main() {
  test('theme tokens include text-safe semantic pairs in both modes', () {
    for (final theme in [MorphicTheme.dark(), MorphicTheme.light()]) {
      final scheme = theme.colorScheme;
      final pairs = <(Color, Color)>[
        (scheme.onSurface, scheme.surface),
        (scheme.onSurface, theme.scaffoldBackgroundColor),
        (scheme.onSurfaceVariant, scheme.surface),
        (scheme.onSurfaceVariant, theme.scaffoldBackgroundColor),
        (scheme.onPrimary, scheme.primary),
        (scheme.onSecondary, scheme.secondary),
        (scheme.onSecondaryContainer, scheme.secondaryContainer),
        (scheme.error, scheme.surface),
        (MorphicColors.warningText(theme.brightness), scheme.surface),
        (MorphicColors.successText(theme.brightness), scheme.surface),
        (theme.textButtonTheme.style!.foregroundColor!.resolve({})!, scheme.surface),
        (theme.outlinedButtonTheme.style!.foregroundColor!.resolve({})!, scheme.surface),
      ];
      for (final (foreground, background) in pairs) {
        expect(_contrast(foreground, background), greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness}: $foreground on $background');
      }
      expect(theme.textTheme.bodyMedium!.fontFamily, MorphicTypography.ui);
      expect(MorphicTypography.dataStyle(theme.textTheme.bodySmall)!.fontFamily,
          MorphicTypography.data);
    }
  });

  test('file preference is restored and an invalid value is reported', () {
    final root = Directory.systemTemp.createTempSync('morphic-theme-');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = FileThemePreferenceStore(root.path);
    expect(store.read(), isNull);
    store.write(ThemeMode.light);
    expect(store.read(), ThemeMode.light);
    store.write(ThemeMode.system);
    expect(store.read(), ThemeMode.system);
    File('${root.path}/theme-preference').writeAsStringSync('bad value');
    expect(store.read, throwsFormatException);
    final preference = MorphicThemePreference(store);
    addTearDown(preference.dispose);
    expect(preference.mode, ThemeMode.dark);
    expect(preference.message, contains('Could not read'));
    preference.select(ThemeMode.light);
    expect(preference.message, isNull);
    expect(store.read(), ThemeMode.light);
  });

  test('a failed write keeps the session choice but does not claim it was saved', () {
    final store = _MemoryThemeStore()..failWrite = true;
    final preference = MorphicThemePreference(store);
    addTearDown(preference.dispose);
    preference.select(ThemeMode.light);
    expect(preference.mode, ThemeMode.light);
    expect(preference.message, contains('Could not save'));
    expect(store.value, isNull);
    store.failWrite = false;
    preference.select(ThemeMode.light);
    expect(preference.message, isNull);
    expect(store.value, ThemeMode.light);
  });

  testWidgets('theme choice applies across routes and is restored by the app', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryThemeStore();
    await tester.pumpWidget(MorphicApp(
      bridge: ScriptedBridge(),
      storageRoot: '/tmp/morphic-theme-widget',
      themePreferenceStore: store,
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-picker-dark')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light').last);
    await tester.pumpAndSettle();
    expect(store.value, ThemeMode.light);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.light);
    expect(find.text('Settings'), findsOneWidget, reason: 'changing theme must keep the route');

    await tester.pageBack();
    await tester.pumpAndSettle();
    final home = tester.element(find.text('Your Data. Your Interface.'));
    expect(Theme.of(home).brightness, Brightness.light);
    final subtitle = tester.widget<Text>(find.text('Your Data. Your Interface.'));
    expect(subtitle.style!.color, MorphicColors.textSecondaryLight);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MorphicApp(
      bridge: ScriptedBridge(),
      storageRoot: '/tmp/morphic-theme-widget',
      themePreferenceStore: store,
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.light);
  });

  testWidgets('system theme follows platform brightness changes', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final store = _MemoryThemeStore()..value = ThemeMode.system;
    await tester.pumpWidget(MorphicApp(
      bridge: ScriptedBridge(),
      storageRoot: '/tmp/morphic-theme-system',
      themePreferenceStore: store,
    ));
    await tester.pumpAndSettle();
    final home = find.text('Your Data. Your Interface.');
    expect(Theme.of(tester.element(home)).brightness, Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(home)).brightness, Brightness.dark);
  });

  test('storage measures local file lengths and rejects an invalid root', () async {
    final root = Directory.systemTemp.createTempSync('morphic-storage-');
    addTearDown(() => root.deleteSync(recursive: true));
    final nested = Directory('${root.path}/nested')..createSync();
    File('${root.path}/a').writeAsBytesSync([1, 2, 3]);
    File('${nested.path}/b').writeAsBytesSync([1, 2, 3, 4, 5]);
    Link('${root.path}/link').createSync('${root.path}/a');
    expect(await measureStorageBytes(root.path), 8, reason: 'do not follow symlinks');
    expect(await measureStorageBytes('${root.path}/not-present'), 0);
    await expectLater(
      measureStorageBytes('${root.path}/a'),
      throwsA(isA<FileSystemException>()),
    );
  });

  testWidgets('storage measurement failure is visible and retryable', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    await tester.pumpWidget(BridgeScope(
      bridge: ScriptedBridge(),
      storageRoot: '/fake',
      child: MaterialApp(
        home: SettingsScreen(storageUsage: (_) {
          calls++;
          return calls == 1 ? Future<int>.error(StateError('denied')) : Future<int>.value(3072);
        }),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Could not measure local storage.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('storage-retry')));
    await tester.pumpAndSettle();
    expect(find.text('3.0 KB in local files'), findsOneWidget);
    expect(calls, 2);
    expect(find.textContaining('2,000,000 rows'), findsOneWidget);
  });

  test('the displayed import ceilings are tied to the real default options', () {
    final rust = File('../../engine/crates/morphic-ingest/src/lib.rs').readAsStringSync();
    int value(String field) {
      final match = RegExp('$field: ([0-9_]+),').firstMatch(rust);
      expect(match, isNotNull);
      return int.parse(match!.group(1)!.replaceAll('_', ''));
    }

    expect(ImportLimits.rows, value('max_rows'));
    expect(ImportLimits.columns, value('max_columns'));
    expect(rust, contains('max_memory_bytes: 512 * 1024 * 1024'));
    expect(ImportLimits.memoryBytes, 512 * 1024 * 1024);
    expect(const SystemClipboardSource().maxBytes, FilePickerSource.defaultMaxBytes);
  });

  testWidgets('entrance has bounded stagger; reduced motion has opacity only', (tester) async {
    final controller = AnimationController(vsync: tester, duration: MorphicMotion.entranceLimit);
    addTearDown(controller.dispose);

    Widget host(bool reduced) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Scaffold(
              body: Column(children: [
                for (final index in [0, 1, 99])
                  MorphicEntrance(
                    key: Key('entrance-$index'),
                    animation: controller,
                    index: index,
                    child: Text('Component $index'),
                  ),
              ]),
            ),
          ),
        );
    double opacity(int index) => tester
        .widget<Opacity>(find.descendant(
          of: find.byKey(Key('entrance-$index')),
          matching: find.byType(Opacity),
        ))
        .opacity;
    double translation(int index) => tester
        .widget<Transform>(find.descendant(
          of: find.byKey(Key('entrance-$index')),
          matching: find.byType(Transform),
        ))
        .transform
        .storage[13];

    await tester.pumpWidget(host(false));
    expect(opacity(0), 0);
    expect(translation(0), MorphicMotion.entranceRise);
    controller.value = 0.05; // 20 ms: first has started, second waits for its 40 ms stagger.
    await tester.pump();
    expect(opacity(0), greaterThan(0));
    expect(opacity(1), 0);
    controller.value = 0.5; // 200 ms: the latest capped entrance has just begun.
    await tester.pump();
    expect(opacity(0), 1);
    expect(opacity(99), 0);
    controller.value = 1;
    await tester.pump();
    expect(opacity(99), 1, reason: 'even large component counts finish within 400 ms');

    controller.value = 0.05;
    await tester.pumpWidget(host(true));
    expect(opacity(0), greaterThan(0));
    expect(opacity(99), opacity(0), reason: 'reduced motion removes stagger');
    expect(translation(0), 0, reason: 'reduced motion removes translation');
  });

  testWidgets('a new engine stage removes the old label rather than faking progress',
      (tester) async {
    Widget host(String key, String label) => MaterialApp(
          home: Scaffold(
            body: MorphicStageLabel(stageKey: key, label: label, style: null),
          ),
        );
    await tester.pumpWidget(host('sniffing', 'Detecting format'));
    expect(find.text('Detecting format'), findsOneWidget);
    await tester.pumpWidget(host('parsing', 'Reading rows'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Detecting format'), findsNothing);
    expect(find.text('Reading rows'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
  });
}
