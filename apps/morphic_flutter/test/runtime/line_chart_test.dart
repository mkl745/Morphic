/// Widget tests for the line-chart renderer (M1.4 task 1.4.3).
///
/// The fixture is chosen so the interesting failures are visible: `web` has no row in the middle
/// bucket, so a renderer that treats a null as zero draws a V it has no data for, and the two
/// series have different row counts so the engine's ordering is observable.
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
import 'package:morphic_flutter/runtime/components/line_chart_painter.dart';
import 'package:morphic_flutter/runtime/components/line_chart_view.dart';

import '../support/scripted_bridge.dart';

Map<String, dynamic> _spec({String? groupBy = 'service', bool canSelect = true}) => {
      'id': 'trend_over_time',
      'type': 'line_chart',
      'title': 'Latency over time',
      'binding': {
        'kind': 'line_chart',
        'x': 'ts',
        'y': [
          {'op': 'avg', 'field': 'latency'},
        ],
        if (groupBy != null) 'group_by': groupBy,
      },
      'interactions': {'filter': true, 'select': canSelect},
    };

/// api has three buckets, web only the first and last — the middle is a genuine gap.
List<List<dynamic>> _rows() => [
      [0, 'api', 10],
      [60000, 'api', 20],
      [120000, 'api', 30],
      [0, 'web', 5],
      [120000, 'web', 15],
    ];

ScriptedBridge _bridge({
  String? groupBy = 'service',
  bool canSelect = true,
  List<List<dynamic>>? rows,
}) =>
    ScriptedBridge(
      rows: rows ?? _rows(),
      fields: const ['ts', 'service', 'latency'],
      dtypes: const {'ts': 'timestamp', 'latency': 'float64'},
      components: [_spec(groupBy: groupBy, canSelect: canSelect)],
      order: const ['trend_over_time'],
    );

Future<EngineController> _pump(WidgetTester tester, ScriptedBridge bridge) async {
  final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await engine.open('w1');
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: AnimatedBuilder(
          animation: engine,
          builder: (context, _) => LineChartView(
            ctx: ComponentContext(spec: engine.components.first, engine: engine),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return engine;
}

LineChartPainter _basePainter(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(const Key('line-base-paint'))).painter
        as LineChartPainter;

ScrubOverlayPainter _overlayPainter(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(const Key('line-overlay-paint'))).painter
        as ScrubOverlayPainter;

/// Computes each chart read eagerly, then holds delivery on a gate — the only way to observe a
/// response from a revision the workspace has already left.
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
    expect(bridge.chartCalls, ['trend_over_time']);
    expect(find.text('Latency over time'), findsOneWidget);
    expect(find.byKey(const Key('line-plot')), findsOneWidget);
    final geo = _basePainter(tester).geometry;
    expect(geo.series.map((s) => s.name), ['api', 'web']);
    expect(geo.firstPoints.length, 3);
    expect(geo.temporal, isTrue);
    expect(geo.bucketMs, 60000);
  });

  testWidgets('a null y stays null all the way to the painter', (tester) async {
    // The engine sends a gap; a renderer that coerced it to zero would draw a V for a bucket
    // where web has no rows at all.
    await _pump(tester, _bridge());
    final web = _basePainter(tester).geometry.series[1];
    expect(web.points.map((p) => p.y), [5.0, null, 15.0]);
  });

  testWidgets('the legend names every series and hides one on tap', (tester) async {
    await _pump(tester, _bridge());
    expect(find.byKey(const Key('line-legend-api')), findsOneWidget);
    expect(find.byKey(const Key('line-legend-web')), findsOneWidget);
    expect(_basePainter(tester).geometry.series.length, 2);

    await tester.tap(find.byKey(const Key('line-legend-web')));
    await tester.pumpAndSettle();
    expect(_basePainter(tester).geometry.series.map((s) => s.name), ['api']);

    await tester.tap(find.byKey(const Key('line-legend-web')));
    await tester.pumpAndSettle();
    expect(_basePainter(tester).geometry.series.length, 2);
  });

  testWidgets('hiding a series does not recolour the others', (tester) async {
    // Colour follows the engine's index. Re-indexing the visible list would repaint every
    // remaining line a different colour each time a legend chip is tapped.
    await _pump(tester, _bridge());
    final webColor = _basePainter(tester).geometry.series[1].color;
    await tester.tap(find.byKey(const Key('line-legend-api')));
    await tester.pumpAndSettle();
    final geo = _basePainter(tester).geometry;
    expect(geo.series.single.name, 'web');
    expect(geo.series.single.color, webColor);
  });

  testWidgets('hiding every series says so and can be undone', (tester) async {
    await _pump(tester, _bridge());
    await tester.tap(find.byKey(const Key('line-legend-api')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('line-legend-web')));
    await tester.pumpAndSettle();
    expect(find.text('All series are hidden.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('line-show-all')));
    await tester.pumpAndSettle();
    expect(find.text('All series are hidden.'), findsNothing);
    expect(_basePainter(tester).geometry.series.length, 2);
  });

  testWidgets('a single series needs no legend', (tester) async {
    await _pump(tester, _bridge(groupBy: null));
    expect(_basePainter(tester).geometry.series.length, 1);
    expect(find.byKey(const Key('line-legend-api')), findsNothing);
  });

  testWidgets('a component that disallows selection gets no legend', (tester) async {
    await _pump(tester, _bridge(canSelect: false));
    expect(find.byKey(const Key('line-legend-api')), findsNothing);
    expect(find.byKey(const Key('line-legend-web')), findsNothing);
  });

  testWidgets('scrubbing reads the bucket under the finger', (tester) async {
    await _pump(tester, _bridge());
    expect(find.byKey(const Key('line-tooltip')), findsNothing);
    final box = tester.getRect(find.byKey(const Key('line-plot')));
    await tester.tapAt(Offset(box.right - 2, box.center.dy));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('line-tooltip')), findsOneWidget);
    expect(_overlayPainter(tester).bucketIndex, 2);
    // The last bucket: api 30, web 15.
    expect(find.text('30'), findsOneWidget);
    expect(find.text('15'), findsOneWidget);
    expect(find.textContaining('1970-01-01'), findsOneWidget);
  });

  testWidgets('the tooltip shows a gap as absent, not as zero', (tester) async {
    await _pump(tester, _bridge());
    final box = tester.getRect(find.byKey(const Key('line-plot')));
    await tester.tapAt(Offset(box.center.dx, box.center.dy));
    await tester.pumpAndSettle();
    expect(_overlayPainter(tester).bucketIndex, 1);
    expect(find.text('20'), findsOneWidget); // api
    expect(find.text('—'), findsOneWidget); // web has no row here
    expect(find.text('0'), findsNothing);
  });

  testWidgets('dragging moves the scrub across buckets', (tester) async {
    await _pump(tester, _bridge());
    final box = tester.getRect(find.byKey(const Key('line-plot')));
    final gesture = await tester.startGesture(Offset(box.left + 50, box.center.dy));
    await tester.pump();
    // A pan is only recognised once the pointer clears Flutter's touch slop (~18dp), so a bare
    // press has not started a scrub yet. Move past it, still inside the first bucket. Tap to
    // inspect is covered separately; this test is about dragging.
    await gesture.moveTo(Offset(box.left + 80, box.center.dy));
    await tester.pump();
    final first = _overlayPainter(tester).bucketIndex;
    await gesture.moveTo(Offset(box.right - 2, box.center.dy));
    await tester.pump();
    final last = _overlayPainter(tester).bucketIndex;
    await gesture.up();
    await tester.pumpAndSettle();
    expect(first, 0);
    expect(last, 2);
  });

  testWidgets('View as table lists every bucket for every visible series',
      (tester) async {
    await _pump(tester, _bridge());
    await tester.tap(find.byKey(const Key('line-view-as-table')));
    await tester.pumpAndSettle();
    expect(find.text('3 buckets of 1m'), findsOneWidget);
    expect(find.text('api'), findsWidgets);
    expect(find.text('web'), findsWidgets);
    expect(find.text('10'), findsOneWidget);
    await tester.tap(find.byKey(const Key('line-table-close')));
    await tester.pumpAndSettle();
    expect(find.text('3 buckets of 1m'), findsNothing);
  });

  testWidgets('the table honours the legend, and says what is hidden', (tester) async {
    await _pump(tester, _bridge());
    await tester.tap(find.byKey(const Key('line-legend-web')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('line-view-as-table')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 series hidden'), findsOneWidget);
  });

  testWidgets('an empty selection says so instead of drawing empty axes', (tester) async {
    await _pump(tester, _bridge(rows: []));
    expect(find.text('No rows match the current filters.'), findsOneWidget);
    expect(find.byKey(const Key('line-plot')), findsNothing);
  });

  testWidgets('a failed read offers a retry that works', (tester) async {
    final bridge = _bridge()..failChart = true;
    await _pump(tester, bridge);
    expect(find.byKey(const Key('line-retry')), findsOneWidget);
    expect(find.textContaining('not a chart'), findsOneWidget);
    bridge.failChart = false;
    await tester.tap(find.byKey(const Key('line-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('line-retry')), findsNothing);
    expect(find.byKey(const Key('line-plot')), findsOneWidget);
  });

  testWidgets('dropped series are announced, never summed into a fake line',
      (tester) async {
    final bridge = _bridge()..chartExtraSeries = 3;
    await _pump(tester, bridge);
    expect(find.byKey(const Key('line-partial-notice')), findsOneWidget);
    expect(find.textContaining('not drawn'), findsOneWidget);
    // Two real series, not three: the dropped ones must not appear as an aggregate.
    expect(_basePainter(tester).geometry.series.length, 2);
  });

  testWidgets('merged buckets are announced too', (tester) async {
    final bridge = _bridge()..chartDownsampled = true;
    await _pump(tester, bridge);
    expect(find.byKey(const Key('line-partial-notice')), findsOneWidget);
    expect(find.textContaining('Buckets merged'), findsOneWidget);
  });

  testWidgets('a complete scene shows no partial warning', (tester) async {
    await _pump(tester, _bridge());
    expect(find.byKey(const Key('line-partial-notice')), findsNothing);
  });

  testWidgets('the chart carries a spoken summary naming the bucket step',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _bridge());
    expect(
      find.bySemanticsLabel(RegExp(r'Line chart of ts over time, 2 series shown')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp(r'3 buckets of 1m')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the scrub is reachable without a pointer', (tester) async {
    await _pump(tester, _bridge());
    // The plot declares semantic increase/decrease, which is what exposes the scrub to a
    // screen reader or a switch. Asserting the declaration and then invoking it covers both
    // the exposure and the behaviour without depending on dart:ui's action enum.
    final plotSemantics = tester.widget<Semantics>(
      find.ancestor(
        of: find.byKey(const Key('line-plot')),
        matching: find.byType(Semantics),
      ).first,
    );
    final increase = plotSemantics.properties.onIncrease;
    final decrease = plotSemantics.properties.onDecrease;
    expect(increase, isNotNull);
    expect(decrease, isNotNull);

    increase!();
    await tester.pumpAndSettle();
    expect(_overlayPainter(tester).bucketIndex, 0);
    increase();
    await tester.pumpAndSettle();
    expect(_overlayPainter(tester).bucketIndex, 1);
    decrease!();
    await tester.pumpAndSettle();
    expect(_overlayPainter(tester).bucketIndex, 0);
    // Clamped at the start rather than wrapping to the far end of the axis.
    decrease();
    await tester.pumpAndSettle();
    expect(_overlayPainter(tester).bucketIndex, 0);
  });

  testWidgets('a response from a superseded revision is discarded and re-read',
      (tester) async {
    final bridge = _bridge();
    final engine = _GatedChartController(bridge: bridge, storageRoot: '/tmp/m');
    await engine.open('w1');
    final ctx = ComponentContext(spec: engine.components.first, engine: engine);
    final slow = engine.holdNext();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LineChartView(ctx: ctx))));
    await tester.pump();
    expect(bridge.chartCalls.length, 1);

    await engine.applyCommands([
      Commands.setGlobalFilter([
        filterNode('eq', field: 'service', value: 'api'),
      ]),
    ]);
    slow.complete();
    await tester.pumpAndSettle();

    expect(bridge.chartCalls.length, greaterThanOrEqualTo(2));
    expect(_basePainter(tester).geometry.series.map((s) => s.name), ['api'],
        reason: 'web is filtered out; drawing it would be a torn frame');
  });

  test('every series colour clears 3:1 on its own theme surface', () {
    // Goldens cannot check this: the test font draws boxes and a pixel diff would not tell a
    // reviewer a line is invisible. WCAG 1.4.11 wants 3:1 for a meaningful graphic.
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

    expect(MorphicColors.seriesDark.length, 8, reason: 'MAX_SERIES is 8');
    expect(MorphicColors.seriesLight.length, 8);
    for (var i = 0; i < 8; i++) {
      expect(
        contrast(MorphicColors.seriesDark[i], MorphicColors.surfaceDark),
        greaterThanOrEqualTo(3.0),
        reason: 'dark series $i',
      );
      expect(
        contrast(MorphicColors.seriesLight[i], MorphicColors.surfaceLight),
        greaterThanOrEqualTo(3.0),
        reason: 'light series $i',
      );
    }
  });

  test('a flat series is centred rather than pinned to the baseline', () {
    final geo = LineGeometry(
      series: [
        LineSeriesDatum(
          name: 'flat',
          points: const [
            SeriesPoint(x: 0, y: 42),
            SeriesPoint(x: 1, y: 42),
          ],
          color: MorphicColors.seriesDark.first,
        ),
      ],
      temporal: false,
      bucketMs: 0,
    );
    final (lo, hi) = geo.yExtent!;
    expect(lo, lessThan(42));
    expect(hi, greaterThan(42));
    final plot = geo.plotIn(const Size(300, 200));
    expect(geo.yToPixel(42, plot), closeTo(plot.center.dy, 0.01));
  });

  group('a lone point between gaps', () {
    LineSeriesDatum datum(List<double?> ys) => LineSeriesDatum(
          name: 's',
          points: [
            for (var i = 0; i < ys.length; i++) SeriesPoint(x: i * 60000.0, y: ys[i]),
          ],
          color: const Color(0xFF000000),
        );

    test('is marked, because a line needs two points to exist', () {
      // The bug the golden caught: web had a real measurement in the last bucket with gaps on
      // both sides, so no segment was drawn and the value silently vanished from the chart.
      expect(datum([1, null, 5, null, 9]).isolatedIndices, [2]);
    });

    test('includes the ends when they stand alone', () {
      expect(datum([1, null, null]).isolatedIndices, [0]);
      expect(datum([null, null, 9]).isolatedIndices, [2]);
      expect(datum([1, null, 9]).isolatedIndices, [0, 2]);
    });

    test('excludes points that a segment already draws', () {
      expect(datum([1, 2, 3]).isolatedIndices, isEmpty);
      expect(datum([null, 2, 3, null]).isolatedIndices, isEmpty);
    });

    test('is the degenerate case of a single-point series', () {
      expect(datum([7]).isolatedIndices, [0]);
      expect(datum([null]).isolatedIndices, isEmpty);
      expect(datum(<double?>[]).isolatedIndices, isEmpty);
    });
  });

  test('an all-null series has no extent and is not drawn as zeros', () {
    final geo = LineGeometry(
      series: [
        LineSeriesDatum(
          name: 'empty',
          points: const [SeriesPoint(x: 0, y: null), SeriesPoint(x: 1, y: null)],
          color: MorphicColors.seriesDark.first,
        ),
      ],
      temporal: false,
      bucketMs: 0,
    );
    expect(geo.yExtent, isNull);
    expect(geo.isEmpty, isTrue);
  });
}