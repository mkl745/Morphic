/// Golden images for the timeline (M1.4 task 1.4.4), across themes and states.
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
import 'package:morphic_flutter/runtime/components/timeline_painter.dart';
import 'package:morphic_flutter/runtime/components/timeline_view.dart';

import '../support/golden_fonts.dart';
import '../support/scripted_bridge.dart';

const Size _surface = Size(360, 620);

Map<String, dynamic> _spec({String? severityField = 'level'}) => {
      'id': 'event_timeline',
      'type': 'timeline',
      'title': 'Events over time',
      'binding': {
        'kind': 'timeline',
        'time_field': 'ts',
        if (severityField != null) 'severity_field': severityField,
      },
      'interactions': {'filter': true, 'select': true},
    };

/// Six buckets with a rising and falling shape, and one bucket where the top severity is absent
/// so a wrong lane mapping would be visible as a colour in the wrong band.
List<List<dynamic>> get _rows => [
      for (var b = 0; b < 6; b++)
        for (var i = 0; i <= b; i++) [b * 60000, 'INFO', 'i$b-$i'],
      [0, 'ERROR', 'e0'],
      [60000, 'ERROR', 'e1'],
      [60000, 'ERROR', 'e1b'],
      [240000, 'ERROR', 'e4'],
      [300000, 'WARN', 'w5'],
      [120000, 'WARN', 'w2'],
      [null, 'ERROR', 'undated'],
    ];

Future<void> _pumpChart(
  WidgetTester tester, {
  required Brightness brightness,
  double textScale = 1.0,
  String? severityField = 'level',
  List<List<dynamic>>? rows,
  bool fail = false,
  int extraLanes = 0,
  String? hideLane,
  bool hideAll = false,
  int? selectColumn,
}) async {
  tester.view.physicalSize = _surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final bridge = ScriptedBridge(
    rows: rows ?? _rows,
    fields: const ['ts', 'level', 'msg'],
    dtypes: const {'ts': 'timestamp'},
    components: [_spec(severityField: severityField)],
    order: const ['event_timeline'],
  )
    ..failChart = fail
    ..chartExtraLanes = extraLanes;
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
            builder: (context, _) => TimelineView(
              ctx: ComponentContext(spec: engine.components.first, engine: engine),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();

  if (hideLane != null) {
    await tester.tap(find.byKey(Key('timeline-legend-$hideLane')));
    await tester.pumpAndSettle();
  }
  if (hideAll) {
    for (final label in ['INFO', 'ERROR', 'WARN']) {
      await tester.tap(find.byKey(Key('timeline-legend-$label')));
      await tester.pumpAndSettle();
    }
  }
  if (selectColumn != null) {
    final box = tester.getRect(find.byKey(const Key('timeline-plot')));
    final painter = tester
        .widget<CustomPaint>(find.byKey(const Key('timeline-paint')))
        .painter as TimelinePainter;
    final geo = painter.geometry;
    final slot = geo.slotFor(geo.columns[selectColumn], geo.plotIn(box.size));
    await tester.tapAt(Offset(box.left + slot.center.dx, box.top + slot.center.dy));
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
          find.byType(TimelineView),
          matchesGoldenFile('goldens/timeline_${theme.key}_ready.png'),
        );
      });

      testWidgets('no severity split', (tester) async {
        await _pumpChart(tester, brightness: theme.value, severityField: null);
        await expectLater(
          find.byType(TimelineView),
          matchesGoldenFile('goldens/timeline_${theme.key}_no_severity.png'),
        );
      });

      testWidgets('a bucket selected', (tester) async {
        await _pumpChart(tester, brightness: theme.value, selectColumn: 2);
        await expectLater(
          find.byType(TimelineView),
          matchesGoldenFile('goldens/timeline_${theme.key}_selected.png'),
        );
      });

      testWidgets('a lane hidden', (tester) async {
        await _pumpChart(tester, brightness: theme.value, hideLane: 'INFO');
        await expectLater(
          find.byType(TimelineView),
          matchesGoldenFile('goldens/timeline_${theme.key}_hidden_lane.png'),
        );
      });

      testWidgets('every lane hidden', (tester) async {
        await _pumpChart(tester, brightness: theme.value, hideAll: true);
        await expectLater(
          find.byType(TimelineView),
          matchesGoldenFile('goldens/timeline_${theme.key}_all_hidden.png'),
        );
      });

      testWidgets('dropped lanes warning', (tester) async {
        await _pumpChart(tester, brightness: theme.value, extraLanes: 5);
        await expectLater(
          find.byType(TimelineView),
          matchesGoldenFile('goldens/timeline_${theme.key}_partial_lanes.png'),
        );
      });

      testWidgets('empty', (tester) async {
        await _pumpChart(tester, brightness: theme.value, rows: []);
        await expectLater(
          find.byType(TimelineView),
          matchesGoldenFile('goldens/timeline_${theme.key}_empty.png'),
        );
      });

      testWidgets('failed', (tester) async {
        await _pumpChart(tester, brightness: theme.value, fail: true);
        await expectLater(
          find.byType(TimelineView),
          matchesGoldenFile('goldens/timeline_${theme.key}_failed.png'),
        );
      });

      testWidgets('at 1.3x text scale', (tester) async {
        await _pumpChart(tester, brightness: theme.value, textScale: 1.3);
        await expectLater(
          find.byType(TimelineView),
          matchesGoldenFile('goldens/timeline_${theme.key}_text_scale_130.png'),
        );
      });
    });
  }
}