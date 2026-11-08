/// Widget tests for the bar-chart renderer (M1.4 task 1.4.2).
///
/// The bar chart is a control as much as a picture: tapping a bar has to move the whole
/// workspace, and the numbers it shows must be the engine's. These tests assert both, plus the
/// two shapes that are easy to get wrong — the null category and the remainder bucket.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/chart_scene.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/bar_chart_painter.dart';
import 'package:morphic_flutter/runtime/components/bar_chart_view.dart';

import '../support/scripted_bridge.dart';

Map<String, dynamic> _spec({
  int limit = 3,
  bool canFilter = true,
  bool canSort = true,
  String op = 'avg',
}) =>
    {
      'id': 'breakdown_by_region',
      'type': 'bar_chart',
      'title': 'Average amount by region',
      'binding': {
        'kind': 'bar_chart',
        'dimension': 'region',
        'measure': {'op': op, 'field': 'amount'},
        'limit': limit,
      },
      'interactions': {'filter': canFilter, 'sort': canSort},
    };

/// latam 60, eu 20 (2 rows), us 5, apac 1 — four categories so a limit of 3 leaves a remainder.
List<List<dynamic>> _rows({bool withNull = false}) => [
      ['eu', 10],
      ['us', 5],
      ['eu', 30],
      ['latam', 60],
      ['apac', 1],
      if (withNull) [null, 99],
    ];

ScriptedBridge _bridge({
  int limit = 3,
  bool canFilter = true,
  bool canSort = true,
  bool withNull = false,
  List<List<dynamic>>? rows,
}) =>
    ScriptedBridge(
      rows: rows ?? _rows(withNull: withNull),
      fields: const ['region', 'amount'],
      dtypes: const {'amount': 'int64'},
      components: [_spec(limit: limit, canFilter: canFilter, canSort: canSort)],
      order: const ['breakdown_by_region'],
    );

Future<EngineController> _pump(WidgetTester tester, ScriptedBridge bridge) async {
  final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await engine.open('w1');
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: AnimatedBuilder(
          animation: engine,
          builder: (context, _) => BarChartView(
            ctx: ComponentContext(
              spec: engine.components.first,
              engine: engine,
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return engine;
}

List<Map<String, dynamic>> _lastGlobalFilters(ScriptedBridge bridge) {
  final batch = bridge.commandBatches.last;
  final cmd = batch.firstWhere((c) => c['kind'] == 'setGlobalFilter');
  return (cmd['filters'] as List).whereType<Map<String, dynamic>>().toList();
}

/// Computes each chart read eagerly, then holds delivery on a gate — the only way to observe
/// a response from a revision the workspace has already left.
class _GatedChartController extends EngineController {
  _GatedChartController({required super.bridge, required super.storageRoot});

  final List<Completer<void>> _gates = [];

  Completer<void> holdNext() {
    final gate = Completer<void>();
    _gates.add(gate);
    return gate;
  }

  @override
  Future<ChartResult?> chartData(String componentId) async {
    final result = await super.chartData(componentId);
    if (_gates.isNotEmpty) await _gates.removeAt(0).future;
    return result;
  }
}

void main() {
  testWidgets('draws the engine scene and asks the engine for it', (tester) async {
    final bridge = _bridge();
    await _pump(tester, bridge);
    expect(bridge.chartCalls, ['breakdown_by_region']);
    expect(find.text('Average amount by region'), findsOneWidget);
    expect(find.byKey(const Key('bar-latam')), findsOneWidget);
    expect(find.byKey(const Key('bar-eu')), findsOneWidget);
    expect(find.byKey(const Key('bar-other-bucket')), findsOneWidget);
    // apac is the smallest and fell outside the limit of three.
    expect(find.byKey(const Key('bar-apac')), findsNothing);
  });

  testWidgets('tapping a bar filters the workspace, tapping again restores it',
      (tester) async {
    final bridge = _bridge();
    final engine = await _pump(tester, bridge);
    await tester.tap(find.byKey(const Key('bar-eu')));
    await tester.pumpAndSettle();
    expect(_lastGlobalFilters(bridge), [
      {'op': 'eq', 'field': 'region', 'value': 'eu'},
    ]);
    expect(engine.globalFilters.length, 1);

    await tester.tap(find.byKey(const Key('bar-eu')));
    await tester.pumpAndSettle();
    expect(_lastGlobalFilters(bridge), isEmpty);
    expect(engine.globalFilters, isEmpty);
  });

  testWidgets('a bar filter composes with one already set on another field',
      (tester) async {
    final bridge = _bridge();
    final engine = await _pump(tester, bridge);
    await engine.applyCommands([
      Commands.setGlobalFilter([
        filterNode('gt', field: 'amount', value: 1),
      ]),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bar-latam')));
    await tester.pumpAndSettle();
    expect(_lastGlobalFilters(bridge).length, 2,
        reason: 'a bar tap adds to the set, it does not replace it');
  });

  testWidgets('the null category filters with is_null, not equals empty string',
      (tester) async {
    final bridge = _bridge(withNull: true, limit: 5);
    await _pump(tester, bridge);
    expect(find.byKey(const Key('bar-$kNullCategoryLabel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bar-$kNullCategoryLabel')));
    await tester.pumpAndSettle();
    expect(_lastGlobalFilters(bridge), [
      {'op': 'is_null', 'field': 'region'},
    ]);
  });

  testWidgets('Other filters to exactly the rows outside the kept bars',
      (tester) async {
    final bridge = _bridge(limit: 3);
    await _pump(tester, bridge);
    await tester.tap(find.byKey(const Key('bar-other-bucket')));
    await tester.pumpAndSettle();
    final filters = _lastGlobalFilters(bridge);
    expect(filters.single['op'], 'not');
    final inner = (filters.single['args'] as List).single as Map<String, dynamic>;
    expect(inner['op'], 'in');
    expect(inner['field'], 'region');
    expect(inner['value'], ['latam', 'eu', 'us']);
  });

  testWidgets('the null group travels with Other when it was cut', (tester) async {
    // Selection sorts nulls last, so whenever a remainder exists the null category is inside
    // it. `not(in(kept))` must therefore bring the null rows back, not silently drop them.
    final bridge = _bridge(withNull: true, limit: 3);
    await _pump(tester, bridge);
    expect(find.byKey(const Key('bar-$kNullCategoryLabel')), findsNothing);
    expect(find.byKey(const Key('bar-other-bucket')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bar-other-bucket')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bar-$kNullCategoryLabel')), findsOneWidget,
        reason: 'the null rows were folded into Other and must come back with it');
    expect(find.byKey(const Key('bar-apac')), findsOneWidget);
    expect(find.byKey(const Key('bar-latam')), findsNothing);
  });

  testWidgets('the sort toggle persists a command instead of reordering in Dart',
      (tester) async {
    final bridge = _bridge();
    await _pump(tester, bridge);
    await tester.tap(find.byKey(const Key('bar-sort-toggle')));
    await tester.pumpAndSettle();
    final cmd = bridge.commandBatches.last.single;
    expect(cmd['kind'], 'setComponentSort');
    expect(cmd['componentId'], 'breakdown_by_region');
    expect((cmd['sort'] as List).single, {
      'field': 'region',
      'dir': 'asc',
      'nulls': 'last',
    });
    // And back: clearing returns to the engine's default, largest first.
    await tester.tap(find.byKey(const Key('bar-sort-toggle')));
    await tester.pumpAndSettle();
    expect(bridge.commandBatches.last.single['sort'], isEmpty);
  });

  testWidgets('a label sort reorders the bars on screen', (tester) async {
    final engine = await _pump(tester, _bridge(limit: 5));
    double topOf(String label) =>
        tester.getTopLeft(find.byKey(Key('bar-$label'))).dy;
    // Default: largest first.
    expect(topOf('latam'), lessThan(topOf('eu')));
    expect(topOf('eu'), lessThan(topOf('apac')));

    await engine.applyCommands([
      Commands.setComponentSort('breakdown_by_region', const [
        SortRule(field: 'region'),
      ]),
    ]);
    await tester.pumpAndSettle();
    expect(topOf('apac'), lessThan(topOf('eu')));
    expect(topOf('eu'), lessThan(topOf('latam')));
    expect(topOf('latam'), lessThan(topOf('us')));
  });

  testWidgets('a label sort never changes which bars were selected', (tester) async {
    // The engine selects top N by measure and only then reorders. Sorting before the cut would
    // keep apac and eu and silently drop latam, the largest bar in the data.
    final engine = await _pump(tester, _bridge(limit: 2));
    expect(find.byKey(const Key('bar-latam')), findsOneWidget);
    expect(find.byKey(const Key('bar-apac')), findsNothing);
    await engine.applyCommands([
      Commands.setComponentSort('breakdown_by_region', const [
        SortRule(field: 'region'),
      ]),
    ]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bar-latam')), findsOneWidget,
        reason: 'the largest bar must survive a label sort');
    expect(find.byKey(const Key('bar-apac')), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const Key('bar-eu'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('bar-latam'))).dy),
    );
  });

  testWidgets('tapping Other narrows the chart to the folded categories', (tester) async {
    await _pump(tester, _bridge(limit: 3));
    await tester.tap(find.byKey(const Key('bar-other-bucket')));
    await tester.pumpAndSettle();
    // Only apac was folded into Other, so it is the only category left standing.
    expect(find.byKey(const Key('bar-apac')), findsOneWidget);
    expect(find.byKey(const Key('bar-latam')), findsNothing);
    expect(find.byKey(const Key('bar-eu')), findsNothing);
  });

  testWidgets('a partial scene states what is missing', (tester) async {
    final bridge = _bridge()..chartTruncated = true;
    await _pump(tester, bridge);
    expect(find.byKey(const Key('bar-partial-notice')), findsOneWidget);
    expect(find.textContaining('Too many categories'), findsOneWidget);
  });

  testWidgets('a complete scene shows no partial warning', (tester) async {
    await _pump(tester, _bridge());
    expect(find.byKey(const Key('bar-partial-notice')), findsNothing);
  });

  testWidgets('a real category named Other does not collide with the bucket',
      (tester) async {
    // Both would key on 'bar-Other' and Flutter throws on duplicate sibling keys.
    await _pump(
      tester,
      _bridge(limit: 2, rows: [
        ['Other', 500],
        ['eu', 100],
        ['apac', 1],
      ]),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('bar-Other')), findsOneWidget);
    expect(find.byKey(const Key('bar-other-bucket')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bar-Other')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bar-eu')), findsNothing,
        reason: 'tapping the real Other category must filter to it, not to the remainder');
  });

  testWidgets('the summary names the largest bar, not the first one drawn',
      (tester) async {
    final handle = tester.ensureSemantics();
    final engine = await _pump(tester, _bridge(limit: 5));
    await engine.applyCommands([
      Commands.setComponentSort('breakdown_by_region', const [
        SortRule(field: 'region'),
      ]),
    ]);
    await tester.pumpAndSettle();
    // apac is drawn first under a label sort but is the smallest bar in the data.
    expect(
      tester.getTopLeft(find.byKey(const Key('bar-apac'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('bar-latam'))).dy),
    );
    expect(find.bySemanticsLabel(RegExp(r'Largest latam\.')), findsOneWidget);
    handle.dispose();
  });

  test('every colour the painter puts on a surface clears its contrast floor', () {
    // Goldens cannot check this: the test font draws boxes, and a pixel diff would not tell a
    // reviewer that a bar is unreadable. WCAG 1.4.11 wants 3:1 for a meaningful graphic and
    // 1.4.3 wants 4.5:1 for the labels drawn beside it.
    double luminance(Color c) {
      double lin(double v) =>
          v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    double contrast(Color a, Color b) {
      final l1 = luminance(a);
      final l2 = luminance(b);
      return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
    }

    for (final pair in [
      ('dark bar', MorphicColors.accent, MorphicColors.surfaceDark, 3.0),
      ('dark other', MorphicColors.info, MorphicColors.surfaceDark, 3.0),
      ('light bar', MorphicColors.accentDark, MorphicColors.surfaceLight, 3.0),
      ('light other', MorphicColors.infoDark, MorphicColors.surfaceLight, 3.0),
      ('dark label', MorphicColors.textPrimaryDark, MorphicColors.surfaceDark, 4.5),
      ('light label', MorphicColors.textPrimaryLight, MorphicColors.surfaceLight, 4.5),
      ('dark value', MorphicColors.textSecondaryDark, MorphicColors.surfaceDark, 4.5),
      ('light value', MorphicColors.textSecondaryLight, MorphicColors.surfaceLight, 4.5),
    ]) {
      final (name, fg, bg, floor) = pair;
      expect(contrast(fg, bg), greaterThanOrEqualTo(floor), reason: name);
    }
  });

  testWidgets('a non-filterable chart draws bars but does not filter', (tester) async {
    final bridge = _bridge(canFilter: false);
    await _pump(tester, bridge);
    await tester.tap(find.byKey(const Key('bar-eu')));
    await tester.pumpAndSettle();
    expect(bridge.commandBatches, isEmpty);
  });

  testWidgets('a non-sortable chart hides the sort control', (tester) async {
    await _pump(tester, _bridge(canSort: false));
    expect(find.byKey(const Key('bar-sort-toggle')), findsNothing);
  });

  testWidgets('View as table shows the same aggregates, including Other',
      (tester) async {
    await _pump(tester, _bridge());
    await tester.tap(find.byKey(const Key('bar-view-as-table')));
    await tester.pumpAndSettle();
    expect(find.text('Rows'), findsOneWidget);
    expect(find.text('latam'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    // eu is 10 and 30 -> 20; the sheet must show the engine's number, not a recomputed one.
    expect(find.text('20'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bar-table-close')));
    await tester.pumpAndSettle();
    expect(find.text('Rows'), findsNothing);
  });

  testWidgets('an empty selection says so instead of drawing an empty canvas',
      (tester) async {
    await _pump(tester, _bridge(rows: []));
    expect(find.text('No rows match the current filters.'), findsOneWidget);
  });

  testWidgets('a failed read offers a retry that works', (tester) async {
    final bridge = _bridge()..failChart = true;
    await _pump(tester, bridge);
    expect(find.byKey(const Key('bar-retry')), findsOneWidget);
    expect(find.textContaining('not a chart'), findsOneWidget);
    expect(find.byKey(const Key('bar-eu')), findsNothing);

    bridge.failChart = false;
    await tester.tap(find.byKey(const Key('bar-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bar-retry')), findsNothing);
    expect(find.byKey(const Key('bar-eu')), findsOneWidget);
  });

  testWidgets('the chart carries a spoken summary and per-bar semantics',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _bridge());
    expect(
      find.bySemanticsLabel(RegExp(r'Bar chart of avg_amount by region')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp(r'eu, 20, 2 rows')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the active bar says it is filtering the workspace', (tester) async {
    final handle = tester.ensureSemantics();
    final engine = await _pump(tester, _bridge());
    await engine.applyCommands([
      Commands.setGlobalFilter([
        filterNode('eq', field: 'region', value: 'eu'),
      ]),
    ]);
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(RegExp(r'eu, .*filtering the workspace')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('a response from a superseded revision is discarded and re-read',
      (tester) async {
    // Hosted on a pinned context so no rebuild-driven refetch can mask the guard: the only
    // thing that can save this chart is the captured-revision check (task 1.3.5).
    final bridge = _bridge();
    final engine = _GatedChartController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    final ctx = ComponentContext(spec: engine.components.first, engine: engine);
    final slow = engine.holdNext();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: BarChartView(ctx: ctx)),
    ));
    await tester.pump();
    expect(bridge.chartCalls.length, 1);

    // The document moves on while that first read is still in flight.
    await engine.applyCommands([
      Commands.setGlobalFilter([
        filterNode('eq', field: 'region', value: 'eu'),
      ]),
    ]);
    slow.complete();
    await tester.pumpAndSettle();

    expect(bridge.chartCalls.length, greaterThanOrEqualTo(2),
        reason: 'the stale scene must be discarded and the chart re-read');
    expect(find.byKey(const Key('bar-eu')), findsOneWidget);
    expect(find.byKey(const Key('bar-latam')), findsNothing,
        reason: 'latam is filtered out; painting it would be a torn frame');
  });
}