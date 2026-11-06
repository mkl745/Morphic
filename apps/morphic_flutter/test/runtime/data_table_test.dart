library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';

import '../support/scripted_bridge.dart';

Map<String, dynamic> _spec({int pageSize = 2, bool search = true, List<String>? columns}) => {
      'id': 'data_table',
      'type': 'data_table',
      'title': 'Data',
      'binding': {
        'kind': 'data_table',
        'columns': columns ?? <String>[],
        'page_size': pageSize,
      },
      'interactions': {'search': search},
    };

Future<EngineController> _open(ScriptedBridge b) async {
  final c = EngineController(bridge: b, storageRoot: '/tmp/m');
  await c.open('w1');
  return c;
}

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

const _rows = [
  ['eu', 10, null],
  ['us', 20, 'alpha'],
  ['apac', 30, 'beta'],
  ['latam', 40, null],
];

void main() {
  testWidgets('renders the page the engine returned, with headers from the profile',
      (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();

    expect(find.text('region'), findsOneWidget);
    expect(find.text('amount'), findsOneWidget);
    expect(find.text('note'), findsOneWidget);
    expect(find.text('eu'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    // Page size 2 of 4 rows.
    expect(find.text('1–2 of 4'), findsOneWidget);
    expect(find.text('apac'), findsNothing);
    expect(bridge.plans.first, {'offset': 0, 'limit': 2});
  });

  testWidgets('a null cell is a glyph and zero would not be', (tester) async {
    final bridge = ScriptedBridge(rows: [
      ['eu', 0, null],
    ]);
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();

    expect(find.text('—'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('next page asks Rust for the next offset instead of slicing locally',
      (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();

    expect(bridge.plans.last, {'offset': 2, 'limit': 2});
    expect(find.text('apac'), findsOneWidget);
    expect(find.text('eu'), findsNothing);
    expect(find.text('3–4 of 4'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous page'));
    await tester.pumpAndSettle();
    expect(bridge.plans.last, {'offset': 0, 'limit': 2});
    expect(find.text('eu'), findsOneWidget);
  });

  testWidgets('paging controls are disabled at the boundaries', (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();

    IconButton prev() =>
        tester.widget<IconButton>(find.byTooltip('Previous page'));
    IconButton next() => tester.widget<IconButton>(find.byTooltip('Next page'));
    expect(prev().onPressed, isNull);
    expect(next().onPressed, isNotNull);

    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(prev().onPressed, isNotNull);
    expect(next().onPressed, isNull, reason: 'last page must not offer a next page');
  });

  testWidgets('search is debounced and executed by the engine', (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(), engine: engine),
      height: 400,
      searchDebounce: const Duration(milliseconds: 200),
    )));
    await tester.pumpAndSettle();
    final before = bridge.plans.length;

    await tester.enterText(find.byType(TextField), 'ap');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(TextField), 'apa');
    await tester.pump(const Duration(milliseconds: 50));
    expect(bridge.plans.length, before, reason: 'keystrokes must not each hit the engine');

    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(bridge.plans.last, {'offset': 0, 'limit': 2, 'search': 'apa'});
    expect(find.text('apac'), findsOneWidget);
    expect(find.text('1–1 of 1'), findsOneWidget);
  });

  testWidgets('search is hidden when the binding does not allow it', (tester) async {
    final engine = await _open(ScriptedBridge(rows: List.of(_rows)));
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(search: false), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('no matches says so, rather than showing an empty grid', (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(), engine: engine),
      height: 400,
      searchDebounce: Duration.zero,
    )));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text('No rows match “zzzz”.'), findsOneWidget);
    expect(find.text('0 of 0'), findsOneWidget);
  });

  testWidgets('an empty dataset is labelled', (tester) async {
    final engine = await _open(ScriptedBridge(rows: []));
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();
    expect(find.text('This dataset has no rows.'), findsOneWidget);
  });

  testWidgets('a query failure offers a retry and then recovers', (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows))..failQuery = true;
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Could not load rows'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    bridge.failQuery = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('eu'), findsOneWidget);
    expect(find.text('Could not load rows'), findsNothing);
  });

  testWidgets('loading is visible until the first page arrives', (tester) async {
    final engine = GatedEngineController(
        bridge: ScriptedBridge(), storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(), engine: engine),
      height: 400,
    )));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    engine.pageGate.complete(const PageResult(
      rows: [
        ['eu', 1, null]
      ],
      totalRows: 1,
      offset: 0,
      limit: 2,
      hasMore: false,
    ));
    await tester.pumpAndSettle();
    expect(find.text('eu'), findsOneWidget);
  });

  testWidgets('page_size from the binding is clamped to the engine ceiling',
      (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(pageSize: 99999), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();
    expect(bridge.plans.first['limit'], maxPageSize);
  });

  testWidgets('a zero page_size still requests at least one row', (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(pageSize: 0), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();
    expect(bridge.plans.first['limit'], 1);
  });

  testWidgets('bound columns override the profile order', (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(
          spec: _spec(columns: ['region']), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();
    expect(find.text('region'), findsOneWidget);
    expect(find.text('amount'), findsNothing);
  });

  testWidgets('the header lives outside the vertical scroll view (sticky)',
      (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(pageSize: 4), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);
    // The header must not be a descendant of the vertically scrolling list.
    expect(
      find.descendant(of: listFinder, matching: find.text('region')),
      findsNothing,
      reason: 'a header inside the ListView would scroll away with the rows',
    );
    expect(find.text('region'), findsOneWidget);
    // Both header and rows share one horizontal viewport, so they move together.
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}
