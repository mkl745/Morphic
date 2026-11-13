/// Degraded-mode recovery affordance (M1.5 task 1.5.3, AT-16).
///
/// The notice alone is not enough: a workspace that opened without its source must offer a
/// one-tap re-link. The picked bytes go to the Rust bridge, which verifies them against the
/// dataset hash; only then is the session reopened so the live data comes back.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/file_source.dart';
import 'package:morphic_flutter/features/workspace/workspace_screen.dart';

import '../support/fake_import.dart';
import '../support/scripted_bridge.dart';

const _notice =
    'the imported source file is no longer available; re-import the same file to restore the data';

class _MissingDocumentBridge extends ScriptedBridge {
  _MissingDocumentBridge() : super(degraded: true, notice: _notice);

  @override
  Map<String, dynamic> snapshot({required String storageRoot, required String workspaceId}) {
    final snapshot = super.snapshot(storageRoot: storageRoot, workspaceId: workspaceId);
    if (degraded) snapshot['doc'] = null;
    return snapshot;
  }
}

Widget _host(Widget home, {Size size = const Size(420, 900)}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: SizedBox(width: size.width, height: size.height, child: home),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget home) async {
  await tester.pumpWidget(home);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('a degraded workspace offers a working re-link action', (tester) async {
    final bridge = ScriptedBridge(degraded: true, notice: _notice);
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/morphic');
    await controller.open('w1');
    final bytes = Uint8List.fromList(utf8.encode('region,amount\neu,10\n'));
    final source = FakeFileSource(
      file: PickedFile(name: 'sales.csv', bytes: bytes),
    );

    await _pump(
      tester,
      _host(WorkspaceScreen(controller: controller, fileSource: source),
          size: const Size(800, 900)),
    );
    // The actual engine has no profile or page in degraded mode: its notice explains why,
    // while the table reports the failed query rather than presenting invented null cells.
    expect(find.text(_notice), findsWidgets);
    expect(find.text('Could not load rows'), findsOneWidget);
    expect(find.textContaining('source data for workspace'), findsWidgets);
    expect(find.textContaining('Source column information'), findsNothing);
    expect(find.semantics.byLabel(RegExp('^Row 1:')), findsNothing);
    expect(find.byKey(const Key('restore-source-button')), findsOneWidget);
    expect(
      find.byKey(const Key('restore-source-notice-button')),
      findsOneWidget,
      reason: 'the notice itself must offer the recovery action',
    );

    await tester.tap(find.byKey(const Key('restore-source-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(source.calls, 1);
    expect(bridge.lastRelinkBytes, bytes);
    expect(bridge.libraryCalls, ['relink:w1']);
    expect(controller.degraded, isFalse);
    expect(find.byKey(const Key('restore-source-button')), findsNothing);
    expect(find.text('Source data restored'), findsOneWidget);
    final row = find.byKey(const Key('table-row-1'));
    await tester.ensureVisible(row);
    await tester.pump();
    expect(find.semantics.byLabel('Row 1: region: eu, amount: 10, note: No value'), findsOne);
    expect(find.text('Could not load rows'), findsNothing);
  });

  testWidgets('a rejected re-link keeps degraded mode and shows the error', (tester) async {
    final bridge = ScriptedBridge(degraded: true, notice: _notice)
      ..rejectRelink = true;
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/morphic');
    await controller.open('w1');
    final source = FakeFileSource(
      file: PickedFile(
        name: 'other.csv',
        bytes: Uint8List.fromList(utf8.encode('region,amount\nus,99\n')),
      ),
    );

    await _pump(
      tester,
      _host(WorkspaceScreen(controller: controller, fileSource: source),
          size: const Size(800, 900)),
    );
    await tester.tap(find.byKey(const Key('restore-source-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Could not restore source'), findsOneWidget);
    expect(controller.degraded, isTrue);
    expect(find.byKey(const Key('restore-source-button')), findsOneWidget);
  });

  testWidgets('the notice button is a second way to re-link', (tester) async {
    final bridge = ScriptedBridge(degraded: true, notice: _notice);
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/morphic');
    await controller.open('w1');
    final source = FakeFileSource(
      file: PickedFile(
        name: 'sales.csv',
        bytes: Uint8List.fromList(utf8.encode('region,amount\neu,10\n')),
      ),
    );
    await _pump(
      tester,
      _host(WorkspaceScreen(controller: controller, fileSource: source)),
    );
    expect(find.byKey(const Key('restore-source-button')), findsNothing,
        reason: 'compact chrome uses the notice action instead of a duplicate');
    await tester.tap(find.byKey(const Key('restore-source-notice-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(bridge.libraryCalls, ['relink:w1']);
    expect(controller.degraded, isFalse);
  });

  testWidgets('compact recovery remains available when there are no components', (tester) async {
    tester.view.physicalSize = const Size(360, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = ScriptedBridge(
      degraded: true,
      notice: _notice,
      components: [],
      order: [],
    );
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/morphic');
    await controller.open('w1');
    final bytes = Uint8List.fromList(utf8.encode('region,amount\neu,10\n'));
    final source = FakeFileSource(file: PickedFile(name: 'sales.csv', bytes: bytes));

    await _pump(
      tester,
      _host(WorkspaceScreen(controller: controller, fileSource: source),
          size: const Size(360, 844)),
    );
    expect(find.text(_notice), findsOneWidget);
    expect(find.text('The engine generated no components for this file.'), findsOneWidget);
    expect(find.byKey(const Key('restore-source-button')), findsNothing);
    await tester.tap(find.byKey(const Key('restore-source-notice-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(bridge.libraryCalls, ['relink:w1']);
    expect(bridge.lastRelinkBytes, bytes);
    expect(controller.degraded, isFalse);
    expect(find.byKey(const Key('restore-source-notice-button')), findsNothing);
    expect(find.text('The engine generated no components for this file.'), findsOneWidget);
  });

  testWidgets('compact chrome retains a restore fallback if the document is absent',
      (tester) async {
    tester.view.physicalSize = const Size(360, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = _MissingDocumentBridge();
    final controller = EngineController(bridge: bridge, storageRoot: '/tmp/morphic');
    await controller.open('w1');
    final bytes = Uint8List.fromList(utf8.encode('region,amount\neu,10\n'));
    final source = FakeFileSource(file: PickedFile(name: 'sales.csv', bytes: bytes));

    await _pump(
      tester,
      _host(WorkspaceScreen(controller: controller, fileSource: source),
          size: const Size(360, 844)),
    );
    expect(find.byKey(const Key('restore-source-notice-button')), findsNothing);
    await tester.tap(find.byKey(const Key('restore-source-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(bridge.libraryCalls, ['relink:w1']);
    expect(bridge.lastRelinkBytes, bytes);
    expect(controller.degraded, isFalse);
    expect(find.byKey(const Key('restore-source-button')), findsNothing);
  });

  testWidgets('no restore action on a healthy workspace', (tester) async {
    final controller = EngineController(
      bridge: ScriptedBridge(),
      storageRoot: '/tmp/morphic',
    );
    await controller.open('w1');
    await _pump(tester, _host(WorkspaceScreen(controller: controller)));
    expect(find.byKey(const Key('restore-source-button')), findsNothing);
  });
}
