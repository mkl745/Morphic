/// Responsive behavior under real viewport constraints, not just a mocked MediaQuery.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/responsive.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/bridge_scope.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';
import 'package:morphic_flutter/features/home/home_screen.dart';
import 'package:morphic_flutter/features/import/import_screen.dart';
import 'package:morphic_flutter/features/settings/settings_screen.dart';
import 'package:morphic_flutter/features/workspace/workspace_screen.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/explanation_sheet.dart';

import '../support/fake_import.dart';
import '../support/scripted_bridge.dart';

Map<String, dynamic> _spec(String id, String type) => {
      'id': id,
      'type': type,
      'title': 'View $id',
      'binding': {'kind': type},
      'explanation': {'detail': 'Summary for $id'},
    };

ComponentRegistry _geometryRegistry() => ComponentRegistry(overrides: {
      for (final type in ['metric_card', 'data_table', 'bar_chart', 'line_chart', 'timeline'])
        type: (ctx) => SizedBox(
              key: Key('paint-${ctx.id}'),
              height: 88,
              child: Card(child: Center(child: Text('Paint ${ctx.id}'))),
            ),
    });

ScriptedBridge _mixedBridge() => ScriptedBridge(
      // Document order intentionally differs from layout.order.
      components: [
        _spec('metric', 'metric_card'),
        _spec('table', 'data_table'),
        _spec('bar', 'bar_chart'),
        _spec('line', 'line_chart'),
        _spec('timeline', 'timeline'),
      ],
      order: ['table', 'metric', 'bar', 'line', 'timeline'],
      hints: [
        {'componentId': 'table', 'span': 1},
        {'componentId': 'metric', 'span': 1},
        {'componentId': 'bar', 'span': 1},
        {'componentId': 'line', 'span': 2},
        {'componentId': 'timeline', 'span': 1},
      ],
    );

ScriptedBridge _tableBridge() => ScriptedBridge(
      components: [
        {
          'id': 'data_table',
          'type': 'data_table',
          'title': 'Orders',
          'binding': {'kind': 'data_table', 'columns': <String>[], 'page_size': 2},
          'explanation': {
            'reason': 'R6_raw_table',
            'detail': 'Every record remains reachable.',
            'evidence': ['All source fields'],
            'confidence': 0.9,
          },
        },
      ],
      order: ['data_table'],
      rows: [
        ['eu', 10, null],
        ['us', 20, 'note'],
      ],
    );

Widget _app(EngineController engine, {ComponentRegistry? registry, double scale = 1}) =>
    MaterialApp(
      theme: MorphicTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: WorkspaceScreen(controller: engine, registry: registry),
    );

void _setSurface(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

void _resetSurface(WidgetTester tester) {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _resize(WidgetTester tester, Size size) async {
  _setSurface(tester, size);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Rect _paintRect(WidgetTester tester, String id) => tester.getRect(find.byKey(Key('paint-$id')));

Future<void> _closeWhy(WidgetTester tester) async {
  final close = find.byKey(const Key('why-sheet-close'));
  await tester.ensureVisible(close);
  await tester.tap(close);
  await tester.pumpAndSettle();
  expect(find.byType(WhyThisViewSheet), findsNothing);
  expect(find.byType(WorkspaceScreen), findsOneWidget,
      reason: 'closing an in-place rail must never pop the workspace');
}

void main() {
  test('window class boundaries are inclusive exactly where specified', () {
    expect(MorphicResponsive.classify(599.999), MorphicWindowClass.compact);
    expect(MorphicResponsive.classify(600), MorphicWindowClass.medium);
    expect(MorphicResponsive.classify(840), MorphicWindowClass.medium);
    expect(MorphicResponsive.classify(840.001), MorphicWindowClass.expanded);
  });

  for (final name in ['home', 'import', 'settings']) {
    testWidgets('$name remains readable on wide and compact windows at 1.3x', (tester) async {
      _resetSurface(tester);
      _setSurface(tester, const Size(1400, 800));
      final previousHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        debugPrint('Responsive $name diagnostic: ${details.toString()}');
        previousHandler?.call(details);
      };
      addTearDown(() => FlutterError.onError = previousHandler);
      final bridge = ScriptedBridge();
      final Widget screen = switch (name) {
        'home' => HomeScreen(fileSource: FakeFileSource(), sampleLauncher: FakeSampleLauncher()),
        'import' => ImportScreen(
            fileSource: FakeFileSource(),
            runner: FakeImportRunner(),
            sampleLauncher: FakeSampleLauncher(),
          ),
        _ => SettingsScreen(storageUsage: (_) async => 1024),
      };
      await tester.pumpWidget(BridgeScope(
        bridge: bridge,
        storageRoot: '/tmp/m',
        child: MaterialApp(
          theme: MorphicTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: screen,
        ),
      ));
      await tester.pumpAndSettle();
      final page = find.byKey(const Key('morphic-page-width'));
      expect(tester.getSize(page).width, closeTo(840, 0.1));
      await _resize(tester, const Size(390, 844));
      expect(tester.getSize(page).width, closeTo(390, 0.1));
      if (name == 'import') {
        final guidance = find.textContaining('Morphic reports how it read the file');
        final scrollable = find.descendant(of: page, matching: find.byType(Scrollable)).first;
        await tester.scrollUntilVisible(guidance, 200, scrollable: scrollable);
        await tester.pumpAndSettle();
        expect(tester.getRect(guidance).bottom, lessThanOrEqualTo(tester.getRect(page).bottom));
      }
      await _resize(tester, const Size(1400, 800));
    });
  }

  testWidgets('mixed views follow engine order and spans at the actual breakpoints',
      (tester) async {
    _resetSurface(tester);
    _setSurface(tester, const Size(599, 1000));
    final bridge = _mixedBridge();
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_app(engine, registry: _geometryRegistry(), scale: 1.3));
    await tester.pumpAndSettle();

    var table = _paintRect(tester, 'table');
    var metric = _paintRect(tester, 'metric');
    expect(table.left, closeTo(metric.left, 0.1));
    expect(metric.top, greaterThan(table.top));
    expect(find.byKey(const Key('workspace-detail-rail')), findsNothing);

    for (final width in [600.0, 840.0, 841.0]) {
      await _resize(tester, Size(width, 1000));
      table = _paintRect(tester, 'table');
      metric = _paintRect(tester, 'metric');
      final bar = _paintRect(tester, 'bar');
      final line = _paintRect(tester, 'line');
      expect(table.top, closeTo(metric.top, 0.1), reason: '$width dp must have two columns');
      expect(metric.left, greaterThan(table.left));
      expect(bar.top, greaterThan(table.top), reason: 'layout.order is not re-sorted');
      expect(line.width, greaterThan(bar.width * 1.9), reason: 'span 2 takes both columns');
      expect(find.byKey(const Key('workspace-detail-rail')),
          width > 840 ? findsOneWidget : findsNothing);
    }

    await _resize(tester, const Size(1360, 800));
    table = _paintRect(tester, 'table');
    metric = _paintRect(tester, 'metric');
    final bar = _paintRect(tester, 'bar');
    final line = _paintRect(tester, 'line');
    final timeline = _paintRect(tester, 'timeline');
    expect(table.top, closeTo(metric.top, 0.1));
    expect(metric.top, closeTo(bar.top, 0.1), reason: 'expanded canvas has three columns');
    expect(bar.left, greaterThan(metric.left));
    expect(line.top, greaterThan(bar.top));
    expect(line.top, closeTo(timeline.top, 0.1), reason: 'span 2 plus span 1 share the next row');
    expect(timeline.left, greaterThan(line.left));
    expect(bridge.commandBatches, isEmpty, reason: 'resizing is not a layout command');
    expect(bridge.order, ['table', 'metric', 'bar', 'line', 'timeline']);
  });

  testWidgets('large valid workspaces do not eagerly query every off-screen table', (tester) async {
    _resetSurface(tester);
    _setSurface(tester, const Size(390, 500));
    final bridge = ScriptedBridge(
      components: [
        for (var i = 0; i < 20; i++)
          {
            'id': 'table$i',
            'type': 'data_table',
            'title': 'Table $i',
            'binding': {'kind': 'data_table', 'columns': <String>[], 'page_size': 2},
          },
      ],
      order: [for (var i = 0; i < 20; i++) 'table$i'],
    );
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_app(engine));
    await tester.pumpAndSettle();
    expect(bridge.pageCalls.length, lessThan(20));
    final before = bridge.pageCalls.length;
    final outer = tester.getRect(find.byKey(const Key('workspace-component-flow')));
    await tester.dragFrom(Offset(outer.left + 4, outer.center.dy), const Offset(0, -750));
    await tester.pumpAndSettle();
    expect(bridge.pageCalls.length, greaterThan(before));
    expect(bridge.pageCalls.length, lessThan(20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact focus keeps summaries and bottom controls through rotation', (tester) async {
    _resetSurface(tester);
    _setSurface(tester, const Size(390, 844));
    final bridge = _mixedBridge();
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_app(engine, registry: _geometryRegistry(), scale: 1.3));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('focus-mode-button')));
    await tester.pumpAndSettle();
    expect(find.text('1 of 5'), findsOneWidget);
    expect(find.byKey(const Key('paint-table')), findsOneWidget);
    expect(find.byKey(const Key('paint-metric')), findsNothing);
    expect(find.byKey(const Key('focus-summary-metric')), findsOneWidget);
    expect(find.text('Summary for metric'), findsOneWidget);
    final controls = tester.getRect(find.byKey(const Key('focus-controls')));
    final content = tester.getRect(find.byKey(const Key('focus-content')));
    expect(controls.top, greaterThanOrEqualTo(content.bottom));

    await tester.tap(find.byKey(const Key('focus-summary-metric')));
    await tester.pumpAndSettle();
    expect(find.text('2 of 5'), findsOneWidget);
    expect(find.byKey(const Key('paint-metric')), findsOneWidget);
    expect(find.byKey(const Key('focus-summary-table')), findsOneWidget);
    await tester.tap(find.byKey(const Key('focus-next-button')));
    await tester.pumpAndSettle();
    expect(find.text('3 of 5'), findsOneWidget);

    await _resize(tester, const Size(700, 400));
    expect(find.byKey(const Key('focus-mode-button')), findsNothing);
    expect(find.byKey(const Key('workspace-component-flow')), findsOneWidget);
    await _resize(tester, const Size(390, 844));
    expect(find.text('3 of 5'), findsOneWidget,
        reason: 'view-only focus selection survives rotation');
    expect(find.byKey(const Key('paint-bar')), findsOneWidget);
    expect(bridge.commandBatches, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focus navigation reveals the selected view on a short screen', (tester) async {
    _resetSurface(tester);
    _setSurface(tester, const Size(390, 400));
    final bridge = _mixedBridge();
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_app(engine, registry: _geometryRegistry(), scale: 1.3));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('focus-mode-button')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const Key('focus-next-button')));
      await tester.pumpAndSettle();
    }
    expect(find.text('5 of 5'), findsOneWidget);
    final viewport = tester.getRect(find.byKey(const Key('focus-content')));
    final selected = _paintRect(tester, 'timeline');
    expect(selected.top, greaterThanOrEqualTo(viewport.top));
    expect(selected.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(bridge.commandBatches, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resizing layout stays engine-owned at compact, medium and expanded widths',
      (tester) async {
    _resetSurface(tester);
    _setSurface(tester, const Size(390, 844));
    final bridge = _mixedBridge();
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_app(engine, registry: _geometryRegistry(), scale: 1.3));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('layout-edit-button')));
    await tester.pumpAndSettle();
    for (final size in [const Size(390, 844), const Size(700, 500), const Size(1100, 700)]) {
      await _resize(tester, size);
      expect(find.byKey(const Key('layout-menu-table')), findsOneWidget);
      await tester.tap(find.byKey(const Key('layout-menu-table')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Span 2'));
      await tester.pumpAndSettle();
      expect(bridge.commandBatches.last.single['kind'], 'resizeComponent');
      expect(bridge.commandBatches.last.single['componentId'], 'table');
      expect(bridge.commandBatches.last.single['span'], 2);
      expect(
        find.descendant(
          of: find.byKey(const Key('layout-tile-table')),
          matching: find.text('span 2 · height auto'),
        ),
        findsOneWidget,
        reason: 'the saved span remains visible even where rendering is clamped',
      );
    }
    await tester.tap(find.byKey(const Key('layout-edit-button')));
    await tester.pumpAndSettle();
    final table = _paintRect(tester, 'table');
    final metric = _paintRect(tester, 'metric');
    expect(table.width, greaterThan(metric.width * 1.9));
    expect(bridge.hints.firstWhere((hint) => hint['componentId'] == 'table')['span'], 2);
  });

  for (final entry in <String, Size>{
    'medium': const Size(700, 650),
    'expanded': const Size(1100, 800),
  }.entries) {
    testWidgets('drag reorder stays engine-owned at ${entry.key} width', (tester) async {
      _resetSurface(tester);
      _setSurface(tester, entry.value);
      final bridge = _mixedBridge();
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await tester.pumpWidget(_app(engine, registry: _geometryRegistry(), scale: 1.3));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('layout-edit-button')));
      await tester.pumpAndSettle();
      final handle = find.byKey(const Key('layout-drag-table'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(seconds: 1));
      await gesture.moveBy(const Offset(0, 160));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(bridge.commandBatches.last.single['kind'], 'moveComponent');
      expect(bridge.commandBatches.last.single['componentId'], 'table');
      expect(bridge.order.first, isNot('table'));
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in <String, Size>{
    'compact': const Size(390, 844),
    'medium landscape': const Size(700, 500),
    'expanded landscape': const Size(1100, 700),
  }.entries) {
    testWidgets('${entry.key} presents and safely closes explanation and row detail at 1.3x',
        (tester) async {
      _resetSurface(tester);
      _setSurface(tester, entry.value);
      final bridge = _tableBridge();
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await tester.pumpWidget(_app(engine, scale: 1.3));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('explain-data_table')));
      await tester.pumpAndSettle();
      expect(find.byType(WhyThisViewSheet), findsOneWidget);
      if (entry.key == 'compact') {
        expect(find.byType(BottomSheet), findsOneWidget);
      } else if (entry.key == 'medium landscape') {
        expect(find.byKey(const Key('workspace-detail-side-sheet')), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
      } else {
        expect(find.byKey(const Key('workspace-detail-rail')), findsOneWidget);
        expect(find.byKey(const Key('workspace-detail-side-sheet')), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('workspace-detail-rail')),
            matching: find.byType(WhyThisViewSheet),
          ),
          findsOneWidget,
        );
      }
      await _closeWhy(tester);

      await tester.tap(find.text('eu').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Row 1'), findsOneWidget);
      expect(find.text('No value (null)'), findsOneWidget);
      if (entry.key == 'compact') {
        expect(find.byType(BottomSheet), findsOneWidget);
      } else if (entry.key == 'medium landscape') {
        expect(find.byKey(const Key('workspace-detail-side-sheet')), findsOneWidget);
      } else {
        expect(
          find.descendant(
            of: find.byKey(const Key('workspace-detail-rail')),
            matching: find.text('Row 1'),
          ),
          findsOneWidget,
        );
      }
      await tester.tap(find.byKey(const Key('row-detail-close')));
      await tester.pumpAndSettle();
      expect(find.text('Row 1'), findsNothing);
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in <String, Size>{
    'short compact': const Size(390, 400),
    'medium landscape': const Size(700, 500),
    'expanded': const Size(1100, 700),
  }.entries) {
    testWidgets('filter and correction forms remain usable in ${entry.key} at 1.3x',
        (tester) async {
      _resetSurface(tester);
      _setSurface(tester, entry.value);
      final bridge = _tableBridge();
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await tester.pumpWidget(_app(engine, scale: 1.3));
      await tester.pumpAndSettle();

      final add = find.byKey(const Key('global-filter-add'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('Filter the whole workspace'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget,
          reason: 'editing forms remain modal rather than replacing inspection detail');
      await tester.enterText(find.byKey(const Key('filter-value')), 'eu');
      final apply = find.byKey(const Key('filter-apply'));
      await tester.ensureVisible(apply);
      await tester.pumpAndSettle();
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(bridge.commandBatches.last.single['kind'], 'setGlobalFilter');

      final header = find.byKey(const Key('sort-region'));
      final flow = find.byKey(const Key('workspace-component-flow'));
      final scrollable = find.descendant(of: flow, matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(header, 120, scrollable: scrollable);
      await tester.pumpAndSettle();
      await tester.longPress(header);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('field-corrections-sheet')), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      final cancel = find.text('Cancel');
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('field-corrections-sheet')), findsNothing);
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('open detail moves between bottom, side and rail on resize', (tester) async {
    _resetSurface(tester);
    _setSurface(tester, const Size(390, 844));
    final bridge = _tableBridge();
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_app(engine, scale: 1.3));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('explain-data_table')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);

    await _resize(tester, const Size(700, 500));
    expect(find.byKey(const Key('workspace-detail-side-sheet')), findsOneWidget);
    expect(find.byType(WhyThisViewSheet), findsOneWidget);
    await _resize(tester, const Size(1100, 700));
    expect(find.byKey(const Key('workspace-detail-side-sheet')), findsNothing);
    expect(
        find.descendant(
          of: find.byKey(const Key('workspace-detail-rail')),
          matching: find.byType(WhyThisViewSheet),
        ),
        findsOneWidget);
    await _resize(tester, const Size(390, 844));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(WhyThisViewSheet), findsOneWidget);
    await _closeWhy(tester);
    expect(bridge.commandBatches, isEmpty);
  });

  testWidgets('an open table row follows the window into the rail', (tester) async {
    _resetSurface(tester);
    _setSurface(tester, const Size(390, 844));
    final bridge = _tableBridge();
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_app(engine, scale: 1.3));
    await tester.pumpAndSettle();
    await tester.tap(find.text('eu').hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await _resize(tester, const Size(700, 500));
    expect(find.byKey(const Key('workspace-detail-side-sheet')), findsOneWidget);
    expect(find.text('Row 1'), findsOneWidget);
    await _resize(tester, const Size(1100, 700));
    expect(
        find.descendant(
          of: find.byKey(const Key('workspace-detail-rail')),
          matching: find.text('Row 1'),
        ),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('row-detail-close')));
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceScreen), findsOneWidget);
    expect(find.text('Row 1'), findsNothing);
  });

  for (final type in ['bar', 'line', 'timeline']) {
    testWidgets('$type chart data opens and closes in the expanded rail', (tester) async {
      _resetSurface(tester);
      _setSurface(tester, const Size(1100, 900));
      final binding = switch (type) {
        'bar' => {
            'kind': 'bar_chart',
            'dimension': 'group',
            'measure': {'op': 'avg', 'field': 'value'},
            'limit': 4,
          },
        'line' => {
            'kind': 'line_chart',
            'x': 'ts',
            'y': [
              {'op': 'avg', 'field': 'value'},
            ],
            'group_by': 'group',
          },
        _ => {'kind': 'timeline', 'time_field': 'ts', 'severity_field': 'group'},
      };
      final componentType = type == 'bar' ? 'bar_chart' : (type == 'line' ? 'line_chart' : type);
      final bridge = ScriptedBridge(
        fields: ['ts', 'group', 'value'],
        dtypes: {'ts': 'timestamp', 'value': 'float64'},
        rows: [
          [0, 'api', 10],
          [60000, 'web', 20],
          [120000, 'api', 30],
        ],
        components: [
          {'id': 'chart', 'type': componentType, 'title': 'Chart', 'binding': binding},
        ],
        order: ['chart'],
      );
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await tester.pumpWidget(_app(engine, scale: 1.3));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('$type-view-as-table')));
      await tester.pumpAndSettle();
      final close = find.byKey(Key('$type-table-close'));
      expect(
        find.descendant(of: find.byKey(const Key('workspace-detail-rail')), matching: close),
        findsOneWidget,
      );
      if (type != 'bar') expect(find.textContaining('Snapshot of the visible'), findsOneWidget);
      await tester.ensureVisible(close);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(close, findsNothing);
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final type in ['line', 'timeline']) {
    testWidgets('$type rail wraps multi-series detail at 1.3x', (tester) async {
      _resetSurface(tester);
      _setSurface(tester, const Size(1100, 800));
      const groups = [
        'api',
        'auth',
        'billing',
        'cache',
        'ingest',
        'metrics',
        'queue',
        'zulu_service_with_a_very_long_name',
      ];
      final componentType = type == 'line' ? 'line_chart' : 'timeline';
      final binding = type == 'line'
          ? {
              'kind': 'line_chart',
              'x': 'ts',
              'y': [
                {'op': 'avg', 'field': 'value'},
              ],
              'group_by': 'group',
            }
          : {'kind': 'timeline', 'time_field': 'ts', 'severity_field': 'group'};
      final bridge = ScriptedBridge(
        fields: ['ts', 'group', 'value'],
        dtypes: {'ts': 'timestamp', 'value': 'float64'},
        rows: [
          for (var i = 0; i < groups.length; i++) [0, groups[i], 10 + i],
          [60000, 'api', 20],
        ],
        components: [
          {'id': 'chart', 'type': componentType, 'title': 'Chart', 'binding': binding},
        ],
        order: ['chart'],
      );
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await tester.pumpWidget(_app(engine, scale: 1.3));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('$type-view-as-table')));
      await tester.pumpAndSettle();
      final rail = find.byKey(const Key('workspace-detail-rail'));
      final text = find.byKey(
        Key(type == 'line' ? 'line-table-series-0-7' : 'timeline-table-lanes-0'),
      );
      expect(find.descendant(of: rail, matching: text), findsOneWidget);
      final widget = tester.widget<Text>(text);
      expect(widget.data, contains('zulu_service_with_a_very_long_name'));
      expect(tester.renderObject<RenderParagraph>(text).didExceedMaxLines, isFalse);
      expect(tester.getSize(text).height, greaterThan(25), reason: 'long text must wrap');
      if (type == 'line') {
        expect(find.byKey(const Key('line-table-value-0-7')), findsOneWidget);
      }
      await tester.tap(find.byKey(Key('$type-table-close')));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('rail discards a stale row after an engine revision changes', (tester) async {
    _resetSurface(tester);
    _setSurface(tester, const Size(1100, 700));
    final bridge = _tableBridge();
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_app(engine, scale: 1.3));
    await tester.pumpAndSettle();
    await tester.tap(find.text('eu').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Row 1'), findsOneWidget);
    await engine.applyCommands([Commands.renameWorkspace('New title')]);
    await tester.pumpAndSettle();
    expect(find.text('Row 1'), findsNothing);
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('New title'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
