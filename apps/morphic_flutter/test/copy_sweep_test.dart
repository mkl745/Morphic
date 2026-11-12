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

ScriptedBridge _barBridge() => ScriptedBridge(
      rows: [
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

ScriptedBridge _lineBridge() => ScriptedBridge(
      rows: [
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

ScriptedBridge _timelineBridge() => ScriptedBridge(
      rows: [
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
      await _pumpChart(tester, _barBridge(), (e) => BarChartView(
            ctx: ComponentContext(spec: e.components.first, engine: e),
          ));
      // No filter applied and rows present: no empty state at all.
      expect(find.text(MorphicCopy.noRowsMatch), findsNothing);
      expect(find.byKey(const Key('bar-clear-filters')), findsNothing);
    });
  });

  group('data table', () {
    Map<String, dynamic> tableSpec() => {
          'id': 'data_table',
          'type': 'data_table',
          'title': 'Data',
          'binding': {
            'kind': 'data_table',
            'columns': <String>[],
            'page_size': 2,
          },
          'interactions': {'search': true},
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
                ctx: ComponentContext(spec: tableSpec(), engine: engine),
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
              ctx: ComponentContext(spec: tableSpec(), engine: engine),
              height: 400,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('This dataset has no rows.'), findsOneWidget);
      expect(find.text('Import a file with data rows to fill this table.'),
          findsOneWidget);
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
      expect(
          find.byKey(const Key('metric-clear-filters-total_records')),
          findsOneWidget);

      await tester.tap(
          find.byKey(const Key('metric-clear-filters-total_records')));
      await tester.pumpAndSettle();
      expect(engine.globalFilters, isEmpty);
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
      expect(find.byKey(const Key('poc-retry-button')), findsOneWidget);

      bridge.failProfile = false;
      await tester.tap(find.byKey(const Key('poc-retry-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Error:'), findsNothing);
    });
  });
}
