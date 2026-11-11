/// Home library lifecycle (M1.5 task 1.5.3).
///
/// These tests pin the important boundary: the screen asks the Rust bridge to rename,
/// duplicate, delete and re-link, then reloads the library from the engine. It never edits
/// the index in Dart. A bridge rejection is surfaced, never swallowed, and a cancelled
/// dialog or file picker makes no call at all.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/app.dart';
import 'package:morphic_flutter/engine/file_source.dart';

import 'support/fake_import.dart';
import 'support/scripted_bridge.dart';

const _menuKey = ValueKey('workspace-menu-w1');

Future<void> pumpHome(
  WidgetTester tester,
  ScriptedBridge bridge, {
  PlatformFileSource? fileSource,
}) async {
  await tester.pumpWidget(MorphicApp(
    bridge: bridge,
    storageRoot: '/tmp/morphic-home-test',
    fileSource: fileSource ?? FakeFileSource(),
  ));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(_menuKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the library lists the engine\'s workspaces', (tester) async {
    final bridge = ScriptedBridge();
    await pumpHome(tester, bridge);
    expect(find.text('Saved workspace'), findsOneWidget);
    expect(find.text('w1'), findsOneWidget);
    expect(find.textContaining('bridge API v10'), findsOneWidget);
  });

  testWidgets('rename sends the new title and reloads the library', (tester) async {
    final bridge = ScriptedBridge();
    await pumpHome(tester, bridge);
    await choose(tester, 'Rename');
    expect(find.text('Rename workspace'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Quarterly sales');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(bridge.libraryCalls, ['rename:w1:Quarterly sales']);
    expect(bridge.workspaceIndex.single['title'], 'Quarterly sales');
    expect(find.text('Quarterly sales'), findsOneWidget);
    expect(find.text('Renamed to Quarterly sales'), findsOneWidget);
  });

  testWidgets('cancelling rename makes no bridge call', (tester) async {
    final bridge = ScriptedBridge();
    await pumpHome(tester, bridge);
    await choose(tester, 'Rename');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(bridge.libraryCalls, isEmpty);
  });

  testWidgets('duplicate adds an independent row', (tester) async {
    final bridge = ScriptedBridge();
    await pumpHome(tester, bridge);
    await choose(tester, 'Duplicate');
    expect(bridge.libraryCalls.single, startsWith('duplicate:w1:'));
    expect(bridge.workspaceIndex.length, 2);
    expect(find.text('Saved workspace copy'), findsOneWidget);
  });

  testWidgets('delete asks first, then removes the row', (tester) async {
    final bridge = ScriptedBridge();
    await pumpHome(tester, bridge);
    await choose(tester, 'Delete');
    expect(find.text('Delete workspace?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(bridge.libraryCalls, isEmpty, reason: 'cancel must not delete');

    await choose(tester, 'Delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(bridge.libraryCalls, ['delete:w1']);
    expect(bridge.workspaceIndex, isEmpty);
    expect(find.textContaining('No workspaces yet'), findsOneWidget);
  });

  testWidgets('re-link sends the picked file bytes to the engine', (tester) async {
    final bridge = ScriptedBridge();
    final bytes = Uint8List.fromList(utf8.encode('region,amount\neu,10\n'));
    final source = FakeFileSource(
      file: PickedFile(name: 'sales.csv', bytes: bytes),
    );
    await pumpHome(tester, bridge, fileSource: source);
    await choose(tester, 'Re-link source file');
    expect(source.calls, 1);
    expect(bridge.lastRelinkBytes, bytes);
    expect(bridge.libraryCalls, ['relink:w1']);
    expect(find.text('Source restored for Saved workspace'), findsOneWidget);
  });

  testWidgets('a cancelled file pick makes no re-link call', (tester) async {
    final bridge = ScriptedBridge();
    final source = FakeFileSource();
    await pumpHome(tester, bridge, fileSource: source);
    await choose(tester, 'Re-link source file');
    expect(source.calls, 1);
    expect(bridge.libraryCalls, isEmpty);
  });

  testWidgets('an engine rejection is shown and changes nothing', (tester) async {
    final bridge = ScriptedBridge()..rejectRelink = true;
    final source = FakeFileSource(
      file: PickedFile(
        name: 'other.csv',
        bytes: Uint8List.fromList(utf8.encode('region,amount\nus,99\n')),
      ),
    );
    await pumpHome(tester, bridge, fileSource: source);
    await choose(tester, 'Re-link source file');
    expect(find.textContaining('Could not re-link'), findsOneWidget);
    expect(bridge.workspaceIndex.length, 1);
    expect(find.text('Saved workspace'), findsOneWidget);
  });
}
