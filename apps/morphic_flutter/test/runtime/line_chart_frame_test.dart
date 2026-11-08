/// Frame-time harness for the line chart (M1.4 task 1.4.3, verification: "frame-time harness").
///
/// # What this measures, and what it does not
///
/// docs/architecture/07 §3 requires that scrubbing repaints the **overlay layer only**, so a
/// 2000-point chart does not re-rasterise its lines on every pointer move. That is a structural
/// claim, and this harness asserts it exactly: across a full drag, the base painter must report
/// `shouldRepaint == false` every single time, while the overlay reports true.
///
/// The wall-clock numbers are **build + layout + paint on the CI test runner**. There is no GPU
/// rasterisation in a widget test and no phone involved, so they are indicative only — the same
/// honesty rule the Rust chart bench and the AT-07 device probe already follow. No time budget
/// is asserted here: a shared runner's timing is not a device budget, and a flaky threshold
/// would be worse than an honest report. The device budget belongs to AT-07's phone harness.
///
/// Output is a `MORPHIC_FRAME_JSON` line, which CI lifts into the run's commit comment.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/line_chart_painter.dart';
import 'package:morphic_flutter/runtime/components/line_chart_view.dart';

import '../support/scripted_bridge.dart';

const String kFrameLogTag = 'MORPHIC_FRAME';

/// The engine's own ceilings: `MAX_CHART_POINTS` 2000 across at most `MAX_SERIES` 8.
const int _series = 8;
const int _buckets = 250;
const int _scrubSteps = 60;

List<List<dynamic>> _rows() => [
      for (var s = 0; s < _series; s++)
        for (var b = 0; b < _buckets; b++)
          [b * 60000, 's$s', ((s * 31 + b * 7) % 97).toDouble()],
    ];

Map<String, dynamic> get _spec => {
      'id': 'trend_over_time',
      'type': 'line_chart',
      'title': 'Latency over time',
      'binding': {
        'kind': 'line_chart',
        'x': 'ts',
        'y': [
          {'op': 'avg', 'field': 'latency'},
        ],
        'group_by': 'service',
      },
      'interactions': {'filter': true, 'select': true},
    };

LineChartPainter _base(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(const Key('line-base-paint'))).painter
        as LineChartPainter;

ScrubOverlayPainter _overlay(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(const Key('line-overlay-paint'))).painter
        as ScrubOverlayPainter;

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final i = ((sorted.length - 1) * p).round();
  return sorted[i];
}

void main() {
  testWidgets('scrubbing a 2000-point chart never repaints the line layer',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bridge = ScriptedBridge(
      rows: _rows(),
      fields: const ['ts', 'service', 'latency'],
      dtypes: const {'ts': 'timestamp', 'latency': 'float64'},
      components: [_spec],
      order: const ['trend_over_time'],
    );
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

    final geo = _base(tester).geometry;
    expect(geo.series.length, _series);
    expect(geo.firstPoints.length, _buckets);
    expect(geo.series.length * geo.firstPoints.length, 2000,
        reason: 'the harness must actually be at the engine ceiling to mean anything');

    final box = tester.getRect(find.byKey(const Key('line-plot')));
    final startX = box.left + kLineAxisLeft + 2;
    final endX = box.right - 8;
    final stepDx = (endX - startX) / _scrubSteps;

    final samples = <double>[];
    var baseRepaints = 0;
    var overlayRepaints = 0;
    var geometryRebuilds = 0;
    var bucketChanges = 0;

    final gesture = await tester.startGesture(Offset(startX, box.center.dy));
    await tester.pump();
    var previousBase = _base(tester);
    var previousOverlay = _overlay(tester);

    for (var i = 1; i <= _scrubSteps; i++) {
      await gesture.moveTo(Offset(startX + stepDx * i, box.center.dy));
      final watch = Stopwatch()..start();
      await tester.pump();
      watch.stop();
      samples.add(watch.elapsedMicroseconds / 1000.0);

      final nextBase = _base(tester);
      final nextOverlay = _overlay(tester);
      // The whole point of the two-layer split. A new painter instance is built every rebuild;
      // what must not happen is that instance asking to be painted.
      if (nextBase.shouldRepaint(previousBase)) baseRepaints++;
      if (!identical(nextBase.geometry, previousBase.geometry)) geometryRebuilds++;
      if (nextOverlay.shouldRepaint(previousOverlay)) overlayRepaints++;
      if (nextOverlay.bucketIndex != previousOverlay.bucketIndex) bucketChanges++;
      previousBase = nextBase;
      previousOverlay = nextOverlay;
    }
    await gesture.up();
    await tester.pumpAndSettle();

    samples.sort();
    final median = _percentile(samples, 0.5);
    final p95 = _percentile(samples, 0.95);
    final worst = samples.isEmpty ? 0.0 : samples.last;

    final report = {
      'schema': 'morphic/frame-probe/1',
      'surface': 'host test runner: build+layout+paint, no GPU raster, not a phone',
      'series': _series,
      'buckets': _buckets,
      'points': _series * _buckets,
      'scrubSteps': _scrubSteps,
      'bucketChanges': bucketChanges,
      'baseLayerRepaints': baseRepaints,
      'geometryRebuilds': geometryRebuilds,
      'overlayRepaints': overlayRepaints,
      'medianMs': double.parse(median.toStringAsFixed(3)),
      'p95Ms': double.parse(p95.toStringAsFixed(3)),
      'worstMs': double.parse(worst.toStringAsFixed(3)),
      'passes': baseRepaints == 0 && geometryRebuilds == 0 && bucketChanges > 0,
    };
    // ignore: avoid_print
    print('${kFrameLogTag}_JSON ${jsonEncode(report)}');
    // ignore: avoid_print
    print('$kFrameLogTag ${baseRepaints == 0 ? "OVERLAY_ONLY" : "BASE_REPAINTED"}: '
        '$baseRepaints base repaints over $_scrubSteps scrub steps at 2000 points; '
        'median ${median.toStringAsFixed(2)} ms, p95 ${p95.toStringAsFixed(2)} ms '
        '(host runner, not a device)');

    expect(baseRepaints, 0,
        reason: 'scrubbing must not repaint the lines — docs/architecture/07 §3');
    expect(geometryRebuilds, 0,
        reason: 'the geometry must stay memoised across pointer moves');
    expect(bucketChanges, greaterThan(0),
        reason: 'a drag that never changed bucket would prove nothing');
    expect(overlayRepaints, bucketChanges,
        reason: 'the overlay repaints exactly when the bucket changes, not per pixel');
  });

  testWidgets('a legend toggle does rebuild the line layer', (tester) async {
    // The counterpart: if the base layer never repainted at all, the assertion above would be
    // vacuous. Hiding a series must change the geometry and ask for a repaint.
    final bridge = ScriptedBridge(
      rows: _rows(),
      fields: const ['ts', 'service', 'latency'],
      dtypes: const {'ts': 'timestamp', 'latency': 'float64'},
      components: [_spec],
      order: const ['trend_over_time'],
    );
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

    final before = _base(tester);
    await tester.tap(find.byKey(const Key('line-legend-s0')));
    await tester.pumpAndSettle();
    final after = _base(tester);
    expect(identical(before.geometry, after.geometry), isFalse);
    expect(after.shouldRepaint(before), isTrue);
    expect(after.geometry.series.length, _series - 1);
  });
}