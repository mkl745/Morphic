/// Global filters and tap-to-filter (M1.3 task 1.3.4).
///
/// The point of these tests is the *intersection*: one command must move the table and the
/// card together, and clearing must restore the exact prior aggregate (AT-06). They assert the
/// recorded command as well as the pixels, because a bar that patched a local list would look
/// identical until a second component disagreed with it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';
import 'package:morphic_flutter/runtime/components/metric_card_view.dart';
import 'package:morphic_flutter/runtime/global_filter_bar.dart';

import '../support/scripted_bridge.dart';

const _rows = [
  ['eu', 10, null],
  ['us', 20, 'alpha'],
  ['eu', 30, 'beta'],
  ['latam', 40, null],
];

Map<String, dynamic> _table({Map<String, dynamic>? state}) => {
      'id': 'data_table',
      'type': 'data_table',
      'title': 'Data',
      'binding': {
        'kind': 'data_table',
        'columns': <String>[],
        'page_size': 10,
      },
      'interactions': {'search': true, 'sort': true, 'filter': true},
      if (state != null) 'state': state,
    };

Map<String, dynamic> _card({
  String id = 'records',
  String op = 'count',
  String? field,
  Map<String, dynamic>? filter,
  bool canFilter = true,
}) =>
    {
      'id': id,
      'type': 'metric_card',
      'title': id,
      'binding': {
        'kind': 'metric_card',
        'aggregation': {'op': op, 'field': field, if (filter != null) 'filter': filter},
      },
      'interactions': {'filter': canFilter},
    };

ScriptedBridge _bridge({List<Map<String, dynamic>>? components}) => ScriptedBridge(
      rows: List.of(_rows),
      dtypes: const {'amount': 'int64'},
      components: components ?? [_card(), _table()],
      order: [for (final c in components ?? [_card(), _table()]) c['id'] as String],
    )..computeMetrics = true;

Future<EngineController> _open(ScriptedBridge b) async {
  final c = EngineController(bridge: b, storageRoot: '/tmp/m');
  await c.open('w1');
  return c;
}

/// Hosts the bar, the cards and the table together, rebuilt from the document on every
/// notification — the same wiring `WorkspaceScreen` uses.
Future<void> _pump(WidgetTester tester, EngineController engine) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: AnimatedBuilder(
          animation: engine,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlobalFilterBar(engine: engine),
              for (final spec in engine.components)
                if (spec['type'] == 'metric_card')
                  MetricCardView(ctx: ComponentContext(spec: spec, engine: engine))
                else
                  DataTableView(
                    ctx: ComponentContext(spec: spec, engine: engine),
                    height: 300,
                    searchDebounce: Duration.zero,
                  ),
            ],
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Adds a workspace filter through the menu: field, operator, bound, Apply.
Future<void> _addFilter(
  WidgetTester tester, {
  required String field,
  required String operator,
  required String bound,
  bool edit = false,
}) async {
  await tester.tap(
      edit ? find.byKey(const Key('global-filter-0')) : find.byKey(const Key('global-filter-add')));
  await tester.pumpAndSettle();
  if (field != 'region') {
    await tester.tap(find.byKey(const Key('filter-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(field).last);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const Key('filter-operator')));
  await tester.pumpAndSettle();
  final op = find.text(operator).last;
  await tester.ensureVisible(op);
  await tester.pumpAndSettle();
  await tester.tap(op);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('filter-value')), bound);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('filter-apply')));
  await tester.pumpAndSettle();
}

List<Map<String, dynamic>> _lastSet(ScriptedBridge b) =>
    (b.commandBatches.last.single['filters'] as List).cast<Map<String, dynamic>>();

void main() {
  group('the bar', () {
    testWidgets('starts empty and offers to filter the workspace', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      expect(find.text('Filter workspace'), findsOneWidget);
      expect(find.byKey(const Key('global-filter-0')), findsNothing);
      expect(find.byKey(const Key('global-filter-clear')), findsNothing);
      expect(bridge.commandBatches, isEmpty);
    });

    testWidgets('adding sends the whole set, not a patch', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'eu');
      expect(bridge.commandBatches.last.single['kind'], 'setGlobalFilter');
      expect(_lastSet(bridge), [
        {'op': 'eq', 'field': 'region', 'value': 'eu'},
      ]);
      expect(find.text('region = eu'), findsOneWidget);
      expect(find.text('Applied to every component in this workspace.'), findsOneWidget);
    });

    testWidgets('a second filter arrives as a set of two', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'eu');
      await _addFilter(tester, field: 'amount', operator: 'Greater than', bound: '10');
      expect(_lastSet(bridge), [
        {'op': 'eq', 'field': 'region', 'value': 'eu'},
        {'op': 'gt', 'field': 'amount', 'value': 10},
      ]);
      expect(find.text('region = eu'), findsOneWidget);
      expect(find.text('amount > 10'), findsOneWidget);
    });

    testWidgets('the field picker changes which operators are offered', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('global-filter-add')));
      await tester.pumpAndSettle();
      expect(find.text('Filter the whole workspace'), findsOneWidget);
      await tester.tap(find.byKey(const Key('filter-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('amount').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-operator')));
      await tester.pumpAndSettle();
      expect(find.text('Greater than'), findsWidgets);
      expect(find.text('Contains'), findsNothing);
    });

    testWidgets('editing a chip replaces it in place', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'eu');
      await _addFilter(tester, field: 'amount', operator: 'Greater than', bound: '10');
      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'us', edit: true);
      expect(_lastSet(bridge), [
        {'op': 'eq', 'field': 'region', 'value': 'us'},
        {'op': 'gt', 'field': 'amount', 'value': 10},
      ]);
    });

    testWidgets('deleting a chip sends the set without it', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'eu');
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(_lastSet(bridge), isEmpty);
      expect(find.byKey(const Key('global-filter-0')), findsNothing);
    });

    testWidgets('clear all is one command with an empty set', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'eu');
      await _addFilter(tester, field: 'amount', operator: 'Greater than', bound: '10');
      final before = bridge.commandBatches.length;
      await tester.tap(find.byKey(const Key('global-filter-clear')));
      await tester.pumpAndSettle();
      expect(bridge.commandBatches.length, before + 1);
      expect(bridge.commandBatches.last.single,
          {'kind': 'setGlobalFilter', 'filters': <Map<String, dynamic>>[]});
      expect(find.text('Filter workspace'), findsOneWidget);
    });

    testWidgets('a rejected set is reported and the chips do not move', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'eu');
      bridge.failCommands = true;
      await tester.tap(find.byKey(const Key('global-filter-clear')));
      await tester.pumpAndSettle();
      expect(find.textContaining('unknown field'), findsOneWidget);
      expect(find.text('region = eu'), findsOneWidget);
    });

    testWidgets('with no profile there is nothing to offer, so Add is disabled',
        (tester) async {
      final bridge = _bridge()
        ..degraded = true
        ..sourceUnavailable = true;
      final engine = await _open(bridge);
      await _pump(tester, engine);
      final add = tester.widget<TextButton>(find.byKey(const Key('global-filter-add')));
      expect(add.onPressed, isNull);
    });
  });

  group('one filter, every component (AT-06)', () {
    testWidgets('the table and the card narrow together', (tester) async {
      final bridge = _bridge(components: [
        _card(),
        _card(id: 'avg', op: 'avg', field: 'amount'),
        _table(),
      ]);
      final engine = await _open(bridge);
      await _pump(tester, engine);
      expect(find.text('4'), findsOneWidget, reason: 'four records to start');
      expect(find.text('25'), findsOneWidget, reason: 'mean of 10, 20, 30, 40');
      expect(find.text('1–4 of 4'), findsOneWidget);

      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'eu');
      expect(find.text('2'), findsOneWidget, reason: 'two eu records');
      expect(find.text('20'), findsOneWidget, reason: 'mean of 10 and 30');
      expect(find.text('1–2 of 2'), findsOneWidget);
    });

    testWidgets('clearing restores the exact prior aggregates', (tester) async {
      final bridge = _bridge(components: [
        _card(),
        _card(id: 'avg', op: 'avg', field: 'amount'),
        _table(),
      ]);
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'eu');
      expect(find.text('20'), findsOneWidget);
      await tester.tap(find.byKey(const Key('global-filter-clear')));
      await tester.pumpAndSettle();
      expect(find.text('4'), findsOneWidget);
      expect(find.text('25'), findsOneWidget);
      expect(find.text('1–4 of 4'), findsOneWidget);
    });

    testWidgets('a global filter intersects a component filter rather than replacing it',
        (tester) async {
      final bridge = _bridge(components: [
        _card(),
        _table(state: {
          'filter': {'op': 'gt', 'field': 'amount', 'value': 10},
        }),
      ]);
      final engine = await _open(bridge);
      await _pump(tester, engine);
      expect(find.text('1–3 of 3'), findsOneWidget, reason: 'the component filter alone');
      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'eu');
      // eu rows are 10 and 30; only 30 is also greater than 10.
      expect(find.text('1–1 of 1'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('2'), findsOneWidget,
          reason: 'the card has no component filter, so it sees both eu rows');
    });

    testWidgets('a card refreshes when the filter was set somewhere else', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      expect(find.text('4'), findsOneWidget);
      await engine.applyCommands([
        Commands.setGlobalFilter([
          {'op': 'eq', 'field': 'region', 'value': 'eu'},
        ]),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget,
          reason: 'the card must notice a revision it did not cause');
    });
  });

  group('metric-card tap-to-filter', () {
    final errors = {'op': 'eq', 'field': 'note', 'value': 'alpha'};

    testWidgets('tapping toggles the card\'s own binding filter into the global set',
        (tester) async {
      final bridge = _bridge(components: [_card(filter: errors), _table()]);
      final engine = await _open(bridge);
      await _pump(tester, engine);
      expect(find.text('Tap to filter the workspace'), findsOneWidget);

      await tester.tap(find.byKey(const Key('metric-tap-records')));
      await tester.pumpAndSettle();
      expect(bridge.commandBatches.last.single, {
        'kind': 'setGlobalFilter',
        'filters': [errors],
      });
      expect(find.text('note = alpha'), findsOneWidget, reason: 'the bar shows it too');
      expect(find.text('Filtering the workspace — tap to clear'), findsOneWidget);
      expect(find.text('1–1 of 1'), findsOneWidget);
    });

    testWidgets('tapping again removes it and restores the workspace', (tester) async {
      final bridge = _bridge(components: [_card(filter: errors), _table()]);
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('metric-tap-records')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('metric-tap-records')));
      await tester.pumpAndSettle();
      expect(_lastSet(bridge), isEmpty);
      expect(find.text('Tap to filter the workspace'), findsOneWidget);
      expect(find.text('1–4 of 4'), findsOneWidget);
    });

    testWidgets('the card looks applied when the same filter came from the bar',
        (tester) async {
      final bridge = _bridge(components: [_card(filter: errors), _table()]);
      final engine = await _open(bridge);
      await _pump(tester, engine);
      // Structurally equal, but a different map object — the card must compare by value.
      await engine.applyCommands([
        Commands.setGlobalFilter([
          {'value': 'alpha', 'field': 'note', 'op': 'eq'},
        ]),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Filtering the workspace — tap to clear'), findsOneWidget);
    });

    testWidgets('toggling keeps the other global filters', (tester) async {
      final bridge = _bridge(components: [_card(filter: errors), _table()]);
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await _addFilter(tester, field: 'region', operator: 'Equals', bound: 'eu');
      await tester.tap(find.byKey(const Key('metric-tap-records')));
      await tester.pumpAndSettle();
      expect(_lastSet(bridge).length, 2);
      expect(_lastSet(bridge).first, {'op': 'eq', 'field': 'region', 'value': 'eu'});
    });

    testWidgets('a card with no filter of its own opens the workspace menu',
        (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      expect(find.text('Tap to add a filter'), findsOneWidget);
      await tester.tap(find.byKey(const Key('metric-tap-records')));
      await tester.pumpAndSettle();
      expect(find.text('Filter the whole workspace'), findsOneWidget);
      expect(find.byKey(const Key('filter-field')), findsOneWidget);
    });

    testWidgets('a card that cannot filter is not a control', (tester) async {
      final bridge = _bridge(components: [_card(canFilter: false), _table()]);
      final engine = await _open(bridge);
      await _pump(tester, engine);
      expect(find.byKey(const Key('metric-tap-records')), findsNothing);
      expect(find.text('Tap to add a filter'), findsNothing);
    });

    testWidgets('a rejected toggle leaves the card unpressed', (tester) async {
      final bridge = _bridge(components: [_card(filter: errors), _table()]);
      final engine = await _open(bridge);
      await _pump(tester, engine);
      bridge.failCommands = true;
      await tester.tap(find.byKey(const Key('metric-tap-records')));
      await tester.pumpAndSettle();
      expect(find.textContaining('unknown field'), findsOneWidget);
      expect(find.text('Tap to filter the workspace'), findsOneWidget);
      expect(find.text('Filtering the workspace — tap to clear'), findsNothing);
    });
  });
}
