/// Table interactions (M1.3 task 1.3.3), tested as the user drives them.
///
/// Every test here has the same shape: gesture → **command** → page re-requested from the
/// engine. The assertions look at the recorded command batch, because that is the contract;
/// a widget that filtered or sorted its own rows could still show the right pixels and would
/// be wrong the moment a global filter existed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';

import '../support/scripted_bridge.dart';

Map<String, dynamic> _spec({
  Map<String, dynamic>? interactions,
  Map<String, dynamic>? state,
  int pageSize = 2,
}) =>
    {
      'id': 'data_table',
      'type': 'data_table',
      'title': 'Data',
      'binding': {
        'kind': 'data_table',
        'columns': <String>[],
        'page_size': pageSize,
      },
      'interactions': interactions ??
          {'search': true, 'sort': true, 'filter': true, 'drillDown': true},
      if (state != null) 'state': state,
    };

const _rows = [
  ['eu', 10, null],
  ['us', 20, 'alpha'],
  ['apac', 30, 'beta'],
  ['latam', 40, null],
];

ScriptedBridge _bridge({
  Map<String, dynamic>? spec,
  Map<String, String>? dtypes,
  Map<String, List<String>>? topValues,
  List<List<dynamic>>? rows,
  List<String>? fields,
}) {
  final s = spec ?? _spec();
  return ScriptedBridge(
    rows: rows ?? List.of(_rows),
    fields: fields,
    dtypes: dtypes ?? const {'amount': 'int64'},
    topValues: topValues,
    components: [s],
    order: ['data_table'],
  );
}

Future<EngineController> _open(ScriptedBridge b) async {
  final c = EngineController(bridge: b, storageRoot: '/tmp/m');
  await c.open('w1');
  return c;
}

/// Hosts the table as the app does: rebuilt from the document on every notification, so
/// persisted state reaches the header after each command.
Future<void> _pump(WidgetTester tester, EngineController engine) async {
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
}

/// The last command sent, for the common one-command case.
Map<String, dynamic> _lastCommand(ScriptedBridge b) => b.commandBatches.last.single;

Future<void> _chooseOperator(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('filter-operator')));
  await tester.pumpAndSettle();
  final item = find.text(label).last;
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

void main() {
  group('column sorting', () {
    testWidgets('tapping a header cycles ascending, descending, off', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);

      await tester.tap(find.byKey(const Key('sort-amount')));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge), {
        'kind': 'setComponentSort',
        'componentId': 'data_table',
        'sort': [
          {'field': 'amount', 'dir': 'asc', 'nulls': 'last'},
        ],
      });
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

      await tester.tap(find.byKey(const Key('sort-amount')));
      await tester.pumpAndSettle();
      expect((_lastCommand(bridge)['sort'] as List).single,
          {'field': 'amount', 'dir': 'desc', 'nulls': 'last'});
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);

      await tester.tap(find.byKey(const Key('sort-amount')));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge)['sort'], isEmpty);
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
    });

    testWidgets('the sorted page comes from the engine, not from a local sort',
        (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('sort-amount')));
      await tester.pumpAndSettle();
      expect(bridge.pageCalls.last['sort'], [
        {'field': 'amount', 'dir': 'asc', 'nulls': 'last'},
      ]);
      expect(bridge.plans, isEmpty, reason: 'no raw plan may bypass the composed one');
      // Ascending by amount, so the first page is the two smallest.
      expect(find.text('10'), findsOneWidget);
      expect(find.text('20'), findsOneWidget);
    });

    testWidgets('a persisted sort shows its indicator on first paint (AT-07)',
        (tester) async {
      final bridge = _bridge(
        spec: _spec(state: {
          'sort': [
            {'field': 'amount', 'dir': 'desc', 'nulls': 'last'},
          ],
        }),
      );
      final engine = await _open(bridge);
      await _pump(tester, engine);
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget,
          reason: 'the indicator is read from the document, so a reopen keeps it');
      expect(bridge.commandBatches, isEmpty, reason: 'rendering must not send a command');
      expect((bridge.pageCalls.first['sort'] as List).single['dir'], 'desc');
    });

    testWidgets('sorting another column moves the indicator', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('sort-amount')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sort-region')));
      await tester.pumpAndSettle();
      expect((_lastCommand(bridge)['sort'] as List).single['field'], 'region');
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    });

    testWidgets('sorting resets to the first page', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(bridge.pageCalls.last['offset'], 2);
      await tester.tap(find.byKey(const Key('sort-amount')));
      await tester.pumpAndSettle();
      expect(bridge.pageCalls.last['offset'], 0);
      expect(find.text('1–2 of 4'), findsOneWidget);
    });

    testWidgets('a header is inert when the binding forbids sorting', (tester) async {
      final bridge = _bridge(spec: _spec(interactions: {'search': true}));
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('sort-amount')));
      await tester.pumpAndSettle();
      expect(bridge.commandBatches, isEmpty);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
    });
  });

  group('type-aware filter menu', () {
    testWidgets('a number offers comparisons and never substring matching',
        (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-amount')));
      await tester.pumpAndSettle();
      expect(find.text('Filter amount'), findsOneWidget);
      await tester.tap(find.byKey(const Key('filter-operator')));
      await tester.pumpAndSettle();
      expect(find.text('Greater than'), findsWidgets);
      expect(find.text('Contains'), findsNothing);
    });

    testWidgets('a numeric bound is sent as a number, not as typed text', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-amount')));
      await tester.pumpAndSettle();
      await _chooseOperator(tester, 'At least');
      await tester.enterText(find.byKey(const Key('filter-value')), '20');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge), {
        'kind': 'setComponentFilter',
        'componentId': 'data_table',
        'filter': {'op': 'gte', 'field': 'amount', 'value': 20},
      });
      expect(find.text('amount ≥ 20'), findsOneWidget);
      expect(find.text('1–2 of 3'), findsOneWidget);
    });

    testWidgets('an unparseable number cannot be applied', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-amount')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('filter-value')), 'abc');
      await tester.pumpAndSettle();
      final apply = tester.widget<FilledButton>(find.byKey(const Key('filter-apply')));
      expect(apply.onPressed, isNull);
    });

    testWidgets('a text column offers contains and the engine\'s frequent values',
        (tester) async {
      final bridge = _bridge(topValues: {
        'region': ['eu', 'us'],
      });
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-region')));
      await tester.pumpAndSettle();
      expect(find.text('Contains'), findsOneWidget, reason: 'the default text operator');
      expect(find.text('Frequent values'), findsOneWidget);
      await tester.tap(find.widgetWithText(ActionChip, 'eu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge)['filter'],
          {'op': 'contains', 'field': 'region', 'value': 'eu'});
      expect(find.text('1–1 of 1'), findsOneWidget);
    });

    testWidgets('one-of sends an array, which is what the engine reads', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-region')));
      await tester.pumpAndSettle();
      await _chooseOperator(tester, 'Is one of');
      await tester.enterText(find.byKey(const Key('filter-value')), 'eu, us');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge)['filter'], {
        'op': 'in',
        'field': 'region',
        'value': ['eu', 'us'],
      });
      expect(find.text('1–2 of 2'), findsOneWidget);
    });

    testWidgets('a boolean offers a choice, not a text box', (tester) async {
      final bridge = _bridge(
        fields: ['region', 'active', 'note'],
        dtypes: const {'active': 'bool'},
        rows: [
          ['eu', true, null],
          ['us', false, 'alpha'],
        ],
      );
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-active')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-bool')), findsOneWidget);
      expect(find.byKey(const Key('filter-value')), findsNothing);
      expect(find.text('Is'), findsOneWidget, reason: 'a boolean says is, not equals');
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge)['filter'],
          {'op': 'eq', 'field': 'active', 'value': true});
    });

    testWidgets('choosing False sends false', (tester) async {
      final bridge = _bridge(
        fields: ['region', 'active', 'note'],
        dtypes: const {'active': 'bool'},
        rows: [
          ['eu', true, null],
          ['us', false, 'alpha'],
        ],
      );
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-active')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-bool')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('False').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge)['filter'],
          {'op': 'eq', 'field': 'active', 'value': false});
      expect(find.text('1–1 of 1'), findsOneWidget);
    });

    testWidgets('a timestamp offers date bounds and a picker', (tester) async {
      final bridge = _bridge(dtypes: const {'amount': 'timestamp'});
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-amount')));
      await tester.pumpAndSettle();
      expect(find.text('On or after'), findsOneWidget);
      expect(find.byKey(const Key('filter-date')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('filter-value')), '2026-01-01');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge)['filter'],
          {'op': 'gte', 'field': 'amount', 'value': '2026-01-01'});
    });

    testWidgets('a null test needs no value and sends none', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-note')));
      await tester.pumpAndSettle();
      await _chooseOperator(tester, 'Is empty');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-value')), findsNothing);
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge)['filter'], {'op': 'is_null', 'field': 'note'});
      expect(find.text('note is empty'), findsOneWidget);
      expect(find.text('1–2 of 2'), findsOneWidget);
    });

    testWidgets('cancelling the menu changes nothing', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-amount')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('filter-value')), '20');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(bridge.commandBatches, isEmpty);
      expect(find.text('1–2 of 4'), findsOneWidget);
    });

    testWidgets('a filter cannot be opened when the binding forbids it', (tester) async {
      final bridge = _bridge(spec: _spec(interactions: {'search': true, 'sort': true}));
      final engine = await _open(bridge);
      await _pump(tester, engine);
      expect(find.byKey(const Key('filter-amount')), findsNothing);
    });

    testWidgets('a column with no inferred type still gets a usable menu',
        (tester) async {
      final bridge = _bridge(dtypes: const {});
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.tap(find.byKey(const Key('filter-amount')));
      await tester.pumpAndSettle();
      expect(find.text('Contains'), findsOneWidget);
    });
  });

  group('active filters', () {
    Future<void> filterAmount(WidgetTester tester, String bound) async {
      await tester.tap(find.byKey(const Key('filter-amount')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('filter-value')), bound);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();
    }

    testWidgets('two columns combine into one conjunction', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await filterAmount(tester, '10');
      await tester.tap(find.byKey(const Key('filter-region')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('filter-value')), 'eu');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();
      final filter = _lastCommand(bridge)['filter'] as Map<String, dynamic>;
      expect(filter['op'], 'and');
      expect((filter['args'] as List).length, 2);
      expect(find.text('amount = 10'), findsOneWidget);
      expect(find.text('region contains eu'), findsOneWidget);
    });

    testWidgets('deleting a chip removes only that column', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await filterAmount(tester, '10');
      await tester.tap(find.byKey(const Key('filter-region')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('filter-value')), 'eu');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge)['filter'],
          {'op': 'contains', 'field': 'region', 'value': 'eu'});
      expect(find.text('amount = 10'), findsNothing);
      expect(find.text('region contains eu'), findsOneWidget);
    });

    testWidgets('the menu can clear the filter it opened on', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await filterAmount(tester, '10');
      await tester.tap(find.byKey(const Key('filter-amount')));
      await tester.pumpAndSettle();
      expect(find.text('10'), findsWidgets, reason: 'the menu shows the applied bound');
      await tester.tap(find.byKey(const Key('filter-clear')));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge)['filter'], isNull);
      expect(find.text('1–2 of 4'), findsOneWidget);
    });

    testWidgets('clear all sends filter and search in one atomic batch', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await filterAmount(tester, '10');
      await tester.enterText(find.byType(TextField).first, 'eu');
      await tester.pumpAndSettle();
      final before = bridge.commandBatches.length;

      await tester.tap(find.byKey(const Key('table-clear-all')));
      await tester.pumpAndSettle();
      expect(bridge.commandBatches.length, before + 1);
      expect(bridge.commandBatches.last, [
        {'kind': 'setComponentFilter', 'componentId': 'data_table', 'filter': null},
        {'kind': 'setSearch', 'componentId': 'data_table', 'text': null},
      ]);
      expect(find.text('1–2 of 4'), findsOneWidget);
      expect(find.byKey(const Key('table-clear-all')), findsNothing);
    });

    testWidgets('search shows as a chip that can be removed', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await tester.enterText(find.byType(TextField), 'apac');
      await tester.pumpAndSettle();
      expect(find.text('Search: apac'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(_lastCommand(bridge),
          {'kind': 'setSearch', 'componentId': 'data_table', 'text': null});
      expect(find.text('1–2 of 4'), findsOneWidget);
    });

    testWidgets('an empty result names the filter that caused it', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      await filterAmount(tester, '999');
      expect(find.text('No rows match amount = 999.'), findsOneWidget);
    });

    testWidgets('a command applied elsewhere refreshes this table', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      // Another component changes the document — the global filter bar in 1.3.4, or a
      // tap-to-filter chip. This table must notice without being told directly.
      await engine.applyCommands([
        {
          'kind': 'setComponentFilter',
          'componentId': 'data_table',
          'filter': {'op': 'eq', 'field': 'region', 'value': 'eu'},
        },
      ]);
      await tester.pumpAndSettle();
      expect(find.text('1–1 of 1'), findsOneWidget);
      expect(find.text('region = eu'), findsOneWidget);
    });

    testWidgets('a rejected command is reported and changes no state', (tester) async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      await _pump(tester, engine);
      bridge.failCommands = true;
      await tester.tap(find.byKey(const Key('sort-amount')));
      await tester.pumpAndSettle();
      expect(find.textContaining('unknown field'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing,
          reason: 'the header must not claim a sort the engine refused');
      expect(find.text('1–2 of 4'), findsOneWidget);
    });
  });
}
