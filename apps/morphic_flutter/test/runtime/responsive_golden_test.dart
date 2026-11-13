/// Representative responsive screens use the shipped fonts, real component renderers and
/// 1.3x text. These snapshots complement behavior tests; they do not certify all of AT-18.
@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

class _ThemeStore implements ThemePreferenceStore {
  _ThemeStore(this.mode);
  ThemeMode mode;

  @override
  ThemeMode read() => mode;

  @override
  void write(ThemeMode value) => mode = value;
}

Map<String, dynamic> _metric(String id, String title, String detail) => {
      'id': id,
      'type': 'metric_card',
      'title': title,
      'binding': {
        'kind': 'metric_card',
        'aggregation': {'op': 'count', 'field': null},
      },
      'explanation': {
        'reason': 'R1_records',
        'detail': detail,
        'evidence': ['Rows in the imported source'],
        'confidence': 0.9,
      },
    };

ScriptedBridge _bridge() => ScriptedBridge(
      metrics: {'records': 1234, 'orders': 82, 'regions': 12},
      components: [
        _metric('records', 'Records', 'The number of rows in this file.'),
        _metric('orders', 'Orders', 'A second measure for comparison.'),
        _metric('regions', 'Regions', 'A third measure for the wider canvas.'),
        {
          'id': 'data_table',
          'type': 'data_table',
          'title': 'Data',
          'binding': {'kind': 'data_table', 'columns': <String>[], 'page_size': 2},
          'interactions': {'search': true, 'sort': true, 'filter': true},
          'explanation': {'detail': 'Every imported record stays reachable.'},
        },
      ],
      order: ['records', 'orders', 'regions', 'data_table'],
      hints: [
        {'componentId': 'records', 'span': 1},
        {'componentId': 'orders', 'span': 1},
        {'componentId': 'regions', 'span': 1},
        {'componentId': 'data_table', 'span': 3},
      ],
    );

Future<void> _pump(WidgetTester tester, Size size, Brightness brightness) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final bridge = _bridge();
  final engine = EngineController(bridge: bridge, storageRoot: '/local/morphic');
  await engine.open('w1');
  await tester.pumpWidget(RepaintBoundary(
    key: const Key('responsive-snapshot'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: brightness == Brightness.dark ? MorphicTheme.dark() : MorphicTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
        child: child!,
      ),
      home: WorkspaceScreen(controller: engine),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _pumpGateway(WidgetTester tester, String name, Brightness brightness) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final bridge = ScriptedBridge();
  bridge.workspaceIndex.single.addAll({
    'datasetId': 'abcdef0123456789',
    'modifiedAt': '2026-11-05T12:34:00',
  });
  final preference = MorphicThemePreference(
    _ThemeStore(brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light),
  );
  addTearDown(preference.dispose);
  final Widget screen = switch (name) {
    'home' => HomeScreen(fileSource: FakeFileSource(), sampleLauncher: FakeSampleLauncher()),
    'import' => ImportScreen(
        fileSource: FakeFileSource(),
        runner: FakeImportRunner(),
        sampleLauncher: FakeSampleLauncher(),
      ),
    _ => SettingsScreen(storageUsage: (_) async => 15360),
  };
  await tester.pumpWidget(RepaintBoundary(
    key: const Key('responsive-snapshot'),
    child: MorphicThemeScope(
      preference: preference,
      child: BridgeScope(
        bridge: bridge,
        storageRoot: '/local/morphic',
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: brightness == Brightness.dark ? MorphicTheme.dark() : MorphicTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: screen,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _snapshot(WidgetTester tester, String filename) async {
  expect(tester.takeException(), isNull);
  await expectLater(
    find.byKey(const Key('responsive-snapshot')),
    matchesGoldenFile('goldens/$filename.png'),
  );
}

void main() {
  setUpAll(loadMorphicGoldenFonts);
  for (final theme in {'dark': Brightness.dark, 'light': Brightness.light}.entries) {
    for (final screen in ['home', 'import', 'settings']) {
      testWidgets('$screen at 1.3x ${theme.key}', (tester) async {
        await _pumpGateway(tester, screen, theme.value);
        if (screen == 'import') {
          final helper = find.text('Detect automatically unless the result looks wrong.');
          expect(helper, findsOneWidget);
          expect(tester.renderObject<RenderParagraph>(helper).didExceedMaxLines, isFalse);
        }
        await _snapshot(tester, 'responsive_${screen}_130_${theme.key}');
      });
    }

    testWidgets('compact portrait focus at 1.3x ${theme.key}', (tester) async {
      await _pump(tester, const Size(390, 844), theme.value);
      await tester.tap(find.byKey(const Key('focus-mode-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('focus-summary-orders')), findsOneWidget);
      await _snapshot(tester, 'responsive_compact_focus_${theme.key}');
    });

    testWidgets('compact landscape focus at 1.3x ${theme.key}', (tester) async {
      await _pump(tester, const Size(560, 360), theme.value);
      await tester.tap(find.byKey(const Key('focus-mode-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('focus-controls')), findsOneWidget);
      final viewport = tester.getRect(find.byKey(const Key('focus-content')));
      final active = tester.getRect(find.byKey(const Key('workspace-component-records')));
      expect(active.top, greaterThanOrEqualTo(viewport.top));
      expect(active.bottom, lessThanOrEqualTo(viewport.bottom));
      await _snapshot(tester, 'responsive_compact_landscape_${theme.key}');
    });

    testWidgets('medium landscape flow at 1.3x ${theme.key}', (tester) async {
      await _pump(tester, const Size(800, 500), theme.value);
      expect(find.byKey(const Key('workspace-detail-rail')), findsNothing);
      await _snapshot(tester, 'responsive_medium_landscape_${theme.key}');
    });

    testWidgets('medium landscape side detail at 1.3x ${theme.key}', (tester) async {
      await _pump(tester, const Size(800, 600), theme.value);
      await tester.tap(find.byKey(const Key('explain-records')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace-detail-side-sheet')), findsOneWidget);
      await _snapshot(tester, 'responsive_medium_detail_${theme.key}');
    });

    testWidgets('expanded landscape detail rail at 1.3x ${theme.key}', (tester) async {
      await _pump(tester, const Size(1360, 768), theme.value);
      await tester.tap(find.byKey(const Key('explain-records')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace-detail-rail')), findsOneWidget);
      final heading = find.text('amount');
      expect(heading, findsOneWidget);
      expect(tester.renderObject<RenderParagraph>(heading).didExceedMaxLines, isFalse);
      await _snapshot(tester, 'responsive_expanded_rail_${theme.key}');
    });
  }
}
