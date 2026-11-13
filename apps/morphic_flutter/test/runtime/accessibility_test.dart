/// Representative host-side accessibility contracts. These tests exercise Flutter's semantics
/// tree, but do not replace a TalkBack pass or establish the complete AT-18 device matrix.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';

import '../support/scripted_bridge.dart';

void _surface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ScriptedBridge _tableBridge({bool canSort = true}) => ScriptedBridge(
      fields: const ['region', 'amount', 'note'],
      dtypes: const {'amount': 'int64'},
      rows: const [
        ['eu', 10, null],
        ['us', 20, ''],
        ['apac', 30, 'beta'],
        ['latam', 40, 'gamma'],
      ],
      components: [
        {
          'id': 'data_table',
          'type': 'data_table',
          'title': 'Data',
          'binding': {'kind': 'data_table', 'columns': <String>[], 'page_size': 2},
          'interactions': {'search': true, 'sort': canSort, 'filter': true},
        },
      ],
      order: const ['data_table'],
    );

Future<EngineController> _pumpTable(
  WidgetTester tester,
  ScriptedBridge bridge, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  Size size = const Size(800, 800),
}) async {
  _surface(tester, size);
  final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await engine.open('w1');
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.dark ? MorphicTheme.dark() : MorphicTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: size.width - 32,
          child: AnimatedBuilder(
            animation: engine,
            builder: (context, _) => DataTableView(
              ctx: ComponentContext(spec: engine.components.first, engine: engine),
              height: 500,
              searchDebounce: Duration.zero,
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return engine;
}

FocusNode _innerFocus(WidgetTester tester, String key) {
  final focus = find.descendant(of: find.byKey(Key(key)), matching: find.byType(Focus)).first;
  // Focus's State is private. An element below the focus inherits its actual FocusNode.
  final child = find.descendant(of: focus, matching: find.byType(MouseRegion)).first;
  return Focus.of(tester.element(child));
}

Map<String, dynamic> _chartSpec(String type) => {
      'id': 'chart',
      'type': type,
      'title': 'Events',
      'binding': switch (type) {
        'line_chart' => {
            'kind': 'line_chart',
            'x': 'ts',
            'y': [
              {'op': 'avg', 'field': 'value'},
            ],
            'group_by': 'group',
          },
        'timeline' => {'kind': 'timeline', 'time_field': 'ts', 'severity_field': 'group'},
        _ => {
            'kind': 'bar_chart',
            'dimension': 'group',
            'measure': {'op': 'avg', 'field': 'value'},
            'limit': 5,
          },
      },
      'interactions': {'filter': true, 'sort': true, 'select': true},
    };

ScriptedBridge _chartBridge(String type) => ScriptedBridge(
      fields: const ['ts', 'group', 'value'],
      dtypes: const {'ts': 'timestamp', 'value': 'float64'},
      rows: const [
        [0, 'api', 10],
        [0, 'web', 5],
        [60000, 'api', 20],
        [120000, 'api', 30],
        [120000, 'web', 15],
      ],
      components: [_chartSpec(type)],
      order: const ['chart'],
    );

Future<EngineController> _pumpChart(
  WidgetTester tester,
  String type, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) async {
  _surface(tester, const Size(800, 1000));
  final bridge = _chartBridge(type);
  final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await engine.open('w1');
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.dark ? MorphicTheme.dark() : MorphicTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: AnimatedBuilder(
              animation: engine,
              builder: (context, _) => ComponentRegistry().build(
                ComponentContext(spec: engine.components.first, engine: engine),
              ),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return engine;
}

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('table targets and labels: $brightness at ${scale}x', (tester) async {
        await _pumpTable(tester, _tableBridge(), brightness: brightness, scale: scale);

        for (final key in ['sort-region', 'filter-region', 'table-row-1', 'table-next-page']) {
          final size = tester.getSize(find.byKey(Key(key)));
          expect(size.width, greaterThanOrEqualTo(48), reason: key);
          expect(size.height, greaterThanOrEqualTo(48), reason: key);
        }
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      });
    }
  }

  testWidgets('row, headers and pager expose one meaningful action in reading order', (tester) async {
    final bridge = _tableBridge();
    await _pumpTable(tester, bridge);

    final first = find.semantics.byLabel('Row 1: region: eu, amount: 10, note: No value');
    final second = find.semantics.byLabel('Row 2: region: us, amount: 20, note: Empty string');
    expect(first, findsOne);
    expect(second, findsOne);
    expect(first.evaluate().single.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    expect(find.semantics.byLabel('eu'), findsNothing, reason: 'cells are not duplicate actions');
    final labels = tester.semantics.simulatedAccessibilityTraversal().map((node) => node.label);
    expect(labels, containsAllInOrder([
      'Column region, Not sorted',
      'Filter region',
      'Column amount, Not sorted',
      'Filter amount',
      'Row 1: region: eu, amount: 10, note: No value',
      'Row 2: region: us, amount: 20, note: Empty string',
      '1–2 of 4',
      'Next page',
    ]));

    tester.semantics.tap(first);
    await tester.pumpAndSettle();
    expect(find.text('Row 1'), findsOneWidget);
    expect(find.text('No value (null)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('row-detail-close')));
    await tester.pumpAndSettle();

    tester.semantics.tap(find.semantics.byLabel('Next page'));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel('Row 3: region: apac, amount: 30, note: beta'), findsOne);
    expect(find.semantics.byLabel('3–4 of 4'), findsOne);
    expect(bridge.pageCalls.last['offset'], 2);
  });

  testWidgets('header semantics sort and expose field correction as a long press', (tester) async {
    final bridge = _tableBridge();
    await _pumpTable(tester, bridge);
    final header = find.semantics.byLabel('Column amount, Not sorted');
    final data = header.evaluate().single.getSemanticsData();
    expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
    expect(data.hasAction(ui.SemanticsAction.longPress), isTrue);
    tester.semantics.longPress(header);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('field-corrections-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('field-correction-close')));
    await tester.pumpAndSettle();
    tester.semantics.tap(find.semantics.byLabel('Column amount, Not sorted'));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel('Column amount, Sorted ascending'), findsOne);
    expect(bridge.commandBatches.last.single['kind'], 'setComponentSort');
  });

  testWidgets('keyboard traverses table controls and can open row and correction', (tester) async {
    await _pumpTable(tester, _tableBridge());
    final order = [
      'sort-region', 'filter-region', 'sort-amount', 'filter-amount',
      'sort-note', 'filter-note', 'table-row-1', 'table-row-2', 'table-next-page',
    ];
    _innerFocus(tester, order.first).requestFocus();
    await tester.pump();
    for (var i = 0; i < order.length; i++) {
      expect(_innerFocus(tester, order[i]).hasPrimaryFocus, isTrue, reason: order[i]);
      if (i != order.length - 1) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('3–4 of 4'), findsOneWidget);

    _innerFocus(tester, 'table-row-3').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Row 3'), findsOneWidget);
    await tester.tap(find.byKey(const Key('row-detail-close')));
    await tester.pumpAndSettle();

    _innerFocus(tester, 'sort-amount').requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('field-corrections-sheet')), findsOneWidget);
  });

  testWidgets('a non-sortable header still offers semantic and keyboard field correction',
      (tester) async {
    await _pumpTable(tester, _tableBridge(canSort: false));
    final header = find.semantics.byLabel('Column region');
    final data = header.evaluate().single.getSemanticsData();
    expect(data.hasAction(ui.SemanticsAction.tap), isFalse);
    expect(data.hasAction(ui.SemanticsAction.longPress), isTrue);
    _innerFocus(tester, 'sort-region').requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('field-corrections-sheet')), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final type in ['line_chart', 'timeline']) {
      testWidgets('$type legend reports visibility and text contrast in $brightness', (tester) async {
        await _pumpChart(tester, type, brightness: brightness, scale: 1.3);
        final prefix = type == 'line_chart' ? 'line' : 'timeline';
        final suffix = type == 'line_chart' ? 'series' : 'lane';
        final semantic = find.semantics.byLabel('api $suffix');
        expect(semantic, findsOne);
        expect(semantic.evaluate().single.getSemanticsData().value, 'Visible');
        final size = tester.getSize(find.byKey(Key('$prefix-legend-api')));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        tester.semantics.tap(semantic);
        await tester.pumpAndSettle();
        expect(semantic.evaluate().single.getSemanticsData().value, 'Hidden');
        final text = tester.widget<Text>(find.descendant(
          of: find.byKey(Key('$prefix-legend-api')),
          matching: find.text('api'),
        ));
        final surface = brightness == Brightness.dark
            ? MorphicColors.surfaceDark
            : MorphicColors.surfaceLight;
        expect(_contrast(text.style!.color!, surface), greaterThanOrEqualTo(4.5));
        tester.semantics.tap(semantic);
        await tester.pumpAndSettle();
        expect(semantic.evaluate().single.getSemanticsData().value, 'Visible');
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      });
    }
  }

  testWidgets('line plot exposes actual semantic adjustment and keyboard bucket values', (tester) async {
    await _pumpChart(tester, 'line_chart');
    final plot = find.semantics.byLabel(RegExp('^Line chart of ts'));
    var data = plot.evaluate().single.getSemanticsData();
    expect(data.value, 'No bucket selected');
    expect(data.hasAction(ui.SemanticsAction.increase), isTrue);
    expect(data.hasAction(ui.SemanticsAction.decrease), isTrue);
    expect(data.hasAction(ui.SemanticsAction.tap), isFalse,
        reason: 'a synthetic center tap is not a meaningful bucket choice');
    tester.semantics.increase(plot);
    await tester.pumpAndSettle();
    data = plot.evaluate().single.getSemanticsData();
    expect(data.value, contains('Bucket 1 of 3'));
    expect(data.value, contains('api 10'));
    expect(data.value, contains('web 5'));
    tester.semantics.increase(plot);
    await tester.pumpAndSettle();
    expect(plot.evaluate().single.getSemanticsData().value, contains('web no value'));
    Focus.of(tester.element(find.byKey(const Key('line-plot')))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(plot.evaluate().single.getSemanticsData().value, contains('Bucket 1 of 3'));
  });

  testWidgets('timeline previews a middle bucket, applies and clears through semantics',
      (tester) async {
    final engine = await _pumpChart(tester, 'timeline');
    final plot = find.semantics.byLabel(RegExp('^Timeline of ts'));
    expect(plot.evaluate().single.getSemanticsData().value, 'No bucket selected');
    tester.semantics.increase(plot);
    await tester.pumpAndSettle();
    tester.semantics.increase(plot);
    await tester.pumpAndSettle();
    expect(engine.globalFilters, isEmpty, reason: 'preview must not narrow the data');
    expect(plot.evaluate().single.getSemanticsData().value, contains('00:01 UTC'));
    expect(find.text('Preview — not filtering the workspace'), findsOneWidget);
    tester.semantics.tap(plot);
    await tester.pumpAndSettle();
    final args = engine.globalFilters.single['args'] as List;
    expect(args[0], {'op': 'gte', 'field': 'ts', 'value': 60000});
    expect(args[1], {'op': 'lt', 'field': 'ts', 'value': 120000});
    expect(plot.evaluate().single.getSemanticsData().value, contains('Filtering to'));
    tester.semantics.tap(plot);
    await tester.pumpAndSettle();
    expect(engine.globalFilters, isEmpty);
  });

  testWidgets('timeline keyboard can preview, apply and clear a bucket', (tester) async {
    final engine = await _pumpChart(tester, 'timeline');
    final focus = Focus.of(tester.element(find.byKey(const Key('timeline-plot'))));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(engine.globalFilters, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect((engine.globalFilters.single['args'] as List)[0]['value'], 60000);
    expect(focus.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(engine.globalFilters, isEmpty);
  });

  testWidgets('bar summary and filtering are exposed as semantic actions', (tester) async {
    final engine = await _pumpChart(tester, 'bar_chart');
    expect(find.semantics.byLabel(RegExp('Bar chart of')), findsOne);
    final bar = find.semantics.byLabel(RegExp('^api,'));
    expect(bar, findsOne);
    expect(bar.evaluate().single.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    expect(tester.getSize(find.byKey(const Key('bar-api'))).height, greaterThanOrEqualTo(48));
    tester.semantics.tap(bar);
    await tester.pumpAndSettle();
    expect(engine.globalFilters.single, {'op': 'eq', 'field': 'group', 'value': 'api'});
  });
}
