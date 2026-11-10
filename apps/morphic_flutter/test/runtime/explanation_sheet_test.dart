/// Behavioural tests for the "Why this view?" sheet (M1.4 task 1.4.6).
///
/// No goldens here: Flutter's test font draws boxes, so a PNG could not prove that the words
/// are right. Everything that matters in this sheet *is* words, and the words are asserted.
/// The 54 chart goldens still change, because the shared header button is part of their layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/explanation_sheet.dart';
import 'package:morphic_flutter/runtime/workspace_view.dart';

import '../support/scripted_bridge.dart';

Widget _sheetHost({
  required Map<String, dynamic>? explanation,
  String title = 'Errors',
  Brightness brightness = Brightness.dark,
}) =>
    MaterialApp(
      theme: brightness == Brightness.dark
          ? MorphicTheme.dark()
          : MorphicTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-why'),
              onPressed: () => showExplanationSheet(
                context,
                componentTitle: title,
                explanation: explanation,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

Widget _workspaceHost(Widget child) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 420, height: 900, child: child),
      ),
    );

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-why')));
  await tester.pumpAndSettle();
}

const Map<String, dynamic> _full = <String, dynamic>{
  'reason': 'R2b_error_metric',
  'detail': "'level' carries severity levels, so errors are a headline number.",
  'evidence': <String>[
    '1 error-shaped level(s) observed',
    'top_values: ERROR, WARN, INFO',
  ],
  'confidence': 0.97,
};

void main() {
  testWidgets('a full explanation shows reason, evidence and confidence', (tester) async {
    await tester.pumpWidget(_sheetHost(explanation: _full));
    await _openSheet(tester);

    expect(find.text('Why this view?'), findsOneWidget);
    expect(find.text('Errors'), findsOneWidget,
        reason: 'the sheet names the component it is explaining');
    expect(find.text('Severity field found'), findsOneWidget);
    expect(find.text('Rule R2b_error_metric'), findsOneWidget,
        reason: 'the auditable rule id is shown even when a heading exists');
    expect(find.text("'level' carries severity levels, so errors are a headline number."),
        findsOneWidget);
    expect(find.text('• 1 error-shaped level(s) observed'), findsOneWidget);
    expect(find.text('• top_values: ERROR, WARN, INFO'), findsOneWidget);
    expect(find.text('97%'), findsOneWidget);
    expect(find.byKey(const Key('why-sheet-confidence-bar')), findsOneWidget);
    expect(find.textContaining('does not rewrite them'), findsOneWidget);
  });

  testWidgets('the sheet closes by its own button, not only by a back gesture',
      (tester) async {
    await tester.pumpWidget(_sheetHost(explanation: _full));
    await _openSheet(tester);
    expect(find.byType(WhyThisViewSheet), findsOneWidget);

    await tester.tap(find.byKey(const Key('why-sheet-close')));
    await tester.pumpAndSettle();
    expect(find.byType(WhyThisViewSheet), findsNothing);
  });

  testWidgets('missing fields are reported, not filled in', (tester) async {
    await tester.pumpWidget(
        _sheetHost(explanation: <String, dynamic>{'detail': 'Only a detail.'}));
    await _openSheet(tester);

    expect(find.text('Only a detail.'), findsOneWidget);
    expect(find.text('No rule recorded'), findsOneWidget);
    expect(find.text('No rule id was recorded.'), findsOneWidget);
    expect(find.text('No evidence was recorded for this component.'), findsOneWidget);
    expect(find.text('Not reported'), findsOneWidget);
    expect(find.byKey(const Key('why-sheet-confidence-bar')), findsNothing,
        reason: 'a bar with no value would be a fabricated 0%');
  });

  testWidgets('a component with no explanation says so explicitly', (tester) async {
    await tester.pumpWidget(_sheetHost(explanation: null));
    await _openSheet(tester);

    expect(find.byKey(const Key('why-sheet-empty')), findsOneWidget);
    expect(find.textContaining('document defect'), findsOneWidget);
    expect(find.byKey(const Key('why-sheet-confidence')), findsNothing);
    expect(find.byKey(const Key('why-sheet-detail')), findsNothing);
  });

  testWidgets('an unknown rule and doc-03-shaped evidence do not crash the sheet',
      (tester) async {
    await tester.pumpWidget(_sheetHost(explanation: <String, dynamic>{
      'reason': 'R9_future_rule',
      'detail': 'From a newer engine.',
      'evidence': <Object?>[
        <String, dynamic>{'field': 'level', 'fact': 'top_values'},
        42,
        null,
      ],
      'confidence': 1.5,
    }));
    await _openSheet(tester);

    expect(find.text('R9_future_rule'), findsOneWidget,
        reason: 'an unknown id falls back to the raw string, without an invented heading');
    expect(find.text('Rule R9_future_rule'), findsOneWidget);
    expect(find.byKey(const Key('why-sheet-evidence-0')), findsOneWidget);
    expect(find.byKey(const Key('why-sheet-evidence-1')), findsOneWidget);
    expect(find.byKey(const Key('why-sheet-evidence-2')), findsNothing,
        reason: 'null evidence is skipped rather than drawn as "null"');
    expect(find.text('Not reported'), findsOneWidget,
        reason: 'a confidence outside 0..1 is not a percentage');
  });

  testWidgets('the sheet reads correctly in the light theme', (tester) async {
    await tester.pumpWidget(
        _sheetHost(explanation: _full, brightness: Brightness.light));
    await _openSheet(tester);
    expect(find.text('97%'), findsOneWidget);
    expect(find.byType(WhyThisViewSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('fromMap keeps only usable evidence and in-range confidence', () {
    final e = ComponentExplanation.fromMap(<String, dynamic>{
      'reason': 17,
      'detail': null,
      'evidence': <Object?>['  ', 'real', 3],
      'confidence': 0.5,
    });
    expect(e.reason, '');
    expect(e.detail, '');
    expect(e.evidence, <String>['real', '3']);
    expect(e.confidencePercent, '50%');

    expect(ComponentExplanation.fromMap(null).isEmpty, isTrue);
    expect(ComponentExplanation.fromMap(<String, dynamic>{}).isEmpty, isTrue);
  });

  /// AT-10 says every component has a non-empty explanation, and the M1.4 exit says every
  /// generated component explains itself. That means the *affordance* must be reachable from
  /// all five renderers, not just the metric card that already showed a clamped `detail`.
  testWidgets('every component type reaches its own explanation', (tester) async {
    const specs = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'total_records',
        'type': 'metric_card',
        'title': 'Records',
        'binding': <String, dynamic>{
          'kind': 'metric_card',
          'aggregation': <String, dynamic>{'op': 'count', 'field': null},
        },
      },
      <String, dynamic>{
        'id': 'trend_over_time',
        'type': 'line_chart',
        'title': 'Over time',
        'binding': <String, dynamic>{
          'kind': 'line_chart',
          'x': 'region',
          'y': <Map<String, dynamic>>[
            <String, dynamic>{'op': 'avg', 'field': 'amount'},
          ],
        },
      },
      <String, dynamic>{
        'id': 'event_timeline',
        'type': 'timeline',
        'title': 'Timeline',
        'binding': <String, dynamic>{
          'kind': 'timeline',
          'time_field': 'region',
        },
      },
      <String, dynamic>{
        'id': 'breakdown_by_region',
        'type': 'bar_chart',
        'title': 'By region',
        'binding': <String, dynamic>{
          'kind': 'bar_chart',
          'dimension': 'region',
          'measure': <String, dynamic>{'op': 'avg', 'field': 'amount'},
          'limit': 4,
        },
      },
      <String, dynamic>{
        'id': 'data_table',
        'type': 'data_table',
        'title': 'Data',
        'binding': <String, dynamic>{
          'kind': 'data_table',
          'columns': <String>[],
          'page_size': 2,
        },
      },
    ];

    for (final spec in specs) {
      final id = spec['id']! as String;
      final detail = 'Explanation for $id.';
      final component = <String, dynamic>{
        ...spec,
        'explanation': <String, dynamic>{
          'reason': 'R1_records',
          'detail': detail,
          'evidence': <String>['$id evidence'],
          'confidence': 0.8,
        },
      };
      final bridge = ScriptedBridge(
        components: <Map<String, dynamic>>[component],
        order: <String>[id],
        metrics: <String, Object?>{id: 7},
      );
      final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
      await engine.open('w1');
      await tester.pumpWidget(_workspaceHost(WorkspaceView(
        controller: engine,
        registry: ComponentRegistry(),
      )));
      await tester.pumpAndSettle();

      final button = find.byKey(Key('explain-$id'));
      expect(button, findsOneWidget, reason: '$id has no "Why this view?" affordance');
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('why-sheet-detail')))
            .data,
        detail,
        reason: '$id opened a sheet without its own explanation',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('why-sheet-component')))
            .data,
        spec['title'],
        reason: 'the sheet must name the component it explains',
      );

      await tester.tap(find.byKey(const Key('why-sheet-close')));
      await tester.pumpAndSettle();
    }
  });
}
