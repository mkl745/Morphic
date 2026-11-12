/// Progress labels follow observations from the real controller; animation never gates work.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/bridge_scope.dart';
import 'package:morphic_flutter/engine/file_source.dart';
import 'package:morphic_flutter/engine/import_progress.dart';
import 'package:morphic_flutter/engine/import_runner.dart';
import 'package:morphic_flutter/features/import/import_screen.dart';
import 'package:morphic_flutter/features/workspace/workspace_args.dart';

import 'support/fake_import.dart';
import 'support/scripted_bridge.dart';

class _ControlledRunner implements ImportRunner {
  final done = Completer<Map<String, dynamic>>();
  void Function(ImportProgress)? onProgress;

  @override
  Future<Map<String, dynamic>> run(
    ImportRequest request,
    void Function(ImportProgress) onProgress,
  ) {
    this.onProgress = onProgress;
    return done.future;
  }

  void emit(String phase, int rows) => onProgress!(ImportProgress(
        phase: phase,
        rowsRead: rows,
        bytesRead: rows * 10,
      ));
}

void main() {
  testWidgets('stages change only on events and completion navigates without delay',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = ScriptedBridge();
    final runner = _ControlledRunner();
    WorkspaceArgs? routed;
    await tester.pumpWidget(BridgeScope(
      bridge: bridge,
      storageRoot: '/tmp/morphic',
      child: MaterialApp(
        routes: {
          '/': (_) => ImportScreen(
                fileSource: FakeFileSource(
                    file: PickedFile(
                  name: 'sales.csv',
                  bytes: Uint8List.fromList([1, 2, 3]),
                )),
                runner: runner,
              ),
          '/workspace': (context) {
            routed = ModalRoute.of(context)!.settings.arguments as WorkspaceArgs;
            return const Scaffold(body: Text('Workspace route'));
          },
        },
      ),
    ));
    await tester.tap(find.text('Choose a file'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Starting engine'), findsOneWidget);
    expect(find.text('Detecting format'), findsNothing);
    expect(
        tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, isNull);

    runner.emit('sniffing', 0);
    await tester.pump();
    expect(find.text('Detecting format'), findsOneWidget);
    expect(find.text('Starting engine'), findsNothing);
    runner.emit('parsing', 42);
    await tester.pump();
    expect(find.text('Reading rows'), findsOneWidget);
    expect(find.text('Detecting format'), findsNothing);
    expect(find.textContaining('42 rows'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);

    runner.done.complete({
      'doc': bridge.doc(),
      'profile': bridge.profileJson(),
      'report': {'rowsImported': 42, 'warnings': <String>[]},
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(routed, isNotNull, reason: 'entrance animation must not delay navigation');
    expect(routed!.animateEntrance, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Workspace route'), findsOneWidget);
  });
}
