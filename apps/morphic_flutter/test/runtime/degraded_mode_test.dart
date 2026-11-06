/// Degraded-mode rendering (M1.1 task 1.1.6).
///
/// A workspace whose source data is gone must still open, still show its real layout, and
/// say plainly why there is no data — not render an empty table that reads as a bad import,
/// and not crash. The notice text comes from the engine; Flutter never invents a cause.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/workspace_view.dart';

import '../support/scripted_bridge.dart';

const notice =
    'the imported source file is no longer available; re-import the same file to restore the data';

EngineController degradedController(ScriptedBridge bridge) =>
    EngineController(bridge: bridge, storageRoot: '/tmp/morphic');

Future<void> pumpView(WidgetTester tester, EngineController controller) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 420,
        height: 900,
        child: WorkspaceView(
          controller: controller,
          registry: ComponentRegistry(),
        ),
      ),
    ),
  ));
  // Explicit pumps: an in-flight page future must not make pumpAndSettle spin forever.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('controller', () {
    test('reads degraded and notice from the snapshot', () async {
      final bridge = ScriptedBridge(degraded: true, notice: notice);
      final c = degradedController(bridge);
      await c.open('w1');
      expect(c.degraded, isTrue);
      expect(c.notice, notice);
      expect(c.profile, isNull);
      expect(c.doc, isNotNull, reason: 'the layout must still load');
      expect(c.components, isNotEmpty);
      c.dispose();
    });

    test('a healthy snapshot is not degraded', () async {
      final c = degradedController(ScriptedBridge());
      await c.open('w1');
      expect(c.degraded, isFalse);
      expect(c.notice, isNull);
      expect(c.profile, isNotNull);
      c.dispose();
    });

    test('older engines without the flag are treated as healthy', () async {
      final bridge = ScriptedBridge();
      final c = degradedController(bridge);
      await c.open('w1');
      expect(c.degraded, isFalse, reason: 'absent flag must not mean degraded');
      c.dispose();
    });

    test('close clears degraded state', () async {
      final c = degradedController(ScriptedBridge(degraded: true, notice: notice));
      await c.open('w1');
      expect(c.degraded, isTrue);
      await c.closeWorkspace();
      expect(c.degraded, isFalse);
      expect(c.notice, isNull);
      c.dispose();
    });
  });

  group('workspace view', () {
    testWidgets('shows the engine notice above the layout', (tester) async {
      final bridge = ScriptedBridge(
        degraded: true,
        notice: notice,
        sourceUnavailable: true,
      );
      final c = degradedController(bridge);
      await c.open('w1');
      await pumpView(tester, c);

      expect(find.text(notice), findsWidgets);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(
        find.text('Sales'),
        findsNothing,
        reason: 'sanity: the notice is not the workspace title',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the generated layout is still rendered', (tester) async {
      final c = degradedController(
        ScriptedBridge(degraded: true, notice: notice, sourceUnavailable: true),
      );
      await c.open('w1');
      await pumpView(tester, c);
      // Metric cards are part of the document and must survive a missing source.
      expect(find.text('Records'), findsWidgets);
    });

    testWidgets('no banner when the data is present', (tester) async {
      final c = degradedController(ScriptedBridge());
      await c.open('w1');
      await pumpView(tester, c);
      expect(find.byType(DegradedNotice), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('a missing notice still explains the state', (tester) async {
      final c = degradedController(ScriptedBridge(degraded: true));
      await c.open('w1');
      await pumpView(tester, c);
      expect(
        find.text('This workspace opened without its source data.'),
        findsOneWidget,
      );
    });
  });
}
