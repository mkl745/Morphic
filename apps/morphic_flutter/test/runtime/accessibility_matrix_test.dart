/// Ready-state host coverage across representative window classes, themes and text scales.
///
/// These tests use the bundled fonts and real runtime renderers in isolated component hosts,
/// not the full workspace layout. They cover selected controls and short labels, not every state
/// or a physical-device/TalkBack review (AT-18 remains open).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';

import '../support/golden_fonts.dart';
import '../support/scripted_bridge.dart';

const _windows = <String, Size>{
  'compact portrait': Size(390, 844),
  'compact landscape': Size(560, 360),
  'medium portrait': Size(700, 900),
  'medium landscape': Size(800, 500),
  'expanded': Size(1100, 800),
};

ScriptedBridge _bridge(String type) {
  if (type == 'metric_card') {
    return ScriptedBridge(
      metrics: {'metric': 1234},
      components: [
        {
          'id': 'metric',
          'type': type,
          'title': 'Records',
          'binding': {
            'kind': type,
            'aggregation': {'op': 'count', 'field': null},
          },
          'interactions': {'filter': true},
        },
      ],
      order: ['metric'],
    );
  }
  if (type == 'data_table') {
    return ScriptedBridge(
      fields: ['region', 'amount', 'note'],
      rows: [
        ['eu', 30, null],
        ['us', 10, 'alpha'],
        ['apac', 20, 'beta'],
      ],
      components: [
        {
          'id': 'data_table',
          'type': type,
          'title': 'Data',
          'binding': {
            'kind': type,
            'columns': ['amount', 'region'],
            'page_size': 2
          },
          'interactions': {'search': true, 'sort': true, 'filter': true},
        },
      ],
      order: ['data_table'],
    );
  }
  final binding = switch (type) {
    'line_chart' => {
        'kind': type,
        'x': 'ts',
        'y': [
          {'op': 'avg', 'field': 'value'},
        ],
        'group_by': 'group',
      },
    'timeline' => {'kind': type, 'time_field': 'ts', 'severity_field': 'group'},
    _ => {
        'kind': type,
        'dimension': 'group',
        'measure': {'op': 'avg', 'field': 'value'},
        'limit': 5,
      },
  };
  return ScriptedBridge(
    fields: ['ts', 'group', 'value'],
    dtypes: {'ts': 'timestamp', 'value': 'float64'},
    rows: [
      [0, 'api', 10],
      [0, 'web', 5],
      [60000, 'api', 20],
      [120000, 'web', 15],
    ],
    components: [
      {
        'id': 'chart',
        'type': type,
        'title': 'Events',
        'binding': binding,
        'interactions': {'filter': true, 'sort': true, 'select': true},
      },
    ],
    order: ['chart'],
  );
}

Future<void> _pumpComponent(
  WidgetTester tester,
  String type,
  Size window,
  Brightness brightness,
  double scale,
) async {
  final engine = EngineController(bridge: _bridge(type), storageRoot: '/tmp/m');
  await engine.open('w1');
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.dark ? MorphicTheme.dark() : MorphicTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: SizedBox(
            width: math.min(640.0, window.width - 32),
            child: AnimatedBuilder(
              animation: engine,
              builder: (context, _) {
                final ctx = ComponentContext(spec: engine.components.first, engine: engine);
                return type == 'data_table'
                    ? DataTableView(ctx: ctx, height: math.min(500.0, window.height - 48))
                    : ComponentRegistry().build(ctx);
              },
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _reachableTarget(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  expect(target, findsOneWidget, reason: key);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget, reason: '$key must be reachable after scrolling');
  final size = tester.getSize(target);
  expect(size.width, greaterThanOrEqualTo(48), reason: '$key width');
  expect(size.height, greaterThanOrEqualTo(48), reason: '$key height');
}

void _unclipped(WidgetTester tester, String text) {
  final finder = find.text(text);
  expect(finder, findsOneWidget);
  expect(tester.renderObject<RenderParagraph>(finder).didExceedMaxLines, isFalse,
      reason: 'the short label "$text" must remain legible');
}

double _contrast(Color a, Color b) {
  final aLuminance = a.computeLuminance();
  final bLuminance = b.computeLuminance();
  return (math.max(aLuminance, bLuminance) + .05) / (math.min(aLuminance, bLuminance) + .05);
}

void main() {
  setUpAll(loadMorphicGoldenFonts);

  for (final window in _windows.entries) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('ready controls: ${window.key}, $brightness, ${scale}x', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = window.value;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          for (final type in ['metric_card', 'data_table', 'bar_chart', 'line_chart', 'timeline']) {
            await _pumpComponent(tester, type, window.value, brightness, scale);
            expect(tester.takeException(), isNull, reason: '$type must lay out without overflow');

            switch (type) {
              case 'metric_card':
                _unclipped(tester, 'Records');
                expect(find.semantics.byLabel(RegExp('Records, count · rows, 1,234')), findsOne);
                await _reachableTarget(tester, 'metric-tap-metric');
              case 'data_table':
                _unclipped(tester, 'Data');
                for (final key in ['sort-amount', 'filter-amount', 'table-row-1']) {
                  await _reachableTarget(tester, key);
                }
                expect(find.semantics.byLabel('Row 1: amount: 30, region: eu'), findsOne);
                await _reachableTarget(tester, 'table-next-page');
                await _reachableTarget(tester, 'sort-amount');
                _unclipped(tester, 'amount');
                _unclipped(tester, 'region');
              case 'bar_chart':
                _unclipped(tester, 'Events');
                expect(find.semantics.byLabel(RegExp('^Bar chart of')), findsOne);
                await _reachableTarget(tester, 'bar-api');
                await _reachableTarget(tester, 'bar-view-as-table');
              case 'line_chart':
                _unclipped(tester, 'Events');
                expect(find.semantics.byLabel(RegExp('^Line chart of ts')), findsOne);
                await _reachableTarget(tester, 'line-legend-api');
                await _reachableTarget(tester, 'line-view-as-table');
              case 'timeline':
                _unclipped(tester, 'Events');
                expect(find.semantics.byLabel(RegExp('^Timeline of ts')), findsOne);
                await _reachableTarget(tester, 'timeline-legend-api');
                await _reachableTarget(tester, 'timeline-view-as-table');
            }
            await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
            await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
            expect(tester.takeException(), isNull, reason: '$type after scrolling');
          }
        });
      }
    }
  }

  test('table text and null indicators contrast with both plain and striped rows', () {
    for (final theme in [MorphicTheme.dark(), MorphicTheme.light()]) {
      final scheme = theme.colorScheme;
      final striped = Color.alphaBlend(
        scheme.surfaceContainerHighest.withValues(alpha: .35),
        scheme.surface,
      );
      for (final background in [scheme.surface, striped]) {
        for (final foreground in [scheme.onSurface, scheme.onSurfaceVariant]) {
          expect(_contrast(foreground, background), greaterThanOrEqualTo(4.5),
              reason: '${theme.brightness}: $foreground on $background');
        }
      }
    }
  });
}
