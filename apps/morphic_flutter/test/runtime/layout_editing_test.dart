/// Manual layout editing is a wire contract, not a second layout engine (M1.5 task 1.5.2).
///
/// These widget tests pump the production app bar / workspace view and assert that the drag
/// handle and pinch-free resize menu emit `moveComponent` / `resizeComponent` commands, while
/// the rendered geometry comes back from `layout.hints`. Focus mode is deliberately a phone
/// view convenience only: it changes which component is painted, never the persisted document.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/features/workspace/workspace_screen.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/workspace_view.dart';

import '../support/scripted_bridge.dart';

Map<String, dynamic> _spec(String id, String type) => <String, dynamic>{
      'id': id,
      'type': type,
      'title': 'Title $id',
      'binding': <String, dynamic>{'kind': type},
    };

ComponentRegistry _registry() => ComponentRegistry(
      overrides: <String, ComponentBuilder>{
        for (final type in <String>['metric_card', 'data_table'])
          type: (ctx) => Container(
                key: Key('paint-${ctx.id}'),
                width: double.infinity,
                height: 120,
                color: Colors.teal,
                child: Center(child: Text('painted ${ctx.id}')),
              ),
      },
    );

Widget _host(Widget home, {Size size = const Size(390, 900)}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: home,
      ),
    );

Widget _viewHost(Widget view, {Size size = const Size(900, 900)}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(
          body: SizedBox(width: size.width, height: size.height, child: view),
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget home) async {
  await tester.pumpWidget(home);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _afterTap(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('a persisted layout hint changes span and height', (tester) async {
    final bridge = ScriptedBridge(
      components: <Map<String, dynamic>>[_spec('m1', 'metric_card')],
      order: <String>['m1'],
      hints: <Map<String, dynamic>>[
        <String, dynamic>{
          'componentId': 'm1',
          'span': 2,
          'height': 'large',
        },
      ],
    );
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await controller.open('w1');
    await _pump(
      tester,
      _viewHost(
        WorkspaceView(controller: controller, registry: _registry()),
      ),
    );

    final painted = find.byKey(const Key('paint-m1'));
    expect(painted, findsOneWidget);
    final size = tester.getSize(painted);
    // 900 dp viewport -> 868 dp content, two 428 dp columns + 12 dp gap = 868 dp.
    expect(size.width, greaterThan(700), reason: 'span 2 fills both columns');
    expect(size.height, 560, reason: 'the large height hint is applied');
  });

  testWidgets('the resize menu sends one engine command', (tester) async {
    final bridge = ScriptedBridge(
      components: <Map<String, dynamic>>[
        _spec('m1', 'metric_card'),
        _spec('t1', 'data_table'),
      ],
      order: <String>['m1', 't1'],
    );
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await controller.open('w1');
    await _pump(
      tester,
      _host(
        WorkspaceScreen(controller: controller, registry: _registry()),
        size: const Size(900, 900),
      ),
    );

    await tester.tap(find.byKey(const Key('layout-edit-button')));
    await _afterTap(tester);
    expect(find.byKey(const Key('layout-menu-t1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('layout-menu-t1')));
    await _afterTap(tester);
    await tester.tap(find.text('Span 2'));
    await _afterTap(tester);

    final command = bridge.commandBatches.last.single;
    expect(command['kind'], 'resizeComponent');
    expect(command['componentId'], 't1');
    expect(command['span'], 2);
    expect(command.containsKey('height'), isFalse);
    expect(bridge.hints.single['span'], 2);
    expect(find.text('span 2 · height auto'), findsOneWidget);
  });

  testWidgets('a long-press drag reorders through a command', (tester) async {
    final bridge = ScriptedBridge(
      components: <Map<String, dynamic>>[
        _spec('m1', 'metric_card'),
        _spec('t1', 'data_table'),
      ],
      order: <String>['m1', 't1'],
    );
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await controller.open('w1');
    await _pump(
      tester,
      _host(
        WorkspaceScreen(controller: controller, registry: _registry()),
      ),
    );

    await tester.tap(find.byKey(const Key('layout-edit-button')));
    await _afterTap(tester);
    final handle = find.byKey(const Key('layout-drag-m1'));
    expect(handle, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    final command = bridge.commandBatches.last.single;
    expect(command['kind'], 'moveComponent');
    expect(command['componentId'], 'm1');
    expect(bridge.order, <String>['t1', 'm1']);
  });

  testWidgets('phone focus mode paints one component at a time', (tester) async {
    final bridge = ScriptedBridge(
      components: <Map<String, dynamic>>[
        _spec('m1', 'metric_card'),
        _spec('t1', 'data_table'),
      ],
      order: <String>['m1', 't1'],
    );
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await controller.open('w1');
    await _pump(
      tester,
      _host(
        WorkspaceScreen(controller: controller, registry: _registry()),
      ),
    );

    expect(find.byKey(const Key('focus-mode-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('focus-mode-button')));
    await _afterTap(tester);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.text('painted m1'), findsOneWidget);
    expect(find.text('painted t1'), findsNothing);

    await tester.tap(find.byKey(const Key('focus-next-button')));
    await _afterTap(tester);
    expect(find.text('2 of 2'), findsOneWidget);
    expect(find.text('painted t1'), findsOneWidget);
    expect(find.text('painted m1'), findsNothing);
    expect(bridge.commandBatches, isEmpty,
        reason: 'focus mode is a view convenience, not a persisted command');
  });
}
