/// Field corrections from the table header (M1.5 task 1.5.5, AT-17).
///
/// The widget owns no inference logic: it reads the engine's profile and persisted overrides,
/// sends the command the engine validates, and renders the document the engine returns. These
/// tests drive the actual long-press → sheet → command → badge flow rather than calling the
/// helpers directly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/copy.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';
import 'package:morphic_flutter/runtime/field_corrections.dart';

import '../support/scripted_bridge.dart';

ScriptedBridge _bridge() => ScriptedBridge(
      rows: const [
        ['eu', 10],
        ['us', 20],
      ],
      fields: ['region', 'amount'],
      dtypes: const {'amount': 'int64'},
      components: [
        {
          'id': 'data_table',
          'type': 'data_table',
          'title': 'Data',
          'binding': {
            'kind': 'data_table',
            'columns': <String>[],
            'page_size': 2,
          },
          'interactions': {
            'sort': true,
            'filter': true,
            'search': true,
            'drillDown': true,
          },
        },
      ],
      order: ['data_table'],
    );

Future<EngineController> _open(ScriptedBridge b) async {
  final c = EngineController(bridge: b, storageRoot: '/tmp/m');
  await c.open('w1');
  return c;
}

Future<void> _pump(WidgetTester tester, EngineController engine) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: AnimatedBuilder(
          animation: engine,
          builder: (context, _) => DataTableView(
            ctx: ComponentContext(spec: engine.components.first, engine: engine),
            height: 400,
            searchDebounce: Duration.zero,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  Future<void> openSheet(WidgetTester tester, EngineController engine) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open-corrections'),
            onPressed: () => showFieldCorrectionsSheet(context, engine: engine),
            child: const Text('Correct a field'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open-corrections')));
    await tester.pumpAndSettle();
  }

  testWidgets('a missing profile offers an explicit close and a next step',
      (tester) async {
    final engine = await _open(ScriptedBridge(fields: []));
    await openSheet(tester, engine);

    expect(find.text('No field profile is available for this workspace.'), findsOneWidget);
    expect(find.text(MorphicCopy.noProfileDetail), findsOneWidget);
    expect(find.text(MorphicCopy.noProfileDegradedDetail), findsNothing);
    expect(find.byKey(const Key('field-correction-apply')), findsNothing);
    await _tap(tester, 'field-correction-close');
    expect(find.byKey(const Key('field-corrections-sheet')), findsNothing);
  });

  testWidgets('a degraded profile points to source restoration, not reopening alone',
      (tester) async {
    final engine = await _open(ScriptedBridge(degraded: true));
    await openSheet(tester, engine);

    expect(find.text(MorphicCopy.noProfileDegradedDetail), findsOneWidget);
    expect(find.text(MorphicCopy.noProfileDetail), findsNothing);
    await _tap(tester, 'field-correction-close');
    expect(find.byKey(const Key('field-corrections-sheet')), findsNothing);
  });

  testWidgets('a long press on a header opens that column for correction', (tester) async {
    final bridge = _bridge();
    final engine = await _open(bridge);
    await _pump(tester, engine);

    await tester.longPress(find.byKey(const Key('sort-amount')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('field-corrections-sheet')), findsOneWidget);
    expect(find.text('Correct a field'), findsOneWidget);
    expect(
      find.text('Inferred: Whole number · Measure'),
      findsOneWidget,
      reason: 'the sheet starts from what Rust inferred, not a UI guess',
    );
    expect(find.byKey(const Key('field-correction-clear')), findsNothing);
  });

  testWidgets('choosing a type and role sends both commands and marks the header',
      (tester) async {
    final bridge = _bridge();
    final engine = await _open(bridge);
    await _pump(tester, engine);

    await tester.longPress(find.byKey(const Key('sort-amount')));
    await tester.pumpAndSettle();
    await _tap(tester, 'field-dtype-utf8');
    await _tap(tester, 'field-role-dimension');
    await _tap(tester, 'field-correction-apply');

    expect(bridge.commandBatches.last, [
      {'kind': 'overrideFieldType', 'field': 'amount', 'dtype': 'utf8'},
      {'kind': 'overrideFieldRole', 'field': 'amount', 'role': 'dimension'},
    ]);
    expect(find.byKey(const Key('field-corrections-sheet')), findsNothing);
    expect(find.byKey(const Key('corrected-amount')), findsOneWidget);
    expect(bridge.fieldOverrides.single, {
      'field': 'amount',
      'dtype': 'utf8',
      'role': 'dimension',
    });
  });

  testWidgets('reset removes the persisted correction', (tester) async {
    final bridge = _bridge();
    bridge.fieldOverrides.add({'field': 'amount', 'dtype': 'utf8'});
    final engine = await _open(bridge);
    await _pump(tester, engine);

    expect(find.byKey(const Key('corrected-amount')), findsOneWidget);
    await tester.longPress(find.byKey(const Key('sort-amount')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('field-correction-clear')), findsOneWidget);
    expect(find.textContaining('corrected'), findsOneWidget);

    await _tap(tester, 'field-correction-clear');
    expect(bridge.commandBatches.last, [
      {'kind': 'clearFieldOverride', 'field': 'amount'},
    ]);
    expect(bridge.fieldOverrides, isEmpty);
    expect(find.byKey(const Key('corrected-amount')), findsNothing);
  });

  testWidgets('no change sends no command', (tester) async {
    final bridge = _bridge();
    final engine = await _open(bridge);
    await _pump(tester, engine);

    await tester.longPress(find.byKey(const Key('sort-region')));
    await tester.pumpAndSettle();
    await _tap(tester, 'field-correction-apply');

    expect(bridge.commandBatches, isEmpty);
    expect(find.byKey(const Key('field-corrections-sheet')), findsNothing);
  });
}
