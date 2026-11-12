/// Metric and table snapshots complete the five runtime component families.
@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/design_system/tokens.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';
import 'package:morphic_flutter/runtime/components/data_table_view.dart';
import 'package:morphic_flutter/runtime/components/metric_card_view.dart';

import '../support/golden_fonts.dart';
import '../support/scripted_bridge.dart';

Future<void> _pumpComponent(
  WidgetTester tester, {
  required Brightness brightness,
  required bool metric,
  bool error = false,
  bool empty = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final bridge = ScriptedBridge(
    rows: empty
        ? []
        : [
            ['eu', 10, null],
            ['us', 20, 'alpha'],
            ['apac', 30, 'beta'],
          ],
    metrics: empty ? {'total_records': null} : {'total_records': 1234},
  )
    ..failMetric = metric && error
    ..failQuery = !metric && error;
  final engine = EngineController(bridge: bridge, storageRoot: '/local/morphic');
  await engine.open('w1');
  final spec = engine.components.firstWhere(
    (component) => component['type'] == (metric ? 'metric_card' : 'data_table'),
  );
  final ctx = ComponentContext(spec: spec, engine: engine);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.dark ? MorphicTheme.dark() : MorphicTheme.light(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 360,
          child: metric ? MetricCardView(ctx: ctx) : DataTableView(ctx: ctx, height: 400),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadMorphicGoldenFonts);
  for (final entry in {'dark': Brightness.dark, 'light': Brightness.light}.entries) {
    for (final state in ['ready', 'empty', 'error']) {
      for (final kind in ['metric', 'table']) {
        testWidgets('$kind $state ${entry.key}', (tester) async {
          final metric = kind == 'metric';
          await _pumpComponent(
            tester,
            brightness: entry.value,
            metric: metric,
            empty: state == 'empty',
            error: state == 'error',
          );
          await expectLater(
            find.byType(metric ? MetricCardView : DataTableView),
            matchesGoldenFile('goldens/${kind}_${entry.key}_$state.png'),
          );
        });
      }
    }
  }
}
