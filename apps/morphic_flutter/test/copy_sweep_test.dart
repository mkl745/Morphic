/// Empty/error copy sweep (M1.6 task 1.6.5).
///
/// Design-system §7: every empty/error surface has human language plus a next action.
/// These tests pin that contract surface by surface: the three charts offer Clear filters
/// when a filter narrowed them to nothing, the table offers Clear search and filters, the
/// metric offers Clear filters, and the workspace/home/PoC empties name the next step.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/app.dart';
import 'package:morphic_flutter/design_system/copy.dart';
import 'package:morphic_flutter/engine/bridge.dart';
import 'package:morphic_flutter/engine/bridge_scope.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';
import 'package:morphic_flutter/features/poc/poc_screen.dart';
import 'package:morphic_flutter/features/workspace/workspace_screen.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/bar_chart_view.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';
import 'package:morphic_flutter/runtime/components/line_chart_view.dart';
import 'package:morphic_flutter/runtime/components/metric_card_view.dart';
import 'package:morphic_flutter/runtime/components/timeline_view.dart';
import 'package:morphic_flutter/runtime/workspace_view.dart';

import 'support/fake_import.dart';
import 'support/scripted_bridge.dart';

// --- chart fixtures -----------------------------------------------------------

Map<String, dynamic> _barSpec() => {
      'id': 'breakdown_by_region',
      'type': 'bar_chart',
      'title': 'Average amount by region',
      'binding': {
        'kind': 'bar_chart',
        'dimension': 'region',
        'measure': {'op': 'avg', 'field': 'amount'},
        'limit': 3,
      },
      'interactions': {'filter': true, 'sort': true},
    };

ScriptedBridge _barBridge({List<List<dynamic>>? rows}) => ScriptedBridge(
      rows: rows ?? [
        ['eu', 10],
        ['us', 5],
        ['eu', 30],
        ['latam', 60],
      ],
      fields: const ['region', 'amount'],
      dtypes: const {'amount': 'int64'},
      components: [_barSpec()],
      order: const ['breakdown_by_region'],
    );

Map<String, dynamic> _lineSpec() => {
      'id': 'trend_over_time',
      'type': 'line_chart',
      'title': 'Latency over time',
      'binding': {
        'kind': 'line_chart',
        'x': 'ts',
        'y': [
          {'op': 'avg', 'field': 'latency'},
        ],
        'group_by': 'service',
      },
      'interactions': {'filter': true, 'select': true},
    };

ScriptedBridge _lineBridge({List<List<dynamic>>? rows}) => ScriptedBridge(
      rows: rows ?? [
        [0, 'api', 10],
        [60000, 'api', 20],
        [120000, 'api', 30],
        [0, 'web', 5],
        [120000, 'web', 15],
      ],
      fields: const ['ts', 'service', 'latency'],
      dtypes: const {'ts': 'timestamp', 'latency': 'float64'},
      components: [_lineSpec()],
      order: const ['trend_over_time'],
    );

Map<String, dynamic> _timelineSpec() => {
      'id': 'event_timeline',
      'type': 'timeline',
      'title': 'Events',
      'binding': {
        'kind': 'timeline',
        'time_field': 'ts',
        'severity_field': 'level',
      },
      'interactions': {'filter': true, 'select': true},
    };

ScriptedBridge _timelineBridge({List<List<dynamic>>? rows}) => ScriptedBridge(
      rows: rows ?? [
        [0, 'ERROR', 'a'],
        [0, 'INFO', 'c'],
        [60000, 'WARN', 'd'],
        [120000, 'ERROR', 'f'],
      ],
      fields: const ['ts', 'level', 'msg'],
      dtypes: const {'ts': 'timestamp'},
      components: [_timelineSpec()],
      order: const ['event_timeline'],
    );

Future<EngineController> _pumpChart(
  WidgetTester tester,
  ScriptedBridge bridge,
  Widget Function(EngineController engine) build,
) async {
  final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await engine.open('w1');
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: AnimatedBuilder(
          animation: engine,
          builder: (context, _) => build(engine),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return engine;
}

// --- failing bridges for the home/PoC retry surfaces --------------------------

/// Fails [engineInfo] until [failEngineInfo] is cleared.
class _EngineFlakyBridge extends ScriptedBridge {
  bool failEngineInfo = true;

  @override
  EngineInfo engineInfo() {
    if (failEngineInfo) {
      throw const MorphicBridgeException('engine: failed to start');
    }
    return super.engineInfo();
  }
}

/// Fails [listWorkspaces] until [failList] is cleared.
class _ListFlakyBridge extends ScriptedBridge {
  bool failList = true;

  @override
  List<dynamic> listWorkspaces(String storageRoot) {
    if (failList) {
      throw const MorphicBridgeException('store: index unreadable');
    }
    return super.listWorkspaces(storageRoot);
  }
}

/// Fails [profileCsv] until [failProfile] is cleared, so the PoC error card is
/// deterministic regardless of whether the test asset bundle loads.
class _ProfileFlakyBridge extends ScriptedBridge {
  bool failProfile = true;

  @override
  Map<String, dynamic> profileCsv(Uint8List bytes) {
    if (failProfile) {
      throw const MorphicBridgeException('profile: unreadable sample');
    }
    return super.profileCsv(bytes);
  }
}

Future<void> _pumpHome(WidgetTester tester, ScriptedBridge bridge) async {
  await tester.pumpWidget(MorphicApp(
    bridge: bridge,
    storageRoot: '/tmp/morphic-copy-test',
    fileSource: FakeFileSource(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('charts: empty-after-filter offers Clear filters', () {
    testWidgets('bar chart', (tester) async {
      final engine = await _pumpChart(tester, _barBridge(), (e) => BarChartView(
            ctx: ComponentContext(spec: e.components.first, engine: e),
          ));
      expect(find.text(MorphicCopy.noRowsMatch), findsNothing);

      await engine.applyCommands([
        Commands.setGlobalFilter(
            [filterNode('eq', field: 'region', value: 'nope')]),
      ]);
      await tester.pumpAndSettle();
      expect(find.text(MorphicCopy.noRowsMatch), findsOneWidget);
      expect(find.byKey(const Key('bar-clear-filters')), findsOneWidget);

      await tester.tap(find.byKey(const Key('bar-clear-filters')));
      await tester.pumpAndSettle();
      expect(find.text(MorphicCopy.noRowsMatch), findsNothing);
      expect(engine.globalFilters, isEmpty);
    });

    testWidgets('line chart', (tester) async {
      final engine = await _pumpChart(tester, _lineBridge(), (e) => LineChartView(
            ctx: ComponentContext(spec: e.components.first, engine: e),
          ));
      expect(find.text(MorphicCopy.noRowsMatch), findsNothing);

      await engine.applyCommands([
        Commands.setGlobalFilter(
            [filterNode('eq', field: 'service', value: 'nope')]),
      ]);
      await tester.pumpAndSettle();
      expect(find.text(MorphicCopy.noRowsMatch), findsOneWidget);
      expect(find.byKey(const Key('line-clear-filters')), findsOneWidget);

      await tester.tap(find.byKey(const Key('line-clear-filters')));
      await tester.pumpAndSettle();
      expect(find.text(MorphicCopy.noRowsMatch), findsNothing);
      expect(engine.globalFilters, isEmpty);
    });

    testWidgets('timeline', (tester) async {
      final engine =
          await _pumpChart(tester, _timelineBridge(), (e) => TimelineView(
                ctx: ComponentContext(spec: e.components.first, engine: e),
              ));
      expect(find.text('No dated rows match the current filters.'),
          findsNothing);

      await engine.applyCommands([
        Commands.setGlobalFilter(
            [filterNode('eq', field: 'level', value: 'nope')]),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('No dated rows match the current filters.'),
          findsOneWidget);
      expect(find.byKey(const Key('timeline-clear-filters')), findsOneWidget);

      await tester.tap(find.byKey(const Key('timeline-clear-filters')));
      await tester.pumpAndSettle();
      expect(find.text('No dated rows match the current filters.'),
          findsNothing);
      expect(engine.globalFilters, isEmpty);
    });

    testWidgets('an empty chart with no filters names the next step',
        (tester) async {
      await _pumpChart(tester, _barBridge(rows: []), (e) => BarChartView(
            ctx: ComponentContext(spec: e.components.first, engine: e),
          ));
      expect(find.text(MorphicCopy.noRowsMatch), findsOneWidget);
      expect(find.text(MorphicCopy.noRowsDetail), findsOneWidget);
      expect(find.byKey(const Key('bar-clear-filters')), findsNothing);
      expect(find.byKey(const Key('bar-clear-view-filters')), findsNothing);
    });

    testWidgets('bar view filters can be cleared without changing workspace filters',
        (tester) async {
      final bridge = _barBridge();
      final engine = await _pumpChart(tester, bridge, (e) => BarChartView(
            ctx: ComponentContext(spec: e.components.first, engine: e),
          ));
      final workspaceFilter = filterNode('eq', field: 'region', value: 'eu');
      await engine.applyCommands([
        Commands.setGlobalFilter([workspaceFilter]),
        Commands.setComponentFilter('breakdown_by_region',
            filterNode('eq', field: 'region', value: 'nope')),
      ]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bar-clear-filters')), findsOneWidget);
      expect(find.byKey(const Key('bar-clear-view-filters')), findsOneWidget);
      await tester.tap(find.byKey(const Key('bar-clear-view-filters')));
      await tester.pumpAndSettle();
      expect(engine.globalFilters, [workspaceFilter]);
      expect(ComponentInteraction.fromSpec(engine.components.first).filter, isNull);
      expect(bridge.commandBatches.last, [
        Commands.setComponentFilter('breakdown_by_region', null),
      ]);
      expect(find.byKey(const Key('bar-eu')), findsOneWidget);
    });

    testWidgets('line view-filter rejection is visible and retryable', (tester) async {
      final bridge = _lineBridge();
      final engine = await _pumpChart(tester, bridge, (e) => LineChartView(
            ctx: ComponentContext(spec: e.components.first, engine: e),
          ));
      await engine.applyCommands([
        Commands.setComponentFilter('trend_over_time',
            filterNode('eq', field: 'service', value: 'nope')),
      ]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('line-clear-view-filters')), findsOneWidget);
      bridge.failCommands = true;
      await tester.tap(find.byKey(const Key('line-clear-view-filters')));
      await tester.pumpAndSettle();
      expect(find.text(MorphicCopy.updateFailure), findsOneWidget);
      expect(find.textContaining(bridge.commandError), findsOneWidget);
      expect(ComponentInteraction.fromSpec(engine.components.first).filter, isNotNull);
      bridge.failCommands = false;
      await tester.tap(find.byKey(const Key('line-clear-view-filters')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('line-plot')), findsOneWidget);
      expect(ComponentInteraction.fromSpec(engine.components.first).filter, isNull);
    });

    testWidgets('timeline offers to clear a view-only filter', (tester) async {
      final bridge = _timelineBridge();
      final engine = await _pumpChart(tester, bridge, (e) => TimelineView(
            ctx: ComponentContext(spec: e.components.first, engine: e),
          ));
      await engine.applyCommands([
        Commands.setComponentFilter('event_timeline',
            filterNode('eq', field: 'level', value: 'nope')),
      ]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timeline-clear-filters')), findsNothing);
      expect(find.byKey(const Key('timeline-clear-view-filters')), findsOneWidget);
      await tester.tap(find.byKey(const Key('timeline-clear-view-filters')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timeline-plot')), findsOneWidget);
      expect(bridge.commandBatches.last, [
        Commands.setComponentFilter('event_timeline', null),
      ]);
    });

    testWidgets('empty values and undated rows give an actionable next step',
        (tester) async {
      await _pumpChart(tester, _lineBridge(rows: [
        [0, 'api', null],
      ]), (e) => LineChartView(
            ctx: ComponentContext(spec: e.components.first, engine: e),
          ));
      expect(find.text('No values in range: every bucket is empty.'), findsOneWidget);
      expect(find.text(MorphicCopy.noRowsDetail), findsOneWidget);

      await _pumpChart(tester, _timelineBridge(rows: [
        [null, 'INFO', 'undated'],
      ]), (e) => TimelineView(
            ctx: ComponentContext(spec: e.components.first, engine: e),
          ));
      expect(find.text('No dated rows match the current filters.'), findsOneWidget);
      expect(find.text(MorphicCopy.noRowsDetail), findsOneWidget);
    });
  });

  group('data table', () {
    Map<String, dynamic> tableSpec({bool search = true, bool filter = false}) => {
          'id': 'data_table',
          'type': 'data_table',
          'title': 'Data',
          'binding': {
            'kind': 'data_table',
            'columns': <String>[],
            'page_size': 2,
          },
          'interactions': {'search': search, 'filter': filter},
        };

    testWidgets('a search with no matches offers Clear search and filters',
        (tester) async {
      final bridge = ScriptedBridge(
        rows: [
          ['eu', 10, null],
          ['us', 20, 'alpha'],
        ],
        components: [tableSpec()],
        order: const ['data_table'],
      );
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: AnimatedBuilder(
              animation: engine,
              builder: (context, _) => DataTableView(
                // The spec must come from the engine document, rebuilt on every
                // notification, so persisted search state reaches the widget.
                ctx: ComponentContext(
                    spec: engine.components.first, engine: engine),
                height: 400,
                searchDebounce: Duration.zero,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('No rows match “zzzz”.'), findsOneWidget);
      expect(find.byKey(const Key('table-clear-empty')), findsOneWidget);

      await tester.tap(find.byKey(const Key('table-clear-empty')));
      await tester.pumpAndSettle();
      expect(find.text('eu'), findsOneWidget);
      expect(find.text('No rows match “zzzz”.'), findsNothing);
      expect(bridge.commandBatches.last, [Commands.setSearch('data_table', null)]);
    });

    testWidgets('a workspace filter is not mistaken for an empty dataset',
        (tester) async {
      final bridge = ScriptedBridge(
        components: [tableSpec()],
        order: const ['data_table'],
      );
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await engine.applyCommands([
        Commands.setGlobalFilter([
          filterNode('eq', field: 'region', value: 'nope'),
        ]),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: AnimatedBuilder(
              animation: engine,
              builder: (context, _) => DataTableView(
                ctx: ComponentContext(spec: engine.components.first, engine: engine),
                height: 400,
                searchDebounce: Duration.zero,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(MorphicCopy.noWorkspaceRows), findsOneWidget);
      expect(find.text('This dataset has no rows.'), findsNothing);
      expect(find.byKey(const Key('table-clear-global-filters')), findsOneWidget);
      expect(find.byKey(const Key('table-clear-empty')), findsNothing);
      await tester.tap(find.byKey(const Key('table-clear-global-filters')));
      await tester.pumpAndSettle();
      expect(engine.globalFilters, isEmpty);
      expect(bridge.commandBatches.last, [Commands.setGlobalFilter([])]);
      expect(find.text('eu'), findsOneWidget);
    });

    testWidgets('table recovery keeps workspace and view filters separate',
        (tester) async {
      final bridge = ScriptedBridge(
        components: [tableSpec()],
        order: const ['data_table'],
      );
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await engine.applyCommands([
        Commands.setGlobalFilter([
          filterNode('eq', field: 'region', value: 'eu'),
        ]),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: AnimatedBuilder(
              animation: engine,
              builder: (context, _) => DataTableView(
                ctx: ComponentContext(spec: engine.components.first, engine: engine),
                height: 400,
                searchDebounce: Duration.zero,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('table-clear-global-filters')), findsOneWidget);
      expect(find.byKey(const Key('table-clear-empty')), findsOneWidget);
      await tester.tap(find.byKey(const Key('table-clear-global-filters')));
      await tester.pumpAndSettle();
      expect(engine.globalFilters, isEmpty);
      expect(ComponentInteraction.fromSpec(engine.components.first).search, 'zzzz');
      expect(find.text('No rows match “zzzz”.'), findsOneWidget);
      expect(bridge.commandBatches.last, [Commands.setGlobalFilter([])]);
      await tester.tap(find.byKey(const Key('table-clear-empty')));
      await tester.pumpAndSettle();
      expect(ComponentInteraction.fromSpec(engine.components.first).search, isNull);
      expect(find.text('eu'), findsOneWidget);
    });

    testWidgets('clearing a rejected search preserves it and can be retried',
        (tester) async {
      final bridge = ScriptedBridge(
        components: [tableSpec()],
        order: const ['data_table'],
      );
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: AnimatedBuilder(
              animation: engine,
              builder: (context, _) => DataTableView(
                ctx: ComponentContext(spec: engine.components.first, engine: engine),
                height: 400,
                searchDebounce: Duration.zero,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();
      bridge.failCommands = true;
      await tester.tap(find.byKey(const Key('table-clear-empty')));
      await tester.pumpAndSettle();
      expect(find.text(MorphicCopy.updateFailure), findsOneWidget);
      expect(find.textContaining(bridge.commandError), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'zzzz');
      expect(ComponentInteraction.fromSpec(engine.components.first).search, 'zzzz');
      bridge.failCommands = false;
      await tester.tap(find.byKey(const Key('table-clear-empty')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      expect(find.text('eu'), findsOneWidget);
    });

    testWidgets('a filter-only table clears its view without sending a search command',
        (tester) async {
      final bridge = ScriptedBridge(
        components: [tableSpec(search: false, filter: true)],
        order: const ['data_table'],
      );
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await engine.applyCommands([
        Commands.setComponentFilter('data_table',
            filterNode('eq', field: 'region', value: 'nope')),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: AnimatedBuilder(
              animation: engine,
              builder: (context, _) => DataTableView(
                ctx: ComponentContext(spec: engine.components.first, engine: engine),
                height: 400,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('table-clear-empty')), findsOneWidget);
      await tester.tap(find.byKey(const Key('table-clear-empty')));
      await tester.pumpAndSettle();
      expect(bridge.commandBatches.last, [
        Commands.setComponentFilter('data_table', null),
      ]);
      expect(find.text('eu'), findsOneWidget);
    });

    testWidgets('a genuinely empty dataset names the next step',
        (tester) async {
      final engine = EngineController(
        bridge: ScriptedBridge(
          rows: [],
          components: [tableSpec()],
          order: const ['data_table'],
        ),
        storageRoot: '/tmp/m',
      );
      await engine.open('w1');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: DataTableView(
              ctx: ComponentContext(
                  spec: engine.components.first, engine: engine),
              height: 400,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('This dataset has no rows.'), findsOneWidget);
      expect(find.text(MorphicCopy.noTableRowsDetail), findsOneWidget);
      expect(find.byKey(const Key('table-clear-empty')), findsNothing);
    });
  });

  group('metric card', () {
    Map<String, dynamic> metricSpec() => {
          'id': 'total_records',
          'type': 'metric_card',
          'title': 'Records',
          'binding': {
            'kind': 'metric_card',
            'aggregation': {'op': 'count', 'field': null},
          },
        };

    testWidgets('a metric view filter can be cleared independently', (tester) async {
      final spec = metricSpec()..['interactions'] = {'filter': true};
      final bridge = ScriptedBridge(
        metrics: {'total_records': null},
        components: [spec],
        order: const ['total_records'],
      );
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      final workspaceFilter = filterNode('eq', field: 'region', value: 'eu');
      await engine.applyCommands([
        Commands.setGlobalFilter([workspaceFilter]),
        Commands.setComponentFilter('total_records',
            filterNode('eq', field: 'region', value: 'nope')),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnimatedBuilder(
              animation: engine,
              builder: (context, _) => MetricCardView(
                ctx: ComponentContext(spec: engine.components.first, engine: engine),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('metric-clear-filters-total_records')), findsOneWidget);
      expect(find.byKey(const Key('metric-clear-view-filters-total_records')), findsOneWidget);
      await tester.tap(find.byKey(const Key('metric-clear-view-filters-total_records')));
      await tester.pumpAndSettle();
      expect(engine.globalFilters, [workspaceFilter]);
      expect(ComponentInteraction.fromSpec(engine.components.first).filter, isNull);
      expect(bridge.commandBatches.last, [
        Commands.setComponentFilter('total_records', null),
      ]);
    });

    testWidgets('a null metric under filters offers Clear filters',
        (tester) async {
      final bridge = ScriptedBridge(metrics: {'total_records': null});
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await engine.applyCommands([
        Commands.setGlobalFilter(
            [filterNode('eq', field: 'region', value: 'eu')]),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnimatedBuilder(
              animation: engine,
              builder: (context, _) => MetricCardView(
                ctx: ComponentContext(spec: metricSpec(), engine: engine),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('No data for this metric'), findsOneWidget);
      expect(find.text(MorphicCopy.metricFiltersHint), findsOneWidget);
      expect(find.text(MorphicCopy.noRowsMatch), findsNothing,
          reason: 'a null aggregate does not prove that no rows matched');
      expect(
          find.byKey(const Key('metric-clear-filters-total_records')),
          findsOneWidget);

      await tester.tap(
          find.byKey(const Key('metric-clear-filters-total_records')));
      await tester.pumpAndSettle();
      expect(engine.globalFilters, isEmpty);
      expect(find.text(MorphicCopy.noRowsDetail), findsOneWidget);
      expect(
          find.byKey(const Key('metric-clear-filters-total_records')),
          findsNothing);
    });
  });

  group('workspace view', () {
    Widget host(Widget child) => MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(420, 900)),
            child: Scaffold(
              body: SizedBox(width: 420, height: 900, child: child),
            ),
          ),
        );

    testWidgets('no workspace open names the next step', (tester) async {
      final engine = EngineController(
          bridge: ScriptedBridge(), storageRoot: '/tmp/m');
      await tester.pumpWidget(host(WorkspaceView(
        controller: engine,
        registry: ComponentRegistry(),
      )));
      await tester.pumpAndSettle();
      expect(find.text('No workspace open.'), findsOneWidget);
      expect(find.text(MorphicCopy.noWorkspaceOpenDetail), findsOneWidget);
    });

    testWidgets('a failed open without a retry callback names the next step',
        (tester) async {
      final bridge = ScriptedBridge()..failSnapshot = true;
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await tester.pumpWidget(host(WorkspaceView(
        controller: engine,
        registry: ComponentRegistry(),
      )));
      await tester.pumpAndSettle();
      expect(find.text('Could not open this workspace'), findsOneWidget);
      expect(find.textContaining('store: not found'), findsOneWidget);
      expect(find.text(MorphicCopy.workspaceOpenFailureDetail), findsOneWidget);
    });

    testWidgets('a missing structural document does not claim data was lost',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WorkspaceScreen()));
      await tester.pumpAndSettle();
      expect(find.text('No workspace document.'), findsOneWidget);
      expect(find.text(MorphicCopy.noWorkspaceDocumentDetail), findsOneWidget);
    });

    testWidgets('no components names the next step', (tester) async {
      final engine = EngineController(
        bridge: ScriptedBridge(components: [], order: []),
        storageRoot: '/tmp/m',
      );
      await engine.open('w1');
      await tester.pumpWidget(host(WorkspaceView(
        controller: engine,
        registry: ComponentRegistry(),
      )));
      await tester.pumpAndSettle();
      expect(
          find.text('The engine generated no components for this file.'),
          findsOneWidget);
      expect(find.text(MorphicCopy.noComponentsDetail), findsOneWidget);
    });
  });

  group('home', () {
    testWidgets('an engine failure offers Try again and recovers',
        (tester) async {
      final bridge = _EngineFlakyBridge();
      await _pumpHome(tester, bridge);
      expect(find.textContaining('Engine unavailable'), findsOneWidget);
      expect(find.byKey(const Key('engine-retry-button')), findsOneWidget);

      bridge.failEngineInfo = false;
      await tester.tap(find.byKey(const Key('engine-retry-button')));
      await tester.pumpAndSettle();
      expect(find.text('Rust engine connected'), findsOneWidget);
    });

    testWidgets('a library failure offers Try again and recovers',
        (tester) async {
      final bridge = _ListFlakyBridge();
      await _pumpHome(tester, bridge);
      expect(find.textContaining('Could not load workspaces'), findsOneWidget);
      expect(find.byKey(const Key('workspaces-retry-button')), findsOneWidget);

      bridge.failList = false;
      await tester.tap(find.byKey(const Key('workspaces-retry-button')));
      await tester.pumpAndSettle();
      expect(find.text('Saved workspace'), findsOneWidget);
    });
  });

  group('proof of concept', () {
    testWidgets('a generation failure retries the import rather than profiling',
        (tester) async {
      final bridge = ScriptedBridge();
      final runner = FakeImportRunner(
        failure: const MorphicBridgeException('store: no space left'),
      );
      await tester.pumpWidget(MaterialApp(
        home: BridgeScope(
          bridge: bridge,
          storageRoot: '/tmp/m',
          importRunner: runner,
          child: const PocScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Generate workspace'));
      await tester.tap(find.text('Generate workspace'));
      await tester.pumpAndSettle();
      expect(runner.runs, 1);
      expect(find.text(MorphicCopy.sampleBuildFailureDetail), findsOneWidget);
      expect(find.textContaining('store: no space left'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('poc-retry-button')));
      await tester.tap(find.byKey(const Key('poc-retry-button')));
      await tester.pumpAndSettle();
      expect(runner.runs, 2);
      expect(find.text(MorphicCopy.sampleBuildFailureDetail), findsOneWidget);
    });

    testWidgets('a load failure offers Try again', (tester) async {
      final bridge = _ProfileFlakyBridge();
      await tester.pumpWidget(MaterialApp(
        home: BridgeScope(
          bridge: bridge,
          storageRoot: '/tmp/m',
          child: const PocScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Error:'), findsOneWidget);
      expect(find.text(MorphicCopy.sampleLoadFailureDetail), findsOneWidget);
      expect(find.byKey(const Key('poc-retry-button')), findsOneWidget);

      bridge.failProfile = false;
      await tester.tap(find.byKey(const Key('poc-retry-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Error:'), findsNothing);
    });
  });
}
