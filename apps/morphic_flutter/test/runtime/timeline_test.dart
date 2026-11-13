/// Widget tests for the timeline renderer (M1.4 task 1.4.4).
///
/// The fixture is chosen so the interesting behaviour is observable: three severities with
/// different frequencies (so the engine's lane order is visible), a bucket where the most frequent
/// severity is absent (so a renderer that matched lanes by position rather than identity would
/// colour it wrongly), and one row with no timestamp at all (so the undated count must surface).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/chart_scene.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/chart_axis_layout.dart';
import 'package:morphic_flutter/runtime/components/chart_format.dart';
import 'package:morphic_flutter/runtime/components/timeline_painter.dart';
import 'package:morphic_flutter/runtime/components/timeline_view.dart';

import '../support/scripted_bridge.dart';

Map<String, dynamic> _spec({
  String? severityField = 'level',
  String? groupBy,
  bool canFilter = true,
  bool canSelect = true,
}) =>
    {
      'id': 'event_timeline',
      'type': 'timeline',
      'title': 'Events over time',
      'binding': {
        'kind': 'timeline',
        'time_field': 'ts',
        if (severityField != null) 'severity_field': severityField,
        if (groupBy != null) 'group_by': groupBy,
      },
      'interactions': {'filter': canFilter, 'select': canSelect},
    };

/// ERROR 3, INFO 2, WARN 1 across three buckets, plus one undated row.
/// Bucket 0 holds ERROR 2 + INFO 1; bucket 1 holds WARN 1 + INFO 1 and **no ERROR**; bucket 2
/// holds ERROR 1. Tallest column is 3, so the count axis runs 0..3 in steps of 1.
List<List<dynamic>> _rows() => [
      [0, 'ERROR', 'a'],
      [0, 'ERROR', 'b'],
      [0, 'INFO', 'c'],
      [60000, 'WARN', 'd'],
      [60000, 'INFO', 'e'],
      [120000, 'ERROR', 'f'],
      [null, 'ERROR', 'undated'],
    ];

ScriptedBridge _bridge({
  String? severityField = 'level',
  String? groupBy,
  bool canFilter = true,
  bool canSelect = true,
  List<List<dynamic>>? rows,
}) =>
    ScriptedBridge(
      rows: rows ?? _rows(),
      fields: const ['ts', 'level', 'msg'],
      dtypes: const {'ts': 'timestamp'},
      components: [
        _spec(
          severityField: severityField,
          groupBy: groupBy,
          canFilter: canFilter,
          canSelect: canSelect,
        ),
      ],
      order: const ['event_timeline'],
    );

Future<EngineController> _pump(WidgetTester tester, ScriptedBridge bridge) async {
  final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await engine.open('w1');
  await tester.pumpWidget(MaterialApp(
    // Pinned so the colour assertions name a known palette: MaterialApp's default is light.
    theme: MorphicTheme.dark(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: AnimatedBuilder(
          animation: engine,
          builder: (context, _) => TimelineView(
            ctx: ComponentContext(spec: engine.components.first, engine: engine),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return engine;
}

TimelinePainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(const Key('timeline-paint'))).painter
        as TimelinePainter;

TimelineGeometry _geo(WidgetTester tester) => _painter(tester).geometry;

/// Taps the centre of a column, by index, using the painter's own slot mapping.
Future<void> _tapColumn(WidgetTester tester, int index) async {
  final box = tester.getRect(find.byKey(const Key('timeline-plot')));
  final geo = _geo(tester);
  final slot = geo.slotFor(geo.columns[index], geo.plotIn(box.size));
  await tester.tapAt(Offset(box.left + slot.center.dx, box.top + slot.center.dy));
  await tester.pumpAndSettle();
}

class _GatedChartController extends EngineController {
  _GatedChartController({required super.bridge, required super.storageRoot});

  final List<Completer<void>> _gates = [];

  Completer<void> holdNext() {
    final gate = Completer<void>();
    _gates.add(gate);
    return gate;
  }

  @override
  Future<ChartResult?> chartData(String componentId) async {
    final result = await super.chartData(componentId);
    if (_gates.isNotEmpty) await _gates.removeAt(0).future;
    return result;
  }
}

void main() {
  testWidgets('draws the engine scene and asks the engine for it', (tester) async {
    final bridge = _bridge();
    await _pump(tester, bridge);
    expect(bridge.chartCalls, ['event_timeline']);
    expect(find.text('Events over time'), findsOneWidget);
    final geo = _geo(tester);
    expect(geo.columns.map((c) => c.startMs), [0, 60000, 120000]);
    expect(geo.columns.map((c) => c.count), [3, 2, 1]);
    expect(geo.bucketMs, 60000);
    expect(geo.hasSeveritySplit, isTrue);
    expect(geo.lanes.map((l) => l.label), ['ERROR', 'INFO', 'WARN']);
  });

  testWidgets('lanes are stacked by identity, not by their position in a bucket',
      (tester) async {
    // Bucket 1 has no ERROR. Matching segments to lanes by list position would paint its INFO
    // count in ERROR's red and its WARN count in INFO's blue.
    await _pump(tester, _bridge());
    final geo = _geo(tester);
    final second = geo.columns[1];
    expect(second.segments.map((s) => geo.lanes[s.laneIndex].label), ['INFO', 'WARN']);
    expect(second.segments.map((s) => s.count), [1, 1]);
    expect(second.count, 2);
  });

  testWidgets('recognised severities get semantic colours, not palette slots',
      (tester) async {
    await _pump(tester, _bridge());
    final lanes = _geo(tester).lanes;
    expect(lanes[0].color, MorphicColors.severityErrorDark);
    expect(lanes[1].color, MorphicColors.severityInfoDark);
    expect(lanes[2].color, MorphicColors.severityWarningDark);
  });

  testWidgets('the count axis uses whole events', (tester) async {
    await _pump(tester, _bridge());
    final geo = _geo(tester);
    expect(geo.countStep, 1);
    expect(geo.countTop, 3);
    // A taller fixture must still land on integers, and the axis must reach the tallest column.
    final tall = TimelineGeometry(
      lanes: const [],
      columns: [
        const TimelineColumn(
          startMs: 0,
          count: 10,
          segments: [TimelineSegment(laneIndex: 0, count: 10)],
        ),
      ],
      bucketMs: 60000,
      hasSeveritySplit: false,
    );
    expect(tall.countStep, 4);
    expect(tall.countTop, 12);
    expect(tall.countTop, greaterThanOrEqualTo(10));
  });

  testWidgets('large count ticks fit at 1.3x and taps follow the scaled plot', (tester) async {
    final scale = ValueNotifier<double>(1);
    addTearDown(scale.dispose);
    final bridge = _bridge(rows: [
      for (var i = 0; i < 12345; i++) [0, 'ERROR', 'item'],
      [60000, 'INFO', 'last'],
    ]);
    final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    await tester.pumpWidget(MaterialApp(
      theme: MorphicTheme.dark(),
      builder: (context, child) => ValueListenableBuilder<double>(
        valueListenable: scale,
        child: child,
        builder: (context, value, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(value)),
          child: child!,
        ),
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: engine,
            builder: (context, _) => TimelineView(
              ctx: ComponentContext(spec: engine.components.first, engine: engine),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final before = _geo(tester);
    final box = tester.getRect(find.byKey(const Key('timeline-plot')));
    scale.value = 1.3;
    await tester.pumpAndSettle();
    final painter = _painter(tester);
    final geometry = painter.geometry;
    final plot = geometry.plotIn(box.size);
    expect(identical(geometry, before), isFalse);
    expect(plot.left, greaterThan(before.plotIn(box.size).left));
    expect(plot.left, greaterThan(kTimelineAxisLeft));
    for (var i = 0; i < 4; i++) {
      final tick = formatChartValue((geometry.countStep * i).toDouble());
      final text = TextPainter(
        text: TextSpan(text: tick, style: painter.textStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
        textScaler: painter.textScaler,
      )..layout(maxWidth: plot.left - chartAxisLabelGap);
      expect(text.didExceedMaxLines, isFalse, reason: 'count tick $tick must fit');
      text.dispose();
    }

    final last = geometry.slotFor(geometry.columns.last, plot);
    await tester.tapAt(Offset(box.left + last.center.dx, box.top + last.center.dy));
    await tester.pumpAndSettle();
    final args = engine.globalFilters.single['args'] as List;
    expect(args[0], {'op': 'gte', 'field': 'ts', 'value': 60000});
  });

  testWidgets('tapping a bucket filters to a half-open time range', (tester) async {
    final engine = await _pump(tester, _bridge());
    await _tapColumn(tester, 1);
    expect(engine.globalFilters.length, 1);
    final range = engine.globalFilters.single;
    expect(range['op'], 'and');
    final args = range['args'] as List;
    expect(args[0], {'op': 'gte', 'field': 'ts', 'value': 60000});
    // Half-open: an event exactly on the next boundary belongs to the next bucket, not this one.
    expect(args[1], {'op': 'lt', 'field': 'ts', 'value': 120000});
    expect(_geo(tester).columns.map((c) => c.count), [2]);
  });

  testWidgets('tapping the selected bucket again clears the filter', (tester) async {
    final engine = await _pump(tester, _bridge());
    await _tapColumn(tester, 1);
    expect(engine.globalFilters, isNotEmpty);
    await _tapColumn(tester, 0); // the scene now holds only the selected bucket
    expect(engine.globalFilters, isEmpty);
    expect(_geo(tester).columns.length, 3);
  });

  testWidgets('the selected column is highlighted and described', (tester) async {
    await _pump(tester, _bridge());
    expect(_painter(tester).activeColumn, isNull);
    expect(find.byKey(const Key('timeline-selection')), findsNothing);
    await _tapColumn(tester, 1);
    expect(_painter(tester).activeColumn, 0);
    expect(find.byKey(const Key('timeline-selection')), findsOneWidget);
    expect(find.textContaining('2 events'), findsWidgets);
  });

  testWidgets('an orphaned bucket range is replaced, not accumulated', (tester) async {
    // A range left over from a selection the scene no longer contains. Two ranges on one field
    // would intersect to nothing, so a tap must replace its own kind rather than append.
    final engine = await _pump(tester, _bridge());
    await engine.applyCommands([
      Commands.setGlobalFilter([
        filterNode('and', args: [
          filterNode('gte', field: 'ts', value: 999),
          filterNode('lt', field: 'ts', value: 60999),
        ]),
      ]),
    ]);
    await tester.pumpAndSettle();
    expect(_painter(tester).activeColumn, isNull, reason: '999 is not a bucket start');
    await _tapColumn(tester, 0);
    expect(engine.globalFilters.length, 1);
    final args = engine.globalFilters.single['args'] as List;
    expect(args[0]['value'], 60000);
  });

  testWidgets("a user's own time filter survives a bucket tap", (tester) async {
    final engine = await _pump(tester, _bridge());
    await engine.applyCommands([
      Commands.setGlobalFilter([filterNode('gte', field: 'ts', value: 0)]),
    ]);
    await tester.pumpAndSettle();
    await _tapColumn(tester, 1);
    expect(engine.globalFilters.length, 2);
    expect(engine.globalFilters.first, {'op': 'gte', 'field': 'ts', 'value': 0});
  });

  testWidgets('clearing the filter elsewhere un-highlights the column', (tester) async {
    final engine = await _pump(tester, _bridge());
    await _tapColumn(tester, 1);
    expect(_painter(tester).activeColumn, 0);
    await engine.applyCommands([Commands.setGlobalFilter([])]);
    await tester.pumpAndSettle();
    expect(_painter(tester).activeColumn, isNull);
    expect(find.byKey(const Key('timeline-selection')), findsNothing);
  });

  testWidgets('a tap does nothing when the component cannot filter', (tester) async {
    final engine = await _pump(tester, _bridge(canFilter: false));
    await _tapColumn(tester, 1);
    expect(engine.globalFilters, isEmpty);
    expect(_geo(tester).columns.length, 3);
  });

  testWidgets('the legend hides a lane and leaves the other colours alone',
      (tester) async {
    await _pump(tester, _bridge());
    final before = _geo(tester).lanes.map((l) => l.color).toList();
    await tester.tap(find.byKey(const Key('timeline-legend-ERROR')));
    await tester.pumpAndSettle();
    final geo = _geo(tester);
    expect(geo.lanes.map((l) => l.label), ['INFO', 'WARN']);
    expect(geo.lanes[0].color, before[1]);
    expect(geo.lanes[1].color, before[2]);
    // Bucket 0 held ERROR 2 + INFO 1; hiding ERROR leaves 1 visible of 3 counted.
    expect(geo.columns.first.count, 3);
    expect(geo.columns.first.visibleCount, 1);
    expect(find.text('Show all'), findsOneWidget);
  });

  testWidgets('hiding every lane offers a way back', (tester) async {
    await _pump(tester, _bridge());
    for (final label in ['ERROR', 'INFO', 'WARN']) {
      await tester.tap(find.byKey(Key('timeline-legend-$label')));
      await tester.pumpAndSettle();
    }
    expect(find.text('Every lane is hidden.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('timeline-show-all-lanes')));
    await tester.pumpAndSettle();
    expect(_geo(tester).lanes.length, 3);
  });

  testWidgets('legend chips are a colour key even when selecting is disabled',
      (tester) async {
    await _pump(tester, _bridge(canSelect: false));
    final chip = tester.widget<TextButton>(
      find.byKey(const Key('timeline-legend-ERROR')),
    );
    expect(chip.onPressed, isNull);
    expect(find.byKey(const Key('timeline-legend-ERROR')), findsOneWidget);
  });

  testWidgets('no severity field means no legend, and the columns still draw',
      (tester) async {
    await _pump(tester, _bridge(severityField: null));
    final geo = _geo(tester);
    expect(geo.hasSeveritySplit, isFalse);
    expect(geo.columns.map((c) => c.count), [3, 2, 1]);
    expect(geo.columns.first.visibleCount, 3);
    expect(geo.lanes.single.color, MorphicColors.accent);
    expect(find.byKey(const Key('timeline-legend-ERROR')), findsNothing);
  });

  testWidgets('group_by supplies lanes when no severity field is named', (tester) async {
    // morphic-core falls back from severity_field to group_by; a fake that ignored it would
    // prove nothing about the timeline a grouped document actually produces.
    await _pump(tester, _bridge(severityField: null, groupBy: 'level'));
    expect(_geo(tester).hasSeveritySplit, isTrue);
    expect(_geo(tester).lanes.map((l) => l.label), ['ERROR', 'INFO', 'WARN']);
  });

  testWidgets('undated rows are reported, not silently dropped', (tester) async {
    await _pump(tester, _bridge());
    expect(find.byKey(const Key('timeline-partial-notice')), findsOneWidget);
    expect(find.textContaining('undated rows not placed'), findsOneWidget);
  });

  testWidgets('dropped lanes are reported', (tester) async {
    final bridge = _bridge()..chartExtraLanes = 4;
    await _pump(tester, bridge);
    expect(find.textContaining('Showing 3 of 7 lanes'), findsOneWidget);
  });

  testWidgets('a complete scene shows no partial warning', (tester) async {
    final rows = _rows().where((r) => r[0] != null).toList();
    await _pump(tester, _bridge(rows: rows));
    expect(find.byKey(const Key('timeline-partial-notice')), findsNothing);
  });

  testWidgets('no dated rows is an explicit state, not an empty box', (tester) async {
    await _pump(tester, _bridge(rows: []));
    expect(find.text('No dated rows match the current filters.'), findsOneWidget);
  });

  testWidgets('a failed read offers a retry that works', (tester) async {
    final bridge = _bridge()..failChart = true;
    await _pump(tester, bridge);
    expect(find.byKey(const Key('timeline-retry')), findsOneWidget);
    expect(find.text('This timeline could not be built.'), findsOneWidget);
    expect(find.textContaining('not a chart'), findsOneWidget);
    bridge.failChart = false;
    await tester.tap(find.byKey(const Key('timeline-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timeline-plot')), findsOneWidget);
  });

  testWidgets('View as table lists every bucket with its lane breakdown',
      (tester) async {
    await _pump(tester, _bridge());
    await tester.tap(find.byKey(const Key('timeline-view-as-table')));
    await tester.pumpAndSettle();
    expect(find.text('3 buckets of 1m'), findsOneWidget);
    expect(find.text('ERROR 2 · INFO 1'), findsOneWidget);
    expect(find.text('INFO 1 · WARN 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('timeline-table-close')));
    await tester.pumpAndSettle();
    expect(find.text('3 buckets of 1m'), findsNothing);
  });

  testWidgets('the chart carries a spoken summary naming the bucket step',
      (tester) async {
    await _pump(tester, _bridge());
    final semantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(const Key('timeline-plot')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(semantics.properties.label, contains('Timeline of ts'));
    expect(semantics.properties.label, contains('3 buckets of 1m'));
    expect(semantics.properties.label, contains('3 lanes shown'));
  });

  testWidgets('the selection is reachable without a pointer', (tester) async {
    final engine = await _pump(tester, _bridge());
    Semantics semantics() => tester.widget<Semantics>(
          find
              .ancestor(
                of: find.byKey(const Key('timeline-plot')),
                matching: find.byType(Semantics),
              )
              .first,
        );
    // SemanticsAction is not exported through material.dart, so invoke the callbacks the widget
    // actually installed rather than synthesising an action the test cannot name.
    semantics().properties.onIncrease!();
    await tester.pumpAndSettle();
    expect(engine.globalFilters, isNotEmpty);
    expect((engine.globalFilters.single['args'] as List)[0]['value'], 0);
  });

  testWidgets('a response from a superseded revision is discarded and re-read',
      (tester) async {
    final bridge = _bridge();
    final engine = _GatedChartController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    final first = engine.holdNext();
    final second = engine.holdNext();
    await tester.pumpWidget(MaterialApp(
      theme: MorphicTheme.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: engine,
            builder: (context, _) => TimelineView(
              ctx: ComponentContext(spec: engine.components.first, engine: engine),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await engine.applyCommands([
      Commands.setGlobalFilter([filterNode('gte', field: 'ts', value: 60000)]),
    ]);
    await tester.pump();
    second.complete();
    first.complete();
    await tester.pumpAndSettle();
    expect(bridge.chartCalls.length, greaterThanOrEqualTo(2));
    expect(_geo(tester).columns.map((c) => c.count), [2, 1]);
  });

  test('every severity colour clears 3:1 on its own theme surface', () {
    // Goldens cannot check this: the test font draws boxes and a pixel diff would not tell a
    // reviewer that a lane is invisible. WCAG 1.4.11 wants 3:1 for a meaningful graphic.
    double luminance(Color c) {
      double lin(double v) =>
          v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    double contrast(Color a, Color b) {
      final l1 = luminance(a);
      final l2 = luminance(b);
      return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
    }

    const dark = [
      MorphicColors.severityErrorDark,
      MorphicColors.severityWarningDark,
      MorphicColors.severityInfoDark,
      MorphicColors.severityOkDark,
      MorphicColors.severityMutedDark,
    ];
    const light = [
      MorphicColors.severityErrorLight,
      MorphicColors.severityWarningLight,
      MorphicColors.severityInfoLight,
      MorphicColors.severityOkLight,
      MorphicColors.severityMutedLight,
    ];
    for (var i = 0; i < dark.length; i++) {
      expect(contrast(dark[i], MorphicColors.surfaceDark), greaterThanOrEqualTo(3.0),
          reason: 'dark severity $i');
      expect(contrast(light[i], MorphicColors.surfaceLight), greaterThanOrEqualTo(3.0),
          reason: 'light severity $i');
    }
  });

  group('severity classification', () {
    test('recognises the spellings log sources actually emit', () {
      for (final s in ['ERROR', 'error', ' Error ', 'fatal', 'CRITICAL', 'panic']) {
        expect(severityBandOf(s), SeverityBand.error, reason: s);
      }
      for (final s in ['WARN', 'warning']) {
        expect(severityBandOf(s), SeverityBand.warning, reason: s);
      }
      for (final s in ['INFO', 'notice', 'information']) {
        expect(severityBandOf(s), SeverityBand.info, reason: s);
      }
      for (final s in ['debug', 'TRACE', 'verbose']) {
        expect(severityBandOf(s), SeverityBand.muted, reason: s);
      }
    });

    test('does not match on substrings', () {
      // A service named error_handler is not an error level, and `informational` is not `form`.
      expect(severityBandOf('error_handler'), SeverityBand.unknown);
      expect(severityBandOf('informational'), SeverityBand.unknown);
      expect(severityBandOf('warning_count'), SeverityBand.unknown);
      expect(severityBandOf(null), SeverityBand.unknown);
      expect(severityBandOf(''), SeverityBand.unknown);
    });

    test('an unrecognised lane still gets a distinct palette colour', () {
      final a = severityColor('svc-a', dark: true, index: 0);
      final b = severityColor('svc-b', dark: true, index: 1);
      expect(a, isNot(b));
      expect(a, MorphicColors.seriesDark[0]);
      // The palette wraps at MAX_SERIES rather than throwing.
      expect(severityColor('x', dark: true, index: 8), MorphicColors.seriesDark[0]);
    });
  });

  test('a tap resolves to the nearest column with events', () {
    final geo = TimelineGeometry(
      lanes: const [],
      columns: const [
        TimelineColumn(
          startMs: 0,
          count: 1,
          segments: [TimelineSegment(laneIndex: 0, count: 1)],
        ),
        TimelineColumn(
          startMs: 120000,
          count: 1,
          segments: [TimelineSegment(laneIndex: 0, count: 1)],
        ),
      ],
      bucketMs: 60000,
      hasSeveritySplit: false,
    );
    final plot = geo.plotIn(const Size(328, kTimelinePlotHeight));
    // The empty stretch between the two columns must still select real data, not filter the
    // workspace down to nothing.
    expect(geo.columnAt(plot.left, plot), 0);
    expect(geo.columnAt(plot.right, plot), 1);
    expect(geo.columnAt(plot.center.dx, plot), isNotNull);
  });
}