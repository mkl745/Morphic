/// App-bar undo/redo controls are engine-driven, not a local UI guess (M1.5 task 1.5.1).
///
/// The scripted bridge stands in for Rust's bounded stacks; the assertions are about the
/// contract — disabled at depth zero, enabled after a command, and a snackbar carrying the
/// engine's own label — not about a second undo implementation in Dart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';
import 'package:morphic_flutter/features/workspace/workspace_screen.dart';

import '../support/scripted_bridge.dart';

Future<void> _pump(WidgetTester tester, Widget home) async {
  await tester.pumpWidget(MaterialApp(home: home));
  // Explicit pumps: the workspace view can show a spinner while its first page resolves,
  // and a continuously animating progress indicator never lets `pumpAndSettle` finish.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _afterTap(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

IconButton _button(WidgetTester tester, String key) =>
    tester.widget<IconButton>(find.byKey(Key(key)));

void main() {
  testWidgets('undo and redo follow engine depth and show engine labels', (tester) async {
    final bridge = ScriptedBridge();
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await controller.open('w1');
    await _pump(tester, WorkspaceScreen(controller: controller));

    expect(_button(tester, 'undo-button').onPressed, isNull);
    expect(_button(tester, 'redo-button').onPressed, isNull);
    expect(find.byKey(const Key('undo-snackbar')), findsNothing);

    await controller.applyCommands([
      Commands.setGlobalFilter([
        filterNode('eq', field: 'region', value: 'eu'),
      ]),
    ]);
    await tester.pump();
    expect(controller.undoDepth, 1);
    expect(_button(tester, 'undo-button').onPressed, isNotNull);
    expect(_button(tester, 'redo-button').onPressed, isNull);

    await tester.tap(find.byKey(const Key('undo-button')));
    await _afterTap(tester);
    expect(find.byKey(const Key('undo-snackbar')), findsOneWidget);
    expect(find.text('Undid Applied changes'), findsOneWidget);
    expect(controller.redoDepth, 1);
    expect(_button(tester, 'redo-button').onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('redo-button')));
    await _afterTap(tester);
    expect(find.byKey(const Key('redo-snackbar')), findsOneWidget);
    expect(find.text('Redid Applied changes'), findsOneWidget);
    expect(controller.undoDepth, 1);
    expect(controller.redoDepth, 0);
  });

  testWidgets('a failed undo surfaces the engine error in the snackbar', (tester) async {
    final bridge = ScriptedBridge();
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await controller.open('w1');
    await controller.applyCommands([
      Commands.setGlobalFilter([
        filterNode('eq', field: 'region', value: 'eu'),
      ]),
    ]);
    bridge.failUndo = true;
    await _pump(tester, WorkspaceScreen(controller: controller));

    await tester.tap(find.byKey(const Key('undo-button')));
    await _afterTap(tester);
    expect(find.byKey(const Key('undo-snackbar')), findsOneWidget);
    expect(find.textContaining('undo: no history available'), findsOneWidget);
    expect(controller.undoDepth, 1, reason: 'a rejected undo changes no history');
  });
}
