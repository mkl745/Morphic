/// The live title is a command, never the library API that resets an open session's history.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';
import 'package:morphic_flutter/features/workspace/workspace_screen.dart';

import '../support/scripted_bridge.dart';

Future<void> _pump(WidgetTester tester, EngineController engine) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: MorphicTheme.light(),
    home: WorkspaceScreen(controller: engine),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('rename preserves prior edits and undo; checkpoint status stays truthful',
      (tester) async {
    final bridge = ScriptedBridge();
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await engine.applyCommands([
      Commands.setGlobalFilter([filterNode('eq', field: 'region', value: 'eu')]),
    ]);
    await _pump(tester, engine);
    expect(find.text('Saved locally · checkpoint pending'), findsOneWidget);
    expect(engine.undoDepth, 1);

    await tester.tap(find.byKey(const Key('workspace-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('workspace-title-input')), '  ');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('workspace-title-save'))).onPressed,
        isNull,
        reason: 'empty titles cannot be submitted');
    await tester.enterText(find.byKey(const Key('workspace-title-input')), '  Sales review  ');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('workspace-title-save'))).onPressed,
        isNotNull);
    await tester.tap(find.byKey(const Key('workspace-title-save')));
    await tester.pumpAndSettle();

    expect(bridge.commandBatches.last, [Commands.renameWorkspace('Sales review')]);
    expect(bridge.libraryCalls, isEmpty, reason: 'do not use the session-resetting library API');
    expect(engine.doc!['workspace']['title'], 'Sales review');
    expect(engine.undoDepth, 2, reason: 'the pre-existing filter remains in history');
    expect(find.text('Sales review'), findsOneWidget);
    expect(engine.globalFilters, isNotEmpty);

    await engine.undo();
    await tester.pumpAndSettle();
    expect(engine.doc!['workspace']['title'], 'Scripted');
    expect(engine.globalFilters, isNotEmpty, reason: 'undoing rename must not undo the filter');
    expect(engine.redoDepth, 1);
    await engine.redo();
    await tester.pumpAndSettle();
    expect(engine.doc!['workspace']['title'], 'Sales review');
    expect(engine.globalFilters, isNotEmpty);

    expect(await engine.save(), isTrue);
    await tester.pump();
    expect(find.text('Saved locally'), findsOneWidget);
    expect(find.textContaining('unsaved'), findsNothing);
  });

  testWidgets('a rejected rename keeps the title and displays engine evidence', (tester) async {
    final bridge = ScriptedBridge()..failCommands = true;
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await _pump(tester, engine);
    await tester.tap(find.byKey(const Key('workspace-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('workspace-title-input')), 'New title');
    await tester.pump();
    await tester.tap(find.byKey(const Key('workspace-title-save')));
    await tester.pumpAndSettle();
    expect(engine.doc!['workspace']['title'], 'Scripted');
    expect(find.textContaining('Could not rename workspace'), findsOneWidget);
    expect(find.textContaining(bridge.commandError), findsOneWidget);
    expect(engine.undoDepth, 0);
  });
}
