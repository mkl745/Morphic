library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/metric_card_view.dart';

import '../support/scripted_bridge.dart';

ComponentContext _ctx(Map<String, dynamic> spec, EngineController engine) =>
    ComponentContext(spec: spec, engine: engine);

Map<String, dynamic> _spec({String op = 'count', String? field}) => {
      'id': 'total_records',
      'type': 'metric_card',
      'title': 'Records',
      'binding': {
        'kind': 'metric_card',
        'aggregation': {'op': op, 'field': field},
      },
      'explanation': {'detail': 'A record count orientates fastest.'},
    };

Future<EngineController> _open(ScriptedBridge bridge) async {
  final c = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await c.open('w1');
  return c;
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  testWidgets('the metric value has an independent meaningful semantic summary', (tester) async {
    final handle = tester.ensureSemantics();
    addTearDown(handle.dispose);
    final engine = await _open(ScriptedBridge(metrics: {'total_records': 17.5}));
    await tester.pumpWidget(
        _host(MetricCardView(ctx: _ctx(_spec(op: 'avg', field: 'amount'), engine))));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel(RegExp('Records, average · amount, 17.5')), findsOne);
  });

  testWidgets('the metric summary says no data rather than zero', (tester) async {
    final handle = tester.ensureSemantics();
    addTearDown(handle.dispose);
    final engine = await _open(ScriptedBridge(metrics: {'total_records': null}));
    await tester.pumpWidget(_host(MetricCardView(ctx: _ctx(_spec(), engine))));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel(RegExp('Records, count · rows, No data')), findsOne);
  });

  testWidgets('shows the value Rust computed, grouped for reading', (tester) async {
    final bridge = ScriptedBridge(metrics: {'total_records': 1234567});
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(MetricCardView(ctx: _ctx(_spec(), engine))));
    await tester.pump();

    expect(find.text('1,234,567'), findsOneWidget);
    expect(find.text('Records'), findsOneWidget);
    expect(find.text('count · rows'), findsOneWidget);
    expect(bridge.metricCalls, ['total_records']);
  });

  testWidgets('names the aggregation so the number is not ambiguous', (tester) async {
    final bridge = ScriptedBridge(metrics: {'total_records': 17.5});
    final engine = await _open(bridge);
    await tester.pumpWidget(
        _host(MetricCardView(ctx: _ctx(_spec(op: 'avg', field: 'amount'), engine))));
    await tester.pump();

    expect(find.text('17.5'), findsOneWidget);
    expect(find.text('average · amount'), findsOneWidget);
  });

  testWidgets('a null aggregate reads as no data, never as zero', (tester) async {
    final bridge = ScriptedBridge(metrics: {'total_records': null});
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(MetricCardView(ctx: _ctx(_spec(), engine))));
    await tester.pump();

    expect(find.text('—'), findsOneWidget);
    expect(find.text('No data for this metric'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('zero is rendered as zero, not as no data', (tester) async {
    final bridge = ScriptedBridge(metrics: {'total_records': 0});
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(MetricCardView(ctx: _ctx(_spec(), engine))));
    await tester.pump();

    expect(find.text('0'), findsOneWidget);
    expect(find.text('No data for this metric'), findsNothing);
  });

  testWidgets('loading state is visible while the engine has not answered',
      (tester) async {
    final engine = GatedEngineController(
        bridge: ScriptedBridge(), storageRoot: '/tmp/m');
    await tester.pumpWidget(_host(MetricCardView(ctx: _ctx(_spec(), engine))));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('—'), findsNothing);

    engine.metricGate.complete(42);
    await tester.pumpAndSettle();
    expect(find.text('42'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('an engine failure is an error state with a retry, not a blank card',
      (tester) async {
    final bridge = ScriptedBridge()..failMetric = true;
    final engine = await _open(bridge);
    await tester.pumpWidget(_host(MetricCardView(ctx: _ctx(_spec(), engine))));
    await tester.pump();

    // A failure must NOT be dressed up as "no data": null is a legitimate metric answer.
    expect(find.text('Could not compute this metric'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No data for this metric'), findsNothing);
    expect(engine.error, contains('not a metric'));

    // Retry re-asks the engine and recovers.
    bridge.failMetric = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('1,234'), findsOneWidget);
    expect(find.text('Could not compute this metric'), findsNothing);
  });

  testWidgets('the explanation from the compiler is shown', (tester) async {
    final engine = await _open(ScriptedBridge());
    await tester.pumpWidget(_host(MetricCardView(ctx: _ctx(_spec(), engine))));
    await tester.pump();

    expect(find.text('A record count orientates fastest.'), findsOneWidget);
  });
}
