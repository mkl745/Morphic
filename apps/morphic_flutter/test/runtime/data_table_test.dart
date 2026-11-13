library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
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

/// The paging part of a component page request. The table no longer sends a plan: it asks for
/// a component's page and Rust resolves the persisted filter/sort/search into one.
Map<String, dynamic> _req(Map<String, dynamic> call) => {
      'offset': call['offset'],
      'limit': call['limit'],
      if (call['search'] != null) 'search': call['search'],
    };

/// A bridge whose document holds exactly this table, so commands have somewhere to persist.
ScriptedBridge _bridgeWith(
  List<List<dynamic>> rows, {
  Map<String, dynamic>? spec,
  List<String>? fields,
  Map<String, String>? dtypes,
}) {
  final s = spec ?? _spec();
  return ScriptedBridge(
    rows: rows,
    fields: fields,
    dtypes: dtypes,
    components: [s],
    order: [s['id'] as String],
  );
}

/// Hosts the table the way the app does: rebuilt from the controller's document on every
/// notification, so persisted interaction state reaches the widget after a command.
Widget _live(
  EngineController engine, {
  double height = 400,
  Duration debounce = Duration.zero,
}) =>
    _host(AnimatedBuilder(
      animation: engine,
      builder: (context, _) => DataTableView(
        ctx: ComponentContext(spec: engine.components.first, engine: engine),
        height: height,
        searchDebounce: debounce,
      ),
    ));

const _rows = [
  ['eu', 10, null],
  ['us', 20, 'alpha'],
  ['apac', 30, 'beta'],
  ['latam', 40, null],
];

/// Capture the next page eagerly, but delay its delivery to exercise source/revision races.
class _HeldPageController extends EngineController {
  _HeldPageController({required super.bridge, required super.storageRoot});

  Completer<void>? holdNext;

  @override
  Future<PageResult?> componentPage(String componentId, {int offset = 0, int limit = 0}) async {
    final gate = holdNext;
    holdNext = null;
    final result = await super.componentPage(componentId, offset: offset, limit: limit);
    if (gate != null) await gate.future;
    return result;
  }
}

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
    expect(_req(bridge.pageCalls.first), {'offset': 0, 'limit': 2});
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

    expect(_req(bridge.pageCalls.last), {'offset': 2, 'limit': 2});
    expect(find.text('apac'), findsOneWidget);
    expect(find.text('eu'), findsNothing);
    expect(find.text('3–4 of 4'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous page'));
    await tester.pumpAndSettle();
    expect(_req(bridge.pageCalls.last), {'offset': 0, 'limit': 2});
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

    // byTooltip matches the Tooltip widget, so walk up to the button itself.
    IconButton button(String tooltip) => tester.widget<IconButton>(
          find.ancestor(
            of: find.byTooltip(tooltip),
            matching: find.byType(IconButton),
          ),
        );
    IconButton prev() => button('Previous page');
    IconButton next() => button('Next page');
    expect(prev().onPressed, isNull);
    expect(next().onPressed, isNotNull);

    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(prev().onPressed, isNotNull);
    expect(next().onPressed, isNull, reason: 'last page must not offer a next page');
  });

  testWidgets('search is debounced and executed by the engine', (tester) async {
    final bridge = _bridgeWith(List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(
        _live(engine, debounce: const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    final before = bridge.pageCalls.length;

    await tester.enterText(find.byType(TextField), 'ap');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(TextField), 'apa');
    await tester.pump(const Duration(milliseconds: 50));
    expect(bridge.pageCalls.length, before, reason: 'keystrokes must not each hit the engine');

    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(_req(bridge.pageCalls.last), {'offset': 0, 'limit': 2, 'search': 'apa'});
    expect(find.text('apac'), findsOneWidget);
    expect(find.text('1–1 of 1'), findsOneWidget);
    // One keystroke burst, one command — and it is persisted state, not a plan field.
    expect(bridge.commandBatches.length, 1);
    expect(bridge.commandBatches.single.single,
        {'kind': 'setSearch', 'componentId': 'data_table', 'text': 'apa'});
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
    final bridge = _bridgeWith(List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_live(engine));
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
    expect(bridge.pageCalls.first['limit'], maxPageSize);
  });

  testWidgets('a zero page_size still requests at least one row', (tester) async {
    final bridge = ScriptedBridge(rows: List.of(_rows));
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(pageSize: 0), engine: engine),
      height: 400,
    )));
    await tester.pumpAndSettle();
    expect(bridge.pageCalls.first['limit'], 1);
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

  testWidgets('reordered projection keeps cells, semantics and full row detail aligned',
      (tester) async {
    final spec = _spec(columns: ['amount', 'region']);
    spec['interactions'] = {'search': true, 'sort': true, 'filter': true};
    final bridge = _bridgeWith([
      ['eu', 30, 'hidden note'],
      ['us', 10, ''],
      ['apac', 20, null],
    ], spec: spec);
    final engine = await _open(bridge);
    await tester.pumpWidget(_live(engine));
    await tester.pumpAndSettle();

    final first = find.semantics.byLabel('Row 1: amount: 30, region: eu');
    expect(first, findsOne);
    final firstRow = find.byKey(const Key('table-row-1'));
    final amount = find.descendant(of: firstRow, matching: find.text('30'));
    final region = find.descendant(of: firstRow, matching: find.text('eu'));
    expect(tester.getTopLeft(amount).dx, lessThan(tester.getTopLeft(region).dx));
    expect(find.text('note'), findsNothing, reason: 'the grid uses the binding projection');
    expect(find.text('hidden note'), findsNothing);

    tester.semantics.tap(first);
    await tester.pumpAndSettle();
    expect(find.text('note'), findsOneWidget, reason: 'detail includes unprojected fields');
    for (final pair in {'amount': '30', 'region': 'eu', 'note': 'hidden note'}.entries) {
      expect(
        find.byWidgetPredicate((widget) {
          if (widget is! Column || widget.children.length < 3) return false;
          final heading = widget.children.first;
          final value = widget.children.last;
          return heading is Text &&
              heading.data == pair.key &&
              value is SelectableText &&
              value.data == pair.value;
        }),
        findsOneWidget,
        reason: 'detail must pair ${pair.key} with ${pair.value}',
      );
    }
    await tester.tap(find.byKey(const Key('row-detail-close')));
    await tester.pumpAndSettle();

    tester.semantics.tap(find.semantics.byLabel('Row 2: amount: 10, region: us'));
    await tester.pumpAndSettle();
    expect(find.text('Empty string'), findsOneWidget);
    await tester.tap(find.byKey(const Key('row-detail-close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel('Row 3: amount: 20, region: apac'), findsOne);
    tester.semantics.tap(find.semantics.byLabel('Column amount, Not sorted'));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel('Row 1: amount: 10, region: us'), findsOne);
  });

  testWidgets('column widths use the selected field rather than the source position',
      (tester) async {
    const long = 'A very long note that needs considerably more width';
    final bridge = _bridgeWith([
      ['eu', 7, long],
    ], spec: _spec(columns: ['note', 'region']));
    final engine = await _open(bridge);
    await tester.pumpWidget(_live(engine));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('sort-note'))).width,
      greaterThan(tester.getSize(find.byKey(const Key('sort-region'))).width),
    );
    expect(find.semantics.byLabel('Row 1: note: $long, region: eu'), findsOne);
  });

  testWidgets('unknown projected columns and malformed pages fail instead of mislabelling',
      (tester) async {
    final unknown = await _open(_bridgeWith(List.of(_rows), spec: _spec(columns: ['ghost'])));
    await tester.pumpWidget(_live(unknown));
    await tester.pumpAndSettle();
    expect(find.text('Could not load rows'), findsOneWidget);
    expect(find.textContaining('columns that are missing'), findsOneWidget);
    expect(find.semantics.byLabel(RegExp('^Row 1:')), findsNothing);

    // Replace the controller without unmounting: matching revisions/ids must not reuse the
    // previous controller's failed page or metadata.
    final short = await _open(_bridgeWith([
      ['eu', 30],
    ]));
    await tester.pumpWidget(_live(short));
    await tester.pumpAndSettle();
    expect(find.text('Could not load rows'), findsOneWidget);
    expect(find.textContaining('does not match the source column count'), findsOneWidget);
    expect(find.semantics.byLabel(RegExp('^Row 1:')), findsNothing);
  });

  testWidgets('missing or ambiguous source metadata is not treated as null cells', (tester) async {
    // A deliberately inconsistent bridge returns a page while omitting its source profile.
    final missing = await _open(ScriptedBridge(degraded: true, sourceUnavailable: false));
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: _spec(columns: ['region']), engine: missing),
      height: 400,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Could not load rows'), findsOneWidget);
    expect(find.textContaining('Source column information'), findsOneWidget);
    expect(find.semantics.byLabel(RegExp('^Row 1:')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    final duplicate = await _open(_bridgeWith(
      [
        ['eu', 'us'],
      ],
      fields: ['region', 'region'],
      spec: _spec(columns: ['region']),
    ));
    await tester.pumpWidget(_live(duplicate));
    await tester.pumpAndSettle();
    expect(find.text('Could not load rows'), findsOneWidget);
    expect(find.textContaining('Source column information'), findsOneWidget);
    expect(find.semantics.byLabel(RegExp('^Row 1:')), findsNothing);
  });

  testWidgets('invalid binding metadata fails instead of silently dropping a column',
      (tester) async {
    final spec = _spec();
    (spec['binding'] as Map<String, dynamic>)['columns'] = ['region', 7];
    final engine = await _open(_bridgeWith(List.of(_rows), spec: spec));
    await tester.pumpWidget(_live(engine));
    await tester.pumpAndSettle();
    expect(find.text('Could not load rows'), findsOneWidget);
    expect(find.textContaining('invalid column information'), findsOneWidget);
    expect(find.semantics.byLabel(RegExp('^Row 1:')), findsNothing);
  });

  testWidgets('a same-revision source reorder hides stale rows until the new page arrives',
      (tester) async {
    final bridge = _bridgeWith(
      [
        ['eu', 30, 'old'],
      ],
      fields: ['region', 'amount', 'note'],
      spec: _spec(columns: ['amount', 'region']),
    );
    final engine = _HeldPageController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_live(engine));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel('Row 1: amount: 30, region: eu'), findsOne);

    final gate = Completer<void>();
    engine.holdNext = gate;
    bridge.fields
      ..clear()
      ..addAll(['amount', 'region', 'note']);
    bridge.rows[0] = [99, 'us', 'new'];
    await engine.open('w1'); // The scripted snapshot still reports revision 1.
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.semantics.byLabel(RegExp('^Row 1:')), findsNothing,
        reason: 'old source-order cells must not be paired with the new profile');
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel('Row 1: amount: 99, region: us'), findsOne);
  });

  testWidgets('a same-revision reload refreshes rows even when field order is unchanged',
      (tester) async {
    final bridge = _bridgeWith([
      ['eu', 30, 'old'],
    ], spec: _spec(columns: ['amount', 'region']));
    final engine = await _open(bridge);
    await tester.pumpWidget(_live(engine));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel('Row 1: amount: 30, region: eu'), findsOne);

    bridge.rows[0] = ['us', 99, 'new'];
    await engine.open('w1'); // Same id, revision and field names; a new profile snapshot.
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel('Row 1: amount: 99, region: us'), findsOne);
    expect(bridge.pageCalls, hasLength(2));
  });

  testWidgets('an in-flight page from a replaced source is discarded at the same revision',
      (tester) async {
    final spec = _spec(columns: ['amount', 'region']);
    final bridge = _bridgeWith(
      [
        ['eu', 30, 'old'],
      ],
      fields: ['region', 'amount', 'note'],
      spec: spec,
    );
    final engine = _HeldPageController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    final gate = Completer<void>();
    engine.holdNext = gate;
    // Deliberately omit an AnimatedBuilder: the request itself must detect the race.
    await tester.pumpWidget(_host(DataTableView(
      ctx: ComponentContext(spec: spec, engine: engine),
      height: 400,
    )));
    await tester.pump();
    bridge.fields
      ..clear()
      ..addAll(['amount', 'region', 'note']);
    bridge.rows[0] = [99, 'us', 'new'];
    await engine.open('w1');
    gate.complete();
    await tester.pumpAndSettle();
    expect(bridge.pageCalls, hasLength(2), reason: 'the old page must be re-read');
    expect(find.semantics.byLabel('Row 1: amount: 99, region: us'), findsOne);
    expect(find.semantics.byLabel('Row 1: amount: eu, region: 30'), findsNothing);
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
    // Both header and rows share one horizontal viewport, so they move together. A separate
    // vertical viewport may hold filter chips or command-error evidence above the grid.
    final horizontal = find.byWidgetPredicate(
      (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
    );
    expect(horizontal, findsOneWidget);
    expect(find.descendant(of: horizontal, matching: find.text('region')), findsOneWidget);
    expect(find.descendant(of: horizontal, matching: listFinder), findsOneWidget);
  });

  group('column sizing (defect found on a real phone)', () {
    // On the realme C51 every timestamp rendered as `2026-11-05T1…`: the column was sized
    // from the 4-character header, so a 24-character ISO value could never be read — not
    // even by scrolling, because the ellipsis lives inside the fixed-width column.
    const iso = '2026-11-05T14:00:02.000Z';

    Future<void> pump(WidgetTester tester, ScriptedBridge bridge,
        {int pageSize = 2}) async {
      final engine = await _open(bridge);
      await tester.pumpWidget(_host(DataTableView(
        ctx: ComponentContext(spec: _spec(pageSize: pageSize), engine: engine),
        height: 400,
      )));
      await tester.pumpAndSettle();
    }

    double headerWidth(WidgetTester tester, String column) {
      final box = tester.widget<SizedBox>(
        find.ancestor(of: find.text(column), matching: find.byType(SizedBox)).first,
      );
      return box.width!;
    }

    testWidgets('a timestamp column is wide enough for the whole value', (tester) async {
      await pump(
        tester,
        ScriptedBridge(
          fields: ['time', 'level', 'message'],
          rows: [
            [iso, 'ERROR', 'Upstream timeout'],
          ],
        ),
      );
      // 24 characters at ~7.2 dp plus padding; the old header-only rule gave 96 dp.
      expect(headerWidth(tester, 'time'), greaterThan(180));
    });

    testWidgets('a long text column grows to its content, not its header', (tester) async {
      await pump(tester, ScriptedBridge(rows: [
        ['eu', 1, 'Connection established'],
      ]));
      expect(headerWidth(tester, 'note'), greaterThan(150));
    });

    testWidgets('widths are frozen so paging does not make columns jump', (tester) async {
      final bridge = ScriptedBridge(rows: [
        [iso, 'ERROR', 'short'],
        ['us', 2, 'x'],
        ['apac', 3, 'a much longer message than the first page had'],
        ['latam', 4, 'y'],
      ]);
      await pump(tester, bridge);
      final before = headerWidth(tester, 'note');

      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(headerWidth(tester, 'note'), before,
          reason: 'column widths must not jitter between pages');
    });

    testWidgets('text scale changes expand headings without re-querying the page', (tester) async {
      final spec = {
        ..._spec(),
        'interactions': {'search': true, 'sort': true, 'filter': true},
      };
      final bridge = _bridgeWith([
        ['eu', 10, 'short'],
        ['us', 20, 'another'],
      ], spec: spec);
      final engine = await _open(bridge);
      Widget host(double scale) => MaterialApp(
            theme: MorphicTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: DataTableView(
                ctx: ComponentContext(spec: spec, engine: engine),
                height: 400,
              ),
            ),
          );

      await tester.pumpWidget(host(1));
      await tester.pumpAndSettle();
      final originalWidth = headerWidth(tester, 'amount');
      final calls = bridge.pageCalls.length;
      await tester.pumpWidget(host(1.3));
      await tester.pumpAndSettle();
      expect(headerWidth(tester, 'amount'), greaterThan(originalWidth));
      expect(tester.renderObject<RenderParagraph>(find.text('amount')).didExceedMaxLines, isFalse);
      expect(bridge.pageCalls.length, calls, reason: 'a text-scale change is not an engine query');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an enormous value is capped rather than dominating the viewport',
        (tester) async {
      await pump(tester, ScriptedBridge(rows: [
        ['eu', 1, 'x' * 5000],
      ]));
      expect(headerWidth(tester, 'note'), lessThanOrEqualTo(300));
    });

    testWidgets('tapping a cell opens the whole row, with the full value',
        (tester) async {
      const long = 'a value far too long to ever fit inside a table column whatsoever';
      await pump(tester, ScriptedBridge(rows: [
        ['eu', 1, long],
      ]));
      await tester.tap(find.text(long).hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Row 1'), findsOneWidget);
      // Every field of the record, not just the cell that was tapped.
      expect(find.text('region'), findsWidgets);
      expect(find.text('amount'), findsWidgets);
      expect(find.text('note'), findsWidgets);
      expect(find.text(long), findsWidgets);
      await tester.tap(find.byKey(const Key('row-detail-close')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a null cell is described as null, not as an empty string', (tester) async {
      await pump(tester, ScriptedBridge(rows: [
        ['eu', 1, null],
      ]));
      await tester.tap(find.text('—').hitTestable());
      await tester.pumpAndSettle();
      final nullText = find.text('No value (null)');
      expect(nullText, findsOneWidget);
      expect(
        tester.widget<Text>(nullText).style?.color,
        Theme.of(tester.element(nullText)).colorScheme.onSurfaceVariant,
      );
    });
  });
}
