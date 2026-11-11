/// Import screen behaviour for task 1.1.7.
///
/// Covers the whole user-visible path with the picker and the engine replaced by fakes:
/// cancel is not an error, real progress is shown while the import runs, a refusal from the
/// picker is explained, an engine failure is recoverable, and success lands on the
/// workspace route with the engine's warnings still attached.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/bridge.dart';
import 'package:morphic_flutter/engine/bridge_scope.dart';
import 'package:morphic_flutter/engine/clipboard_source.dart';
import 'package:morphic_flutter/engine/file_source.dart';
import 'package:morphic_flutter/engine/sample_import.dart';
import 'package:morphic_flutter/features/import/import_screen.dart';
import 'package:morphic_flutter/features/workspace/workspace_args.dart';

import 'support/fake_import.dart';
import 'support/scripted_bridge.dart';

Widget host({
  required PlatformFileSource source,
  required FakeImportRunner runner,
  required void Function(WorkspaceArgs) onWorkspace,
  ScriptedBridge? bridge,
  PlatformClipboardSource? clipboard,
  SampleLauncher? sampleLauncher,
}) =>
    MaterialApp(
      initialRoute: '/',
      routes: {
        '/': (_) => BridgeScope(
              bridge: bridge ?? ScriptedBridge(),
              storageRoot: '/tmp/morphic',
              child: ImportScreen(
                fileSource: source,
                clipboardSource: clipboard ?? FakeClipboardSource(),
                runner: runner,
                sampleLauncher: sampleLauncher,
              ),
            ),
        '/workspace': (context) {
          onWorkspace(
            ModalRoute.of(context)!.settings.arguments as WorkspaceArgs,
          );
          return const Scaffold(body: Text('WORKSPACE ROUTE'));
        },
      },
    );

PickedFile csv() => PickedFile(
      name: 'sales.csv',
      bytes: Uint8List.fromList(List.filled(2048, 65)),
      sizeBytes: 2048,
    );

/// A surface tall enough that every card is genuinely on screen.
///
/// The import body is a lazy `ListView`, and a finder can match a widget sitting in its
/// cache extent — built, but not hit-testable. These tests assert content and behaviour, not
/// layout, so giving them room removes a whole class of false failures. (1.2.4 learned this
/// the hard way: `scrollUntilVisible` stops at "found", which is not "visible".)
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('a bundled sample is offered and launched through the injected seam',
      (tester) async {
    useTallSurface(tester);
    final launcher = FakeSampleLauncher();
    await tester.pumpWidget(host(
      source: FakeFileSource(),
      runner: FakeImportRunner(),
      onWorkspace: (_) {},
      sampleLauncher: launcher,
    ));
    await tester.pump();

    expect(find.text('Try a bundled sample'), findsOneWidget);
    final button = find.byKey(const Key('sample-sensors'));
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(launcher.calls, 1);
    expect(launcher.lastSample!.id, 'sensors');
    expect(launcher.lastSample!.formatHint, 'json');
  });

  testWidgets('a sample launch failure is shown on the import screen', (tester) async {
    useTallSurface(tester);
    final launcher = FakeSampleLauncher()..failure = StateError('asset missing');
    await tester.pumpWidget(host(
      source: FakeFileSource(),
      runner: FakeImportRunner(),
      onWorkspace: (_) {},
      sampleLauncher: launcher,
    ));
    await tester.pump();

    final button = find.byKey(const Key('sample-server-logs'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not open sample'), findsOneWidget);
  });

  testWidgets('offers a picker and states the supported formats', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(host(
      source: FakeFileSource(),
      runner: FakeImportRunner(),
      onWorkspace: (_) {},
    ));
    await tester.pump();

    expect(find.text('Import a file'), findsOneWidget);
    expect(find.text('Choose a file'), findsOneWidget);
    expect(find.textContaining('nothing leaves this device'), findsOneWidget);
    expect(
      find.textContaining('If it guessed wrong'),
      findsOneWidget,
      reason: 'the UI must not imply formats the engine cannot parse',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the format defaults to auto-detect and can be overridden',
      (tester) async {
    useTallSurface(tester);
    final runner = FakeImportRunner();
    await tester.pumpWidget(host(
      source: FakeFileSource(file: csv()),
      runner: runner,
      onWorkspace: (_) {},
    ));
    await tester.pump();

    expect(find.text('Detect automatically'), findsOneWidget);

    // Choose an explicit format, then import: the hint must reach the engine.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JSON Lines').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose a file'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(runner.lastRequest?.formatHint, 'jsonl');
    expect(runner.lastRequest?.extension, 'csv');
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving the format alone sends no hint', (tester) async {
    useTallSurface(tester);
    final runner = FakeImportRunner();
    await tester.pumpWidget(host(
      source: FakeFileSource(file: csv()),
      runner: runner,
      onWorkspace: (_) {},
    ));
    await tester.pump();

    await tester.tap(find.text('Choose a file'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(runner.lastRequest?.formatHint, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a running import can be cancelled from the UI', (tester) async {
    useTallSurface(tester);
    final gate = Completer<void>();
    final bridge = ScriptedBridge()..cancelResult = true;
    await tester.pumpWidget(host(
      source: FakeFileSource(file: csv()),
      runner: FakeImportRunner(gate: gate),
      bridge: bridge,
      onWorkspace: (_) {},
    ));
    await tester.pump();

    await tester.tap(find.text('Choose a file'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Cancel import'), findsOneWidget);

    await tester.tap(find.text('Cancel import'));
    await tester.pump();
    expect(bridge.cancelCalls, hasLength(1));

    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cancelled import says nothing was saved, without an error card',
      (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(host(
      source: FakeFileSource(file: csv()),
      runner: FakeImportRunner(
        failure: const MorphicBridgeException('ingest: import cancelled'),
      ),
      onWorkspace: (_) {},
    ));
    await tester.pump();

    await tester.tap(find.text('Choose a file'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Import cancelled'), findsOneWidget);
    expect(find.textContaining('Nothing was saved'), findsOneWidget);
    expect(find.text('Choose another file'), findsNothing,
        reason: 'cancellation must not render the error card');
    expect(tester.takeException(), isNull);
  });

  testWidgets('quarantined rows keep the user on the report instead of navigating',
      (tester) async {
    useTallSurface(tester);
    var opened = false;
    await tester.pumpWidget(host(
      source: FakeFileSource(file: csv()),
      runner: FakeImportRunner(result: {
        'doc': ScriptedBridge().doc(),
        'profile': ScriptedBridge().profileJson(),
        'report': {
          'format': 'csv',
          'encoding': 'utf-8',
          'rowsImported': 90,
          'rowsQuarantined': 10,
          'fieldCount': 3,
          'warnings': [
            "Read as 'csv' (100% confidence): 3 fields on 100% of sampled lines.",
            '10 rows did not fit the shape of the file.',
          ],
        },
      }),
      onWorkspace: (_) => opened = true,
    ));
    await tester.pump();

    await tester.tap(find.text('Choose a file'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(opened, isFalse, reason: 'review comes before the workspace');
    expect(find.text('Worth a look first'), findsOneWidget);
    expect(find.text('What Morphic read'), findsOneWidget);
    expect(find.text('Set aside'), findsOneWidget);

    await tester.tap(find.text('View report'));
    await tester.pumpAndSettle();
    expect(find.text('Import report'), findsOneWidget);
    expect(find.textContaining('10 rows did not fit'), findsOneWidget);
    expect(find.text('Read it as something else'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an engine failure shows human copy and keeps the raw evidence',
      (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(host(
      source: FakeFileSource(file: csv()),
      runner: FakeImportRunner(
        failure: const MorphicBridgeException(
          'ingest: resource limit exceeded: the file is 300 MiB, over the 256 MiB '
          'import limit; import a sample instead',
        ),
      ),
      onWorkspace: (_) {},
    ));
    await tester.pump();

    await tester.tap(find.text('Choose a file'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('That file is too large to import.'), findsOneWidget);
    expect(find.textContaining('Split the file'), findsOneWidget);
    expect(find.textContaining('300 MiB'), findsOneWidget,
        reason: 'the engine text is evidence, not noise');
    expect(tester.takeException(), isNull);
  });

  testWidgets('pasted text is imported without opening the picker', (tester) async {
    useTallSurface(tester);
    final source = FakeFileSource(file: csv());
    final runner = FakeImportRunner();
    final clipboard = FakeClipboardSource(content: clipboardText('a,b\n1,2\n'));
    WorkspaceArgs? args;
    await tester.pumpWidget(host(
      source: source,
      runner: runner,
      clipboard: clipboard,
      onWorkspace: (a) => args = a,
    ));
    await tester.pump();

    await tester.tap(find.text('Paste from clipboard'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(clipboard.calls, 1);
    expect(source.calls, 0, reason: 'pasting must not open the file picker');
    expect(runner.lastRequest!.title, 'Clipboard text');
    expect(runner.lastRequest!.extension, isNull);
    expect(args, isNotNull, reason: 'a clean paste opens the workspace');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty clipboard is explained, not imported', (tester) async {
    useTallSurface(tester);
    final runner = FakeImportRunner();
    await tester.pumpWidget(host(
      source: FakeFileSource(),
      runner: runner,
      clipboard: FakeClipboardSource(),
      onWorkspace: (_) {},
    ));
    await tester.pump();

    await tester.tap(find.text('Paste from clipboard'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(runner.runs, 0);
    expect(find.textContaining('The clipboard has no text'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a clipboard refusal is shown with its own explanation', (tester) async {
    useTallSurface(tester);
    final runner = FakeImportRunner();
    await tester.pumpWidget(host(
      source: FakeFileSource(),
      runner: runner,
      clipboard: FakeClipboardSource(
        failure: const ClipboardReadException(
          'The clipboard holds 90.0 MB of text. This build reads up to 64 MB at once; '
          'save it to a file and import a smaller part.',
        ),
      ),
      onWorkspace: (_) {},
    ));
    await tester.pump();

    await tester.tap(find.text('Paste from clipboard'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(runner.runs, 0);
    expect(find.textContaining('90.0 MB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the clipboard button states the platform notice honestly',
      (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(host(
      source: FakeFileSource(),
      runner: FakeImportRunner(),
      onWorkspace: (_) {},
    ));
    await tester.pump();
    expect(find.text('Paste from clipboard'), findsOneWidget);
    expect(find.textContaining('Android may show its own notice'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the picker is not an error', (tester) async {
    useTallSurface(tester);
    final source = FakeFileSource();
    final runner = FakeImportRunner();
    await tester.pumpWidget(host(
      source: source,
      runner: runner,
      onWorkspace: (_) => fail('cancelling must not navigate'),
    ));
    await tester.pump();
    await tester.tap(find.text('Choose a file'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(source.calls, 1);
    expect(runner.runs, 0);
    expect(find.text('Choose a file'), findsOneWidget);
    expect(find.textContaining('could not'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a successful pick opens the workspace with warnings attached',
      (tester) async {
    useTallSurface(tester);
    WorkspaceArgs? args;
    final runner = FakeImportRunner(
      warnings: const ["Detected ';' as the delimiter."],
    );
    await tester.pumpWidget(host(
      source: FakeFileSource(file: csv()),
      runner: runner,
      onWorkspace: (a) => args = a,
    ));
    await tester.pump();
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();

    expect(find.text('WORKSPACE ROUTE'), findsOneWidget);
    expect(runner.runs, 1);
    expect(runner.lastRequest!.title, 'sales');
    expect(args, isNotNull);
    expect(args!.controller, isNotNull);
    expect(args!.controller!.doc, isNotNull);
    expect(
      args!.warnings,
      ["Detected ';' as the delimiter."],
      reason: 'warnings must survive the import screen being disposed',
    );
  });

  testWidgets('shows the picked file and live engine progress while importing',
      (tester) async {
    useTallSurface(tester);
    final gate = Completer<void>();
    await tester.pumpWidget(host(
      source: FakeFileSource(file: csv()),
      runner: FakeImportRunner(events: kProgressEvents, gate: gate),
      onWorkspace: (_) {},
    ));
    await tester.pump();
    await tester.tap(find.text('Choose a file'));
    // Explicit pumps: the indeterminate progress indicator never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('sales.csv'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('Building workspace'), findsOneWidget);
    expect(find.text('6000 rows · 300.0 KB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'a second import must not be startable while one is running',
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('WORKSPACE ROUTE'), findsOneWidget);
  });

  testWidgets('a refused file is explained and can be retried', (tester) async {
    useTallSurface(tester);
    final source = FakeFileSource(
      failure: const FileSelectionException('That file is 512.0 MB.'),
    );
    final runner = FakeImportRunner();
    await tester.pumpWidget(host(
      source: source,
      runner: runner,
      onWorkspace: (_) => fail('a refused file must not navigate'),
    ));
    await tester.pump();
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();

    expect(find.text('That file is 512.0 MB.'), findsOneWidget);
    expect(find.text('Choose another file'), findsOneWidget);
    expect(runner.runs, 0);

    await tester.tap(find.text('Choose another file'));
    await tester.pumpAndSettle();
    expect(source.calls, 2, reason: 'retry re-opens the picker');
  });

  testWidgets('an engine failure is shown, not navigated past', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(host(
      source: FakeFileSource(file: csv()),
      runner: FakeImportRunner(failure: Exception('ingest: empty file')),
      onWorkspace: (_) => fail('a failed import must not navigate'),
    ));
    await tester.pump();
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ingest: empty file'), findsOneWidget);
    expect(find.text('Choose another file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('byte formatting', () {
    test('uses binary units and one decimal above a kilobyte', () {
      expect(formatByteCount(0), '0 B');
      expect(formatByteCount(1023), '1023 B');
      expect(formatByteCount(1024), '1.0 KB');
      expect(formatByteCount(307200), '300.0 KB');
      expect(formatByteCount(10 * 1024 * 1024), '10.0 MB');
    });
  });
}
