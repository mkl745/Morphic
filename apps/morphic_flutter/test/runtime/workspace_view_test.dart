library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';
import 'package:morphic_flutter/runtime/components/deferred_component.dart';
import 'package:morphic_flutter/runtime/components/metric_card_view.dart';
import 'package:morphic_flutter/runtime/workspace_view.dart';

import '../support/scripted_bridge.dart';

Widget _host(Widget child, {Size size = const Size(420, 900)}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(body: SizedBox(width: size.width, height: size.height, child: child)),
      ),
    );

Map<String, dynamic> _metric(String id, String title) => {
      'id': id,
      'type': 'metric_card',
      'title': title,
      'binding': {
        'kind': 'metric_card',
        'aggregation': {'op': 'count', 'field': null},
      },
    };

Map<String, dynamic> _chart(String id, String type) => {
      'id': id,
      'type': type,
      'title': '$type title',
      'binding': {'kind': type},
      'explanation': {'detail': 'Chosen because the data is temporal.'},
    };

void main() {
  testWidgets('renders in layout.order, not document order', (tester) async {
    final bridge = ScriptedBridge(
      metrics: {'m1': 1},
      components: [_metric('m1', 'First'), _chart('c1', 'timeline')],
      // Document order is m1 then c1; layout deliberately reverses them.
      order: ['c1', 'm1'],
    );
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_host(WorkspaceView(
      controller: engine,
      registry: ComponentRegistry(),
    )));
    await tester.pumpAndSettle();

    final chartY = tester.getTopLeft(find.byType(DeferredComponent)).dy;
    final metricY = tester.getTopLeft(find.byType(MetricCardView)).dy;
    expect(chartY, lessThan(metricY),
        reason: 'the engine chose the order; the runtime must not re-sort it');
  });

  testWidgets('metric cards flow into two columns on a wide viewport', (tester) async {
    final bridge = ScriptedBridge(
      metrics: {'m1': 1, 'm2': 2},
      components: [_metric('m1', 'One'), _metric('m2', 'Two')],
      order: ['m1', 'm2'],
    );
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_host(
      WorkspaceView(controller: engine, registry: ComponentRegistry()),
      size: const Size(900, 900),
    ));
    await tester.pumpAndSettle();

    final a = tester.getTopLeft(find.byType(MetricCardView).first);
    final b = tester.getTopLeft(find.byType(MetricCardView).last);
    expect(a.dy, closeTo(b.dy, 0.5), reason: 'side by side on a wide viewport');
    expect(b.dx, greaterThan(a.dx));
  });

  testWidgets('metric cards stack on a phone-width viewport', (tester) async {
    final bridge = ScriptedBridge(
      metrics: {'m1': 1, 'm2': 2},
      components: [_metric('m1', 'One'), _metric('m2', 'Two')],
      order: ['m1', 'm2'],
    );
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_host(
      WorkspaceView(controller: engine, registry: ComponentRegistry()),
      size: const Size(390, 900),
    ));
    await tester.pumpAndSettle();

    final a = tester.getTopLeft(find.byType(MetricCardView).first);
    final b = tester.getTopLeft(find.byType(MetricCardView).last);
    expect(b.dy, greaterThan(a.dy), reason: 'stacked on a narrow viewport');
  });

  testWidgets('a chart the runtime cannot draw is labelled, not dropped', (tester) async {
    final bridge = ScriptedBridge(
      components: [_chart('c1', 'timeline')],
      order: ['c1'],
    );
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_host(WorkspaceView(
      controller: engine,
      registry: ComponentRegistry(),
    )));
    await tester.pumpAndSettle();

    expect(find.byType(DeferredComponent), findsOneWidget);
    // The headline is visible while collapsed, so the component is never silent.
    expect(find.text('timeline renders in M1.4'), findsOneWidget);
    // The long rationale is behind a tap, keeping the data table above the fold.
    expect(find.textContaining('Why this was generated:'), findsNothing);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('Why this was generated:'), findsOneWidget);
  });

  testWidgets('an unknown type is reported as unknown, not as scheduled', (tester) async {
    final bridge = ScriptedBridge(
      components: [_chart('x1', 'hologram')],
      order: ['x1'],
    );
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_host(WorkspaceView(
      controller: engine,
      registry: ComponentRegistry(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Unknown component type “hologram”'), findsOneWidget);
    expect(find.textContaining('renders in'), findsNothing);
  });

  testWidgets('a reserved type is reported as a validation problem', (tester) async {
    final bridge = ScriptedBridge(
      components: [_chart('x1', 'pie_chart')],
      order: ['x1'],
    );
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_host(WorkspaceView(
      controller: engine,
      registry: ComponentRegistry(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('pie_chart is reserved'), findsOneWidget);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('did not pass validation'), findsOneWidget);
  });

  testWidgets('no workspace open is an explicit empty state', (tester) async {
    final engine = EngineController(
        bridge: ScriptedBridge(), storageRoot: '/tmp/m');
    await tester.pumpWidget(_host(WorkspaceView(
      controller: engine,
      registry: ComponentRegistry(),
    )));
    await tester.pumpAndSettle();
    expect(find.text('No workspace open.'), findsOneWidget);
  });

  testWidgets('a failed open shows the error and a retry that works', (tester) async {
    final bridge = ScriptedBridge()..failSnapshot = true;
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    expect(await engine.open('w1'), isFalse);
    await tester.pumpWidget(_host(WorkspaceView(
      controller: engine,
      registry: ComponentRegistry(),
      onRetry: () async {
        bridge.failSnapshot = false;
        await engine.open('w1');
      },
    )));
    await tester.pumpAndSettle();

    expect(find.text('Could not open this workspace'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a document with no components says the engine generated none',
      (tester) async {
    final bridge = ScriptedBridge(components: [], order: []);
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_host(WorkspaceView(
      controller: engine,
      registry: ComponentRegistry(),
    )));
    await tester.pumpAndSettle();
    expect(find.text('The engine generated no components for this file.'),
        findsOneWidget);
  });

  testWidgets('a full generated workspace renders metric + table together',
      (tester) async {
    final bridge = ScriptedBridge(metrics: {'total_records': 4});
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_host(WorkspaceView(
      controller: engine,
      registry: ComponentRegistry(),
    )));
    await tester.pumpAndSettle();

    expect(find.byType(MetricCardView), findsOneWidget);
    expect(find.byType(DataTableView), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('eu'), findsOneWidget);
  });

  // Deliberately a renderable type: an override must beat the real painter, not just a
  // placeholder. Until 1.4.3 this only proved the weaker case.
  testWidgets('an injected registry override is honoured', (tester) async {
    final bridge = ScriptedBridge(
      components: [_chart('c1', 'line_chart')],
      order: ['c1'],
    );
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(_host(WorkspaceView(
      controller: engine,
      registry: ComponentRegistry(
        overrides: {'line_chart': (_) => const Text('custom painter')},
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.text('custom painter'), findsOneWidget);
    expect(find.byType(DeferredComponent), findsNothing);
  });
}
