/// 1.4.7 UI contract: the engine decides which switches exist, a table -> chart switch asks
/// for confirmation, and every switch is one `changeComponentType` command (never a local
/// edit of the document).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/change_type_button.dart';

import '../support/scripted_bridge.dart';

Future<EngineController> _open(ScriptedBridge bridge) async {
  final engine = EngineController(bridge: bridge, storageRoot: 'root');
  final ok = await engine.open('w1');
  expect(ok, isTrue, reason: 'the scripted snapshot should open');
  return engine;
}

Widget _app(EngineController engine, {required String id, required String type}) =>
    MaterialApp(
      home: Scaffold(
        body: ChangeTypeButton(engine: engine, id: id, type: type),
      ),
    );

void main() {
  test('the controller reads typeOptions from the engine snapshot', () async {
    final engine = await _open(ScriptedBridge(
      typeOptions: const <String, List<String>>{
        'c1': <String>['bar_chart', 'metric_card'],
      },
    ));
    expect(engine.typeOptionsFor('c1'), <String>['bar_chart', 'metric_card']);
    expect(engine.typeOptionsFor('missing'), isEmpty);
  });

  testWidgets('an older snapshot without typeOptions shows no button', (tester) async {
    final engine = await _open(ScriptedBridge());
    await tester.pumpWidget(_app(engine, id: 'data_table', type: 'data_table'));
    expect(find.byKey(const Key('change-type-data_table')), findsNothing);
  });

  testWidgets('a table -> chart switch asks for confirmation, then sends one command',
      (tester) async {
    final bridge = ScriptedBridge(
      typeOptions: const <String, List<String>>{
        'data_table': <String>['bar_chart', 'metric_card'],
      },
    );
    final engine = await _open(bridge);
    await tester.pumpWidget(_app(engine, id: 'data_table', type: 'data_table'));

    expect(find.byKey(const Key('change-type-data_table')), findsOneWidget);
    await tester.tap(find.byKey(const Key('change-type-data_table')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('change-type-option-bar_chart')), findsOneWidget);

    await tester.tap(find.byKey(const Key('change-type-option-bar_chart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('change-type-confirm')), findsOneWidget);
    expect(find.text('Switch to a chart?'), findsOneWidget);
    expect(bridge.commandBatches, isEmpty,
        reason: 'no command may be sent before the person confirms');

    await tester.tap(find.byKey(const Key('change-type-confirm-button')));
    await tester.pumpAndSettle();
    expect(bridge.commandBatches, hasLength(1));
    final command = bridge.commandBatches.single.single;
    expect(command['kind'], 'changeComponentType');
    expect(command['componentId'], 'data_table');
    expect(command['targetType'], 'bar_chart');
    expect(find.byKey(const Key('change-type-done')), findsOneWidget);
  });

  testWidgets('a cancelled confirmation sends nothing', (tester) async {
    final bridge = ScriptedBridge(
      typeOptions: const <String, List<String>>{
        'data_table': <String>['line_chart'],
      },
    );
    final engine = await _open(bridge);
    await tester.pumpWidget(_app(engine, id: 'data_table', type: 'data_table'));
    await tester.tap(find.byKey(const Key('change-type-data_table')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('change-type-option-line_chart')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('change-type-cancel')));
    await tester.pumpAndSettle();
    expect(bridge.commandBatches, isEmpty);
    expect(find.byKey(const Key('change-type-done')), findsNothing);
  });

  testWidgets('a non-table switch is immediate and sends the chosen target',
      (tester) async {
    final bridge = ScriptedBridge(
      typeOptions: const <String, List<String>>{
        'total_records': <String>['data_table'],
      },
    );
    final engine = await _open(bridge);
    await tester.pumpWidget(
        _app(engine, id: 'total_records', type: 'metric_card'));
    await tester.tap(find.byKey(const Key('change-type-total_records')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('change-type-option-data_table')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('change-type-confirm')), findsNothing,
        reason: 'only data_table -> chart needs a confirmation');
    expect(bridge.commandBatches.single.single['targetType'], 'data_table');
  });

  testWidgets('a refused switch shows the engine error instead of a fake success',
      (tester) async {
    final bridge = ScriptedBridge(
      typeOptions: const <String, List<String>>{
        'total_records': <String>['data_table'],
      },
    )..failCommands = true;
    final engine = await _open(bridge);
    await tester.pumpWidget(
        _app(engine, id: 'total_records', type: 'metric_card'));
    await tester.tap(find.byKey(const Key('change-type-total_records')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('change-type-option-data_table')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('change-type-error')), findsOneWidget);
    expect(find.textContaining('filter references unknown field'), findsOneWidget);
    expect(find.byKey(const Key('change-type-done')), findsNothing);
  });
}
