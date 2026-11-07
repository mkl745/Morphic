/// Proves the *reachable* app path uses the live runtime, not the structural fallback.
///
/// A runtime that exists but is never navigated to would still pass every unit test, so this
/// drives the real screens: Home → PoC → Generate → workspace, and Home → reopen.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/app.dart';
import 'package:morphic_flutter/engine/import_runner.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';
import 'package:morphic_flutter/runtime/components/metric_card_view.dart';

import '../support/scripted_bridge.dart';

Future<void> _pumpApp(WidgetTester tester, ScriptedBridge bridge) async {
  await tester.pumpWidget(
    MorphicApp(
      bridge: bridge,
      storageRoot: '/tmp/morphic-wired-test',
      // The host has no libmorphic_bridge.so, so the worker isolate cannot run. The
      // screens, navigation and runtime under test are the real ones.
      importRunner: InlineImportRunner(bridge),
    ),
  );
  // Explicit pumps: the home loading spinner animates forever, so pumpAndSettle would hang.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  testWidgets('PoC generate opens the live runtime and pages through Rust',
      (tester) async {
    final bridge = ScriptedBridge(metrics: {'total_records': 12});
    await _pumpApp(tester, bridge);

    await tester.tap(find.text('Run proof of concept'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Detected schema'), findsOneWidget);

    await tester.tap(find.text('Generate workspace'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(MetricCardView), findsOneWidget,
        reason: 'the live runtime must be reachable, not just unit-tested');
    expect(find.byType(DataTableView), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(bridge.pageCalls, isNotEmpty,
        reason: 'the table must have asked the engine for a real page');
    expect(bridge.metricCalls, contains('total_records'));
  });

  testWidgets('reopening from Home restores a live, queryable session',
      (tester) async {
    final bridge = ScriptedBridge(metrics: {'total_records': 7});
    await _pumpApp(tester, bridge);

    await tester.tap(find.text('Saved workspace'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(MetricCardView), findsOneWidget,
        reason: 'reopen must reach the runtime, not the read-only structural view');
    expect(find.text('7'), findsOneWidget);
    expect(bridge.pageCalls, isNotEmpty,
        reason: 'a reopened workspace must be queryable, not just describable');
  });

  testWidgets('ingest warnings survive navigation and are shown on the workspace',
      (tester) async {
    final bridge = ScriptedBridge()
      ..importWarnings = ['encoding fell back to latin-1'];
    await _pumpApp(tester, bridge);

    await tester.tap(find.text('Run proof of concept'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Generate workspace'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Import notes (1)'), findsOneWidget);
    expect(find.textContaining('latin-1'), findsOneWidget);
  });

  testWidgets('the data table pages inside the real workspace route', (tester) async {
    final bridge = ScriptedBridge(rows: [
      ['eu', 10, null],
      ['us', 20, null],
      ['apac', 30, null],
      ['latam', 40, null],
    ]);
    await _pumpApp(tester, bridge);

    await tester.tap(find.text('Run proof of concept'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Generate workspace'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('1–2 of 4'), findsOneWidget);
    await tester.tap(find.byTooltip('Next page'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(bridge.pageCalls.last['offset'], 2);
    expect(find.text('3–4 of 4'), findsOneWidget);
  });
}
