/// Golden images for the bar chart (M1.4 task 1.4.2), across themes and states.
///
/// **What these images do and do not pin.** Flutter's default test font renders every glyph as a
/// box, and this repository ships no font asset, so these goldens cannot verify that the right
/// *words* are drawn. They pin what a text-only test cannot: bar geometry, ordering, the
/// remainder and null bars, colour and contrast per theme, spacing, the truncation notice, and
/// the layout under a 1.3× text scale. Text *content* is asserted in `bar_chart_test.dart`.
/// Wiring a real font would upgrade these to full visual checks; that is recorded as a gap
/// rather than implied by the presence of PNG files.
///
/// The loading state is deliberately not captured: it draws an indeterminate spinner, so its
/// pixels depend on animation phase and would be flaky.
///
/// Regenerate with `[regenerate-goldens]` in the commit message (or let CI seed them on the
/// first run), exactly as the Rust `insta` snapshots work.
@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/bar_chart_view.dart';

import '../support/scripted_bridge.dart';

/// A phone-width surface at a 1:1 device pixel ratio: golden bytes must not depend on the
/// runner's window size.
const Size _surface = Size(360, 460);

Map<String, dynamic> _spec({int limit = 4}) => {
      'id': 'breakdown_by_region',
      'type': 'bar_chart',
      'title': 'Average amount by region',
      'binding': {
        'kind': 'bar_chart',
        'dimension': 'region',
        'measure': {'op': 'avg', 'field': 'amount'},
        'limit': limit,
      },
      'interactions': {'filter': true, 'sort': true},
    };

List<List<dynamic>> get _rows => [
      ['eu', 10],
      ['us', 5],
      ['eu', 30],
      ['latam', 60],
      ['apac', 1],
      ['mea', 2],
    ];

Future<void> _pumpChart(
  WidgetTester tester, {
  required Brightness brightness,
  double textScale = 1.0,
  List<List<dynamic>>? rows,
  int limit = 4,
  bool fail = false,
  bool truncated = false,
  Map<String, dynamic>? activeFilter,
  bool sortedByLabel = false,
}) async {
  tester.view.physicalSize = _surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final bridge = ScriptedBridge(
    rows: rows ?? _rows,
    fields: const ['region', 'amount'],
    dtypes: const {'amount': 'int64'},
    components: [_spec(limit: limit)],
    order: const ['breakdown_by_region'],
  )
    ..failChart = fail
    ..chartTruncated = truncated;
  final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await engine.open('w1');
  if (activeFilter != null) {
    await engine.applyCommands([
      Commands.setGlobalFilter([activeFilter]),
    ]);
  }
  if (sortedByLabel) {
    await engine.applyCommands([
      Commands.setComponentSort('breakdown_by_region', const [
        SortRule(field: 'region'),
      ]),
    ]);
  }

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
            builder: (context, _) => BarChartView(
              ctx: ComponentContext(spec: engine.components.first, engine: engine),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  for (final theme in <String, Brightness>{
    'dark': Brightness.dark,
    'light': Brightness.light,
  }.entries) {
    group(theme.key, () {
      testWidgets('ready', (tester) async {
        // Every category kept, so no remainder bar: distinct from the 'other' case below.
        await _pumpChart(tester, brightness: theme.value, limit: 6);
        await expectLater(
          find.byType(BarChartView),
          matchesGoldenFile('goldens/bar_chart_${theme.key}_ready.png'),
        );
      });

      testWidgets('with a remainder bucket', (tester) async {
        await _pumpChart(tester, brightness: theme.value, limit: 3);
        await expectLater(
          find.byType(BarChartView),
          matchesGoldenFile('goldens/bar_chart_${theme.key}_other.png'),
        );
      });

      testWidgets('with a null category', (tester) async {
        await _pumpChart(
          tester,
          brightness: theme.value,
          limit: 3,
          rows: [..._rows, [null, 99]],
        );
        await expectLater(
          find.byType(BarChartView),
          matchesGoldenFile('goldens/bar_chart_${theme.key}_null_category.png'),
        );
      });

      testWidgets('one bar active', (tester) async {
        await _pumpChart(
          tester,
          brightness: theme.value,
          activeFilter: filterNode('eq', field: 'region', value: 'eu'),
        );
        await expectLater(
          find.byType(BarChartView),
          matchesGoldenFile('goldens/bar_chart_${theme.key}_active.png'),
        );
      });

      testWidgets('sorted by label', (tester) async {
        await _pumpChart(tester, brightness: theme.value, sortedByLabel: true);
        await expectLater(
          find.byType(BarChartView),
          matchesGoldenFile('goldens/bar_chart_${theme.key}_label_order.png'),
        );
      });

      testWidgets('partial scene warning', (tester) async {
        // The accumulation-cap flag, not a small limit: a limit cutting categories is the
        // Other bucket above. The fake groups in memory and cannot breach 100k groups itself.
        await _pumpChart(
          tester,
          brightness: theme.value,
          limit: 3,
          truncated: true,
        );
        await expectLater(
          find.byType(BarChartView),
          matchesGoldenFile('goldens/bar_chart_${theme.key}_partial.png'),
        );
      });

      testWidgets('empty', (tester) async {
        await _pumpChart(tester, brightness: theme.value, rows: []);
        await expectLater(
          find.byType(BarChartView),
          matchesGoldenFile('goldens/bar_chart_${theme.key}_empty.png'),
        );
      });

      testWidgets('failed', (tester) async {
        await _pumpChart(tester, brightness: theme.value, fail: true);
        await expectLater(
          find.byType(BarChartView),
          matchesGoldenFile('goldens/bar_chart_${theme.key}_failed.png'),
        );
      });

      testWidgets('at 1.3x text scale', (tester) async {
        await _pumpChart(tester, brightness: theme.value, textScale: 1.3, limit: 3);
        await expectLater(
          find.byType(BarChartView),
          matchesGoldenFile('goldens/bar_chart_${theme.key}_text_scale_130.png'),
        );
      });
    });
  }
}