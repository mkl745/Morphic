/// Representative real-workspace coverage, including adaptive inspection surfaces.
///
/// These tests exercise Flutter widgets and semantics with a scripted engine, not a physical
/// device or TalkBack. They intentionally use one fixture and selected ready-state actions;
/// they are evidence towards AT-18, not a complete state, target, contrast or clipping audit.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/features/workspace/workspace_screen.dart';

import '../support/golden_fonts.dart';
import '../support/scripted_bridge.dart';

const _windows = <String, Size>{
  'compact portrait': Size(390, 844),
  'compact landscape': Size(560, 360),
  'medium boundary': Size(600, 500),
  'medium portrait': Size(700, 900),
  'medium landscape': Size(800, 500),
  'expanded boundary': Size(841, 700),
  'expanded': Size(1100, 800),
};

ScriptedBridge _workspace() {
  const ids = ['metric', 'data_table', 'bar', 'line', 'timeline'];
  return ScriptedBridge(
    metrics: {'metric': 4},
    fields: ['ts', 'group', 'value', 'note'],
    dtypes: {'ts': 'timestamp', 'value': 'float64'},
    rows: [
      [0, 'api', 10, null],
      [60000, 'web', 20, 'second'],
      [120000, 'api', 30, 'third'],
      [180000, 'web', 40, 'fourth'],
    ],
    components: [
      {
        'id': 'metric',
        'type': 'metric_card',
        'title': 'Records',
        'binding': {
          'kind': 'metric_card',
          'aggregation': {'op': 'count', 'field': null},
        },
        'interactions': {'filter': true},
      },
      {
        'id': 'data_table',
        'type': 'data_table',
        'title': 'Data',
        'binding': {
          'kind': 'data_table',
          'columns': ['value', 'group'],
          'page_size': 2,
        },
        'interactions': {'search': true, 'sort': true, 'filter': true},
      },
      {
        'id': 'bar',
        'type': 'bar_chart',
        'title': 'Bar',
        'binding': {
          'kind': 'bar_chart',
          'dimension': 'group',
          'measure': {'op': 'avg', 'field': 'value'},
          'limit': 5,
        },
        'interactions': {'filter': true, 'sort': true},
      },
      {
        'id': 'line',
        'type': 'line_chart',
        'title': 'Line',
        'binding': {
          'kind': 'line_chart',
          'x': 'ts',
          'y': [
            {'op': 'avg', 'field': 'value'},
          ],
          'group_by': 'group',
        },
        'interactions': {'select': true},
      },
      {
        'id': 'timeline',
        'type': 'timeline',
        'title': 'Timeline',
        'binding': {'kind': 'timeline', 'time_field': 'ts', 'severity_field': 'group'},
        'interactions': {'filter': true, 'select': true},
      },
    ],
    order: ids,
    // Narrow one-column cards are a valid saved layout even at medium/expanded widths.
    hints: [
      for (final id in ids) {'componentId': id, 'span': 1}
    ],
  );
}

Future<EngineController> _pumpWorkspace(
  WidgetTester tester,
  Brightness brightness,
  double scale,
) async {
  final engine = EngineController(bridge: _workspace(), storageRoot: '/tmp/m');
  await engine.open('w1');
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.dark ? MorphicTheme.dark() : MorphicTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: WorkspaceScreen(controller: engine),
  ));
  await tester.pumpAndSettle();
  return engine;
}

/// Check actual visible portions, not just the unconstrained size of an off-screen widget.
/// Intersect the target with the window and every enclosing scrollable viewport. This is a
/// selected geometry check, not a hit-test grid or a replacement for a human target audit.
Future<void> _reachableTarget(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  expect(target, findsOneWidget, reason: key);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget, reason: '$key must be reachable after scrolling');

  var visible = tester.getRect(target).intersect(
        Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio),
      );
  final scrollables = find.ancestor(of: target, matching: find.byType(Scrollable));
  for (final element in scrollables.evaluate()) {
    final box = element.renderObject;
    if (box is RenderBox && box.hasSize) {
      visible = visible.intersect(box.localToGlobal(Offset.zero) & box.size);
    }
  }
  expect(visible.width, greaterThanOrEqualTo(48 - 0.000001), reason: '$key visible width');
  expect(visible.height, greaterThanOrEqualTo(48 - 0.000001), reason: '$key visible height');
}

void _unclipped(WidgetTester tester, String text) {
  final finder = find.text(text);
  expect(finder, findsOneWidget);
  expect(tester.renderObject<RenderParagraph>(finder).didExceedMaxLines, isFalse,
      reason: 'the short title "$text" must remain legible');
}

Finder _detailSurface(Size size) {
  if (size.width < 600) return find.byType(BottomSheet);
  if (size.width <= 840) return find.byKey(const Key('workspace-detail-side-sheet'));
  return find.byKey(const Key('workspace-detail-rail'));
}

Future<void> _openChartTable(WidgetTester tester, String prefix, Size size) async {
  final button = '$prefix-view-as-table';
  await _reachableTarget(tester, button);
  await tester.tap(find.byKey(Key(button)));
  await tester.pumpAndSettle();

  final surface = _detailSurface(size);
  final close = find.byKey(Key('$prefix-table-close'));
  expect(find.descendant(of: surface, matching: close), findsOneWidget,
      reason: '$prefix table must be on the adaptive detail surface');
  if (prefix == 'bar') {
    expect(find.descendant(of: surface, matching: find.text('api')), findsOneWidget);
  } else {
    final bucket = find.byKey(Key('$prefix-table-bucket-0'));
    expect(find.descendant(of: surface, matching: bucket), findsOneWidget);
  }
  await _reachableTarget(tester, '$prefix-table-close');
  await tester.tap(close);
  await tester.pumpAndSettle();
  expect(close, findsNothing);
  expect(find.byType(WorkspaceScreen), findsOneWidget);
  expect(tester.takeException(), isNull, reason: '$prefix detail must not overflow');
}

void main() {
  setUpAll(loadMorphicGoldenFonts);

  for (final window in _windows.entries) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('workspace: ${window.key}, $brightness, ${scale}x', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = window.value;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final engine = await _pumpWorkspace(tester, brightness, scale);
          expect(tester.takeException(), isNull, reason: 'workspace must lay out');

          for (final title in ['Records', 'Data', 'Bar', 'Line', 'Timeline']) {
            _unclipped(tester, title);
          }
          for (final key in [
            'metric-tap-metric',
            'sort-value',
            'filter-value',
            'table-row-1',
            'table-next-page',
            'bar-api',
            'line-legend-api',
            'timeline-legend-api',
          ]) {
            await _reachableTarget(tester, key);
          }

          await _reachableTarget(tester, 'table-row-1');
          final row = find.semantics.byLabel('Row 1: value: 10, group: api');
          expect(row, findsOne);
          tester.semantics.tap(row);
          await tester.pumpAndSettle();
          final surface = _detailSurface(window.value);
          expect(find.descendant(of: surface, matching: find.text('Row 1')), findsOneWidget);
          final nullValue = find.descendant(of: surface, matching: find.text('No value (null)'));
          expect(nullValue, findsOneWidget, reason: 'detail includes non-projected source fields');
          await tester.ensureVisible(nullValue);
          await tester.pumpAndSettle();
          await _reachableTarget(tester, 'row-detail-close');
          await tester.tap(find.byKey(const Key('row-detail-close')));
          await tester.pumpAndSettle();
          expect(find.text('Row 1'), findsNothing);

          for (final prefix in ['bar', 'line', 'timeline']) {
            await _openChartTable(tester, prefix, window.value);
          }
          expect(engine.globalFilters, isEmpty, reason: 'inspection must not change the data');
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
