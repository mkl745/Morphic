/// Cross-component consistency (M1.3 task 1.3.5).
///
/// The engine already applies a batch atomically, so every read *can* be consistent. This file
/// tests the harder half: that the UI never paints a frame where one component shows the new
/// selection and another still shows the old one.
///
/// To make that testable the controller below computes each read eagerly and then **delivers it
/// later**, on a gate. That is not a hypothetical: it is exactly what happens once the bridge
/// moves off the UI isolate, and it is the only way to observe a response that was computed
/// against a revision the workspace has already left.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';
import 'package:morphic_flutter/runtime/components/metric_card_view.dart';
import 'package:morphic_flutter/runtime/workspace_view.dart';

import '../support/scripted_bridge.dart';

/// One read, stamped with the revision the document was on when it was computed.
class RecordedRead {
  RecordedRead(this.componentId, this.revision, this.offset);

  final String componentId;
  final int revision;
  final int? offset;

  @override
  String toString() => '$componentId@rev$revision(offset: $offset)';
}

/// Computes reads at the current revision, then holds delivery until a gate is completed.
class StaggeredController extends EngineController {
  StaggeredController({required super.bridge, required super.storageRoot});

  final List<RecordedRead> reads = [];
  final Map<String, List<Completer<void>>> _gates = {};

  /// The next read of [componentId] will wait for the returned completer. Gates are consumed
  /// in order, so two overlapping reads of one component can be released independently.
  Completer<void> holdNext(String componentId) {
    final gate = Completer<void>();
    _gates.putIfAbsent(componentId, () => []).add(gate);
    return gate;
  }

  Future<void> _deliver(String componentId) async {
    final queue = _gates[componentId];
    if (queue == null || queue.isEmpty) return;
    await queue.removeAt(0).future;
  }

  @override
  Future<PageResult?> componentPage(String componentId,
      {int offset = 0, int limit = 0}) async {
    final at = revision;
    final result = await super.componentPage(componentId, offset: offset, limit: limit);
    reads.add(RecordedRead(componentId, at, offset));
    await _deliver(componentId);
    return result;
  }

  @override
  Future<Object?> metric(String componentId) async {
    final at = revision;
    final result = await super.metric(componentId);
    reads.add(RecordedRead(componentId, at, null));
    await _deliver(componentId);
    return result;
  }
}

const _rows = [
  ['eu', 10, null],
  ['us', 20, 'alpha'],
  ['eu', 30, 'beta'],
  ['latam', 40, null],
];

Map<String, dynamic> _card() => {
      'id': 'records',
      'type': 'metric_card',
      'title': 'Records',
      'binding': {
        'kind': 'metric_card',
        'aggregation': {'op': 'count', 'field': null},
      },
      'interactions': {'filter': true},
    };

Map<String, dynamic> _table({int pageSize = 2}) => {
      'id': 'data_table',
      'type': 'data_table',
      'title': 'Data',
      'binding': {
        'kind': 'data_table',
        'columns': <String>[],
        'page_size': pageSize,
      },
      'interactions': {'search': true, 'sort': true, 'filter': true},
    };

StaggeredController _controller({int pageSize = 2}) {
  final bridge = ScriptedBridge(
    rows: List.of(_rows),
    dtypes: const {'amount': 'int64'},
    components: [_card(), _table(pageSize: pageSize)],
    order: ['records', 'data_table'],
  )..computeMetrics = true;
  return StaggeredController(bridge: bridge, storageRoot: '/tmp/m');
}

/// The production route: WorkspaceView rebuilt from the controller on every notification.
Future<void> _pumpRoute(WidgetTester tester, EngineController engine) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AnimatedBuilder(
        animation: engine,
        builder: (context, _) => WorkspaceView(
          controller: engine,
          registry: ComponentRegistry(),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _inTable(Finder matching) =>
    find.descendant(of: find.byType(DataTableView), matching: matching);

Future<void> _filterToEu(EngineController engine) => engine.applyCommands([
      Commands.setGlobalFilter([
        {'op': 'eq', 'field': 'region', 'value': 'eu'},
      ]),
    ]);

void main() {
  testWidgets('every component reads at the one revision the command produced',
      (tester) async {
    final engine = _controller();
    await engine.open('w1');
    await _pumpRoute(tester, engine);
    engine.reads.clear();

    await _filterToEu(engine);
    await tester.pumpAndSettle();

    expect(engine.reads, isNotEmpty);
    for (final read in engine.reads) {
      expect(read.revision, engine.revision,
          reason: '$read was computed against a superseded document');
    }
    expect(engine.reads.map((r) => r.componentId).toSet(), {'records', 'data_table'},
        reason: 'both bound components must be re-read, not just the one that changed');
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1–2 of 2'), findsOneWidget);
  });

  testWidgets('a slow component loads rather than showing the previous selection',
      (tester) async {
    final engine = _controller();
    await engine.open('w1');
    await _pumpRoute(tester, engine);
    expect(find.text('4'), findsOneWidget);
    expect(_inTable(find.text('1–2 of 4')), findsOneWidget);

    // The table's next read will be computed but not delivered.
    final slow = engine.holdNext('data_table');
    await _filterToEu(engine);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // The card is already on the new selection. The table must not sit beside it showing
    // the old row count — that is the torn frame. A loading state is honest; stale data is not.
    expect(find.text('2'), findsOneWidget);
    expect(_inTable(find.text('1–2 of 4')), findsNothing,
        reason: 'the old selection must not be painted next to the new one');
    expect(_inTable(find.text('us')), findsNothing,
        reason: 'stale rows must not be readable or actionable while reloading');
    expect(_inTable(find.byType(CircularProgressIndicator)), findsWidgets);

    slow.complete();
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
    expect(_inTable(find.text('1–2 of 2')), findsOneWidget);
  });

  testWidgets('a response computed for a superseded revision is discarded', (tester) async {
    final engine = _controller(pageSize: 10);
    await engine.open('w1');
    // Host the table with a pinned context so no rebuild-driven refetch can mask the guard:
    // this isolates the reader's own revision check.
    final ctx = ComponentContext(spec: _table(pageSize: 10), engine: engine);
    final slow = engine.holdNext('data_table');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DataTableView(ctx: ctx, height: 400, searchDebounce: Duration.zero),
      ),
    ));
    await tester.pump();
    expect(engine.reads.length, 1);
    final staleRevision = engine.reads.single.revision;

    // The document moves on while that first read is still undelivered.
    await _filterToEu(engine);
    expect(engine.revision, greaterThan(staleRevision));
    slow.complete();
    await tester.pumpAndSettle();

    expect(engine.reads.length, greaterThanOrEqualTo(2),
        reason: 'the stale response must trigger a fresh read, not be adopted');
    expect(engine.reads.last.revision, engine.revision);
    expect(_inTable(find.text('1–4 of 4')), findsNothing);
    expect(_inTable(find.text('1–2 of 2')), findsOneWidget);
  });

  testWidgets('the same guard protects a metric value', (tester) async {
    final engine = _controller();
    await engine.open('w1');
    final ctx = ComponentContext(spec: _card(), engine: engine);
    final slow = engine.holdNext('records');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MetricCardView(ctx: ctx)),
    ));
    await tester.pump();
    expect(engine.reads.single.componentId, 'records');

    await _filterToEu(engine);
    slow.complete();
    await tester.pumpAndSettle();

    expect(engine.reads.last.revision, engine.revision);
    expect(find.text('2'), findsOneWidget,
        reason: 'the value for the old selection must never be painted');
    expect(find.text('4'), findsNothing);
  });

  testWidgets('two commands in a row converge on the last revision', (tester) async {
    final engine = _controller();
    await engine.open('w1');
    await _pumpRoute(tester, engine);

    final first = engine.holdNext('data_table');
    await _filterToEu(engine);
    await tester.pump();
    final second = engine.holdNext('data_table');
    await engine.applyCommands([
      Commands.setGlobalFilter([
        {'op': 'gt', 'field': 'amount', 'value': 20},
      ]),
    ]);
    await tester.pump();

    // Release the newer read first, so the older one arrives last and would otherwise win.
    second.complete();
    await tester.pump();
    first.complete();
    await tester.pumpAndSettle();

    expect(find.text('2'), findsOneWidget, reason: 'amount > 20 matches 30 and 40');
    expect(_inTable(find.text('1–2 of 2')), findsOneWidget);
    expect(engine.reads.last.revision, engine.revision);
  });

  testWidgets('clearing the filter returns every component to the prior selection',
      (tester) async {
    final engine = _controller();
    await engine.open('w1');
    await _pumpRoute(tester, engine);
    await _filterToEu(engine);
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    final slow = engine.holdNext('records');
    await engine.applyCommands([Commands.setGlobalFilter(const [])]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_inTable(find.text('1–2 of 4')), findsOneWidget);
    expect(find.text('2'), findsNothing,
        reason: 'the card must not keep the filtered count while the table is restored');

    slow.complete();
    await tester.pumpAndSettle();
    expect(find.text('4'), findsOneWidget);
    expect(_inTable(find.text('1–2 of 4')), findsOneWidget);
  });
}
