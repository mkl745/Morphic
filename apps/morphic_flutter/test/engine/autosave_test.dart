/// Autosave hardening and recovery UI (M1.5 task 1.5.4).
///
/// The Rust engine persists every command synchronously. These tests pin the three layers
/// Flutter adds: a two-second *checkpoint* debounce, an immediate flush on lifecycle pause,
/// and an honest dialog describing what startup recovery actually repaired.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/app.dart';
import 'package:morphic_flutter/engine/autosave.dart';
import 'package:morphic_flutter/engine/bridge.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';

import '../support/scripted_bridge.dart';

const _recoveryKey = Key('recovery-dialog');
const _dismissKey = Key('recovery-dismiss-button');

void main() {
  test('the recovery report decodes the engine JSON and never invents damage', () {
    const clean = RecoveryReport();
    expect(clean.isClean, isTrue);
    expect(clean.messages, isEmpty);

    final report = RecoveryReport.fromJson(const {
      'sweptTmp': 2,
      'tornJournalLines': 1,
      'restoredFromJournal': true,
      'quarantined': true,
      'migratedLegacySource': true,
      'rebuiltLibraryIndex': true,
    });
    expect(report.isClean, isFalse);
    expect(report.sweptTmp, 2);
    expect(report.restoredFromJournal, isTrue);
    expect(report.rebuiltLibraryIndex, isTrue);
    expect(report.messages.length, 6);
    expect(
      report.messages.last,
      contains('Rebuilt the workspace index'),
    );
    expect(report.messages.first, contains('Restored the last edit'));
    expect(report.toJson()['migratedLegacySource'], isTrue);
  });

  test('a checkpoint clears the flag and closeSession flushes a pending one', () async {
    final bridge = ScriptedBridge();
    final controller = EngineController(
      bridge: bridge,
      storageRoot: '/tmp/morphic-autosave-test',
    );
    await controller.open('w1');
    expect(controller.dirty, isFalse, reason: 'a fresh snapshot is clean');

    await controller.applyCommands([
      Commands.setSearch('data_table', 'eu'),
    ]);
    expect(controller.dirty, isTrue);
    expect(bridge.saveCalls, isEmpty);

    expect(await controller.save(), isTrue);
    expect(controller.dirty, isFalse);
    expect(bridge.saveCalls, ['w1']);

    await controller.applyCommands([
      Commands.setSearch('data_table', 'us'),
    ]);
    await controller.closeWorkspace();
    expect(bridge.saveCalls, ['w1', 'w1']);
    expect(controller.workspaceId, isNull);
  });

  testWidgets('the debounce waits two seconds and a pause flushes immediately',
      (tester) async {
    // Pump a trivial widget so the fake-async clock can be advanced with tester.pump.
    await tester.pumpWidget(const SizedBox.shrink());

    final bridge = ScriptedBridge();
    final controller = EngineController(
      bridge: bridge,
      storageRoot: '/tmp/morphic-autosave-timer',
    );
    final coordinator = AutosaveCoordinator();
    coordinator.watch(controller);
    addTearDown(coordinator.dispose);

    await controller.open('w1');
    await controller.applyCommands([
      Commands.setSearch('data_table', 'eu'),
    ]);
    expect(controller.dirty, isTrue);

    await tester.pump(const Duration(milliseconds: 1999));
    expect(bridge.saveCalls, isEmpty, reason: 'the debounce has not elapsed');
    await tester.pump(const Duration(milliseconds: 1));
    expect(bridge.saveCalls, ['w1']);
    expect(controller.dirty, isFalse);

    // A lifecycle pause does not wait for another two seconds.
    await controller.applyCommands([
      Commands.setSearch('data_table', 'us'),
    ]);
    expect(bridge.saveCalls.length, 1);
    await coordinator.flushNow();
    expect(bridge.saveCalls.length, 2);
    expect(controller.dirty, isFalse);
  });

  testWidgets('a clean startup shows no recovery dialog', (tester) async {
    await tester.pumpWidget(MorphicApp(
      bridge: ScriptedBridge(),
      storageRoot: '/tmp/morphic-clean-start',
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(_recoveryKey), findsNothing);
  });

  testWidgets('startup recovery is reported to the user, not silently hidden',
      (tester) async {
    final bridge = ScriptedBridge()
      ..recovery = const RecoveryReport(
        restoredFromJournal: true,
        sweptTmp: 2,
        quarantined: true,
      );
    await tester.pumpWidget(MorphicApp(
      bridge: bridge,
      storageRoot: '/tmp/morphic-recovered-start',
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(_recoveryKey), findsOneWidget);
    expect(find.text('Workspace recovered'), findsOneWidget);
    expect(find.textContaining('Restored the last edit'), findsOneWidget);
    expect(find.textContaining('Discarded 2 interrupted writes'), findsOneWidget);
    expect(
      find.textContaining('workspace.corrupt.json'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(_dismissKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_recoveryKey), findsNothing);
    // The report is captured once; dismissing does not try to show it again.
    expect(bridge.saveCalls, isEmpty);
  });
}
