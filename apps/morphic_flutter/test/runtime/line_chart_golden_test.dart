/// Golden images for the line chart (M1.4 task 1.4.3), across themes and states.
///
/// Bundled Inter and JetBrains Mono are loaded explicitly so these images pin readable text,
/// geometry, color and spacing. The indeterminate loading animation is not captured because
/// its pixels depend on animation phase. Regenerate with the CI subject marker.
@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/line_chart_view.dart';

import '../support/golden_fonts.dart';
import '../support/scripted_bridge.dart';

const Size _surface = Size(360, 620);

Map<String, dynamic> _spec({String? groupBy = 'service'}) => {
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
      'interactions': {'filter': true, 'select': true},
    };

/// Six buckets, three series, and a deliberate hole: `web` is absent from the middle buckets so
/// the gap is visible in the image rather than only asserted in a test.
List<List<dynamic>> get _rows => [
      for (var b = 0; b < 6; b++) [b * 60000, 'api', 10.0 + b * 6],
      for (var b = 0; b < 6; b++) [b * 60000, 'batch', 30.0 - b * 3],
      [0, 'web', 8],
      [60000, 'web', 12],
      [300000, 'web', 20],
    ];

Future<void> _pumpChart(
  WidgetTester tester, {
  required Brightness brightness,
  double textScale = 1.0,
  String? groupBy = 'service',
  List<List<dynamic>>? rows,
  bool fail = false,
  bool downsampled = false,
  int extraSeries = 0,
  String? hideSeries,
  double? scrubFraction,
}) async {
  tester.view.physicalSize = _surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final bridge = ScriptedBridge(
    rows: rows ?? _rows,
    fields: const ['ts', 'service', 'latency'],
    dtypes: const {'ts': 'timestamp', 'latency': 'float64'},
    components: [_spec(groupBy: groupBy)],
    order: const ['trend_over_time'],
  )
    ..failChart = fail
    ..chartDownsampled = downsampled
    ..chartExtraSeries = extraSeries;
  final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await engine.open('w1');

  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.dark ? MorphicTheme.dark() : MorphicTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(
        size: _surface,
        devicePixelRatio: 1.0,
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: engine,
            builder: (context, _) => LineChartView(
              ctx: ComponentContext(spec: engine.components.first, engine: engine),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();

  if (hideSeries != null) {
    await tester.tap(find.byKey(Key('line-legend-$hideSeries')));
    await tester.pumpAndSettle();
  }
  if (scrubFraction != null) {
    final box = tester.getRect(find.byKey(const Key('line-plot')));
    await tester.tapAt(Offset(
      box.left + box.width * scrubFraction,
      box.center.dy,
    ));
    await tester.pumpAndSettle();
  }
}

void main() {
  setUpAll(loadMorphicGoldenFonts);
  for (final theme in <String, Brightness>{
    'dark': Brightness.dark,
    'light': Brightness.light,
  }.entries) {
    group(theme.key, () {
      testWidgets('ready', (tester) async {
        await _pumpChart(tester, brightness: theme.value);
        await expectLater(
          find.byType(LineChartView),
          matchesGoldenFile('goldens/line_chart_${theme.key}_ready.png'),
        );
      });

      testWidgets('single series', (tester) async {
        await _pumpChart(tester, brightness: theme.value, groupBy: null);
        await expectLater(
          find.byType(LineChartView),
          matchesGoldenFile('goldens/line_chart_${theme.key}_single.png'),
        );
      });

      testWidgets('scrubbing', (tester) async {
        await _pumpChart(tester, brightness: theme.value, scrubFraction: 0.62);
        await expectLater(
          find.byType(LineChartView),
          matchesGoldenFile('goldens/line_chart_${theme.key}_scrub.png'),
        );
      });

      testWidgets('a series hidden', (tester) async {
        await _pumpChart(tester, brightness: theme.value, hideSeries: 'batch');
        await expectLater(
          find.byType(LineChartView),
          matchesGoldenFile('goldens/line_chart_${theme.key}_hidden_series.png'),
        );
      });

      testWidgets('dropped series warning', (tester) async {
        await _pumpChart(tester, brightness: theme.value, extraSeries: 4);
        await expectLater(
          find.byType(LineChartView),
          matchesGoldenFile('goldens/line_chart_${theme.key}_partial_series.png'),
        );
      });

      testWidgets('merged buckets warning', (tester) async {
        await _pumpChart(tester, brightness: theme.value, downsampled: true);
        await expectLater(
          find.byType(LineChartView),
          matchesGoldenFile('goldens/line_chart_${theme.key}_downsampled.png'),
        );
      });

      testWidgets('empty', (tester) async {
        await _pumpChart(tester, brightness: theme.value, rows: []);
        await expectLater(
          find.byType(LineChartView),
          matchesGoldenFile('goldens/line_chart_${theme.key}_empty.png'),
        );
      });

      testWidgets('failed', (tester) async {
        await _pumpChart(tester, brightness: theme.value, fail: true);
        await expectLater(
          find.byType(LineChartView),
          matchesGoldenFile('goldens/line_chart_${theme.key}_failed.png'),
        );
      });

      testWidgets('at 1.3x text scale', (tester) async {
        await _pumpChart(tester, brightness: theme.value, textScale: 1.3);
        await expectLater(
          find.byType(LineChartView),
          matchesGoldenFile('goldens/line_chart_${theme.key}_text_scale_130.png'),
        );
      });
    });
  }
}