/// Tests for the chart scene contract (M1.4 task 1.4.1).
///
/// Two things matter here. First, the Dart model must parse exactly what Rust sends — a field
/// silently defaulting to zero would draw a wrong chart with no error. Second, the partial-scene
/// notices must exist, because a painter that draws a truncated scene as complete is the
/// dishonest-reporting failure this project keeps refusing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/chart_scene.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';

import '../support/scripted_bridge.dart';

Map<String, dynamic> _bar() => {
      'id': 'breakdown_by_region',
      'type': 'bar_chart',
      'title': 'Average amount by region',
      'binding': {
        'kind': 'bar_chart',
        'dimension': 'region',
        'measure': {'op': 'avg', 'field': 'amount'},
        'limit': 2,
      },
      'interactions': {'filter': true},
    };

// us is 5, not 20, on purpose: it makes the remainder's true average (15) differ from the
// average of the group averages (12.5), so the Other test can actually tell them apart.
const _rows = [
  ['eu', 10],
  ['us', 5],
  ['eu', 30],
  ['latam', 60],
];

ScriptedBridge _bridge({int limit = 2}) {
  final bar = _bar();
  if (limit != 2) {
    (bar['binding'] as Map<String, dynamic>)['limit'] = limit;
  }
  return ScriptedBridge(
    rows: List.of(_rows),
    fields: const ['region', 'amount'],
    dtypes: const {'amount': 'int64'},
    components: [bar],
    order: const ['breakdown_by_region'],
  );
}

Future<EngineController> _open(ScriptedBridge bridge) async {
  final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await engine.open('w1');
  return engine;
}

void main() {
  group('parsing', () {
    test('a category scene round-trips every field', () {
      final scene = ChartScene.fromJson({
        'kind': 'category',
        'dimension': 'region',
        'measure': 'avg_amount',
        'points': [
          {'label': 'us', 'value': 30.0, 'rowCount': 2},
          {'label': null, 'value': null, 'rowCount': 1},
        ],
        'other': {'label': 'Other', 'value': 16.5, 'rowCount': 4},
        'totalCategories': 7,
        'truncated': true,
      });
      expect(scene, isA<CategoryScene>());
      final c = scene as CategoryScene;
      expect(c.dimension, 'region');
      expect(c.measure, 'avg_amount');
      expect(c.points.length, 2);
      expect(c.points[0].label, 'us');
      expect(c.points[0].value, 30.0);
      expect(c.points[0].rowCount, 2);
      expect(c.other?.value, 16.5);
      expect(c.other?.rowCount, 4);
      expect(c.totalCategories, 7);
      expect(c.hiddenCategories, 5);
      expect(c.truncated, isTrue);
    });

    test('a null label stays null and is not coerced to an empty string', () {
      // The null category is a real group. Rendering it as "" would merge it with a genuine
      // empty-string category, which is a different thing.
      final c = ChartScene.fromJson({
        'kind': 'category',
        'points': [
          {'label': null, 'value': 5.0, 'rowCount': 1},
        ],
      }) as CategoryScene;
      expect(c.points.single.label, isNull);
      expect(c.points.single.value, 5.0);
    });

    test('a null value stays null rather than becoming zero', () {
      // An undefined measure must draw as an absent bar, not a zero-height one.
      final c = ChartScene.fromJson({
        'kind': 'category',
        'points': [
          {'label': 'eu', 'value': null, 'rowCount': 3},
        ],
      }) as CategoryScene;
      expect(c.points.single.value, isNull);
      expect(c.points.single.rowCount, 3);
    });

    test('an int-valued measure parses as a double', () {
      // Rust sends 30.0, but a count arrives as an integer in JSON. Both must work.
      final c = ChartScene.fromJson({
        'kind': 'category',
        'points': [
          {'label': 'eu', 'value': 3, 'rowCount': 3},
        ],
      }) as CategoryScene;
      expect(c.points.single.value, 3.0);
    });

    test('a series scene parses bucketing and gaps', () {
      final s = ChartScene.fromJson({
        'kind': 'series',
        'xField': 'ts',
        'temporal': true,
        'bucketing': {'bucketMs': 1800000, 'label': '30m', 'downsampled': false},
        'series': [
          {
            'name': 'eu',
            'points': [
              {'x': 0, 'y': 1.5},
              {'x': 1800000, 'y': null},
            ],
          },
        ],
        'totalSeries': 5,
        'truncatedSeries': false,
        'totalPoints': 2,
      }) as SeriesScene;
      expect(s.temporal, isTrue);
      expect(s.bucketing.label, '30m');
      expect(s.bucketing.bucketMs, 1800000);
      expect(s.series.single.name, 'eu');
      expect(s.series.single.points[1].y, isNull, reason: 'a gap, not a zero');
      expect(s.totalSeries, 5);
      expect(s.hiddenSeries, 4);
    });

    test('a timeline scene parses lanes and undated rows', () {
      final t = ChartScene.fromJson({
        'kind': 'timeline',
        'timeField': 'time',
        'bucketing': {'bucketMs': 60000, 'label': '1m', 'downsampled': true},
        'lanes': ['ERROR', 'WARN', null],
        'buckets': [
          {
            'startMs': 0,
            'count': 3,
            'lanes': [
              {'lane': 'ERROR', 'count': 2},
              {'lane': null, 'count': 1},
            ],
          },
        ],
        'totalBuckets': 1,
        'totalLanes': 3,
        'truncatedLanes': false,
        'unbucketedRows': 4,
      }) as TimelineScene;
      expect(t.lanes, ['ERROR', 'WARN', null]);
      expect(t.buckets.single.count, 3);
      expect(t.buckets.single.lanes.last.lane, isNull);
      expect(t.unbucketedRows, 4);
    });

    test('an unknown kind throws instead of drawing an empty chart', () {
      expect(
        () => ChartScene.fromJson({'kind': 'pie_chart'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ChartScene.fromJson({}),
        throwsA(isA<FormatException>()),
      );
    });

    test('the envelope carries the revision that produced the scene', () {
      final r = ChartResult.fromJson({
        'componentId': 'breakdown_by_region',
        'revision': 9,
        'scene': {'kind': 'category', 'points': <Map<String, dynamic>>[]},
      });
      expect(r.componentId, 'breakdown_by_region');
      expect(r.revision, 9);
    });

    test('hidden counts never go negative when totals are absent', () {
      final c = ChartScene.fromJson({
        'kind': 'category',
        'points': [
          {'label': 'eu', 'value': 1, 'rowCount': 1},
        ],
      }) as CategoryScene;
      expect(c.hiddenCategories, 0);
    });
  });

  group('partial-scene notices', () {
    test('a complete scene has nothing to report', () {
      const c = CategoryScene(
        dimension: 'region',
        measure: 'count',
        points: [],
        other: null,
        totalCategories: 0,
        truncated: false,
      );
      expect(c.isPartial, isFalse);
      expect(c.partialNotice, isNull);
    });

    test('a truncated category scene says the ranking is unreliable', () {
      const c = CategoryScene(
        dimension: 'region',
        measure: 'count',
        points: [],
        other: null,
        totalCategories: 200000,
        truncated: true,
      );
      expect(c.isPartial, isTrue);
      expect(c.partialNotice, contains('prefix'));
    });

    test('dropped series are counted, never summed into a fabricated Other', () {
      final s = ChartScene.fromJson({
        'kind': 'series',
        'bucketing': {'label': '1h'},
        'series': [
          {'name': 'a', 'points': <Map<String, dynamic>>[]},
          {'name': 'b', 'points': <Map<String, dynamic>>[]},
        ],
        'totalSeries': 9,
        'truncatedSeries': true,
      }) as SeriesScene;
      expect(s.isPartial, isTrue);
      expect(s.partialNotice, 'Showing 2 of 9 series; 7 not drawn.');
      expect(s.series.length, 2, reason: 'no fabricated ninth series');
    });

    test('merged buckets are reported with their resulting step', () {
      final s = ChartScene.fromJson({
        'kind': 'series',
        'bucketing': {'label': '2h', 'downsampled': true},
        'series': <Map<String, dynamic>>[],
        'truncatedSeries': false,
      }) as SeriesScene;
      expect(s.isPartial, isTrue);
      expect(s.partialNotice, contains('2h'));
      expect(s.partialNotice, contains('merged'));
    });

    test('undated rows are surfaced even when nothing was truncated', () {
      final t = ChartScene.fromJson({
        'kind': 'timeline',
        'bucketing': {'label': '1m'},
        'lanes': <String>[],
        'buckets': <Map<String, dynamic>>[],
        'truncatedLanes': false,
        'unbucketedRows': 12,
      }) as TimelineScene;
      expect(t.isPartial, isTrue);
      expect(t.partialNotice, '12 undated rows not placed.');
    });

    test('a timeline reports both problems when it has both', () {
      final t = ChartScene.fromJson({
        'kind': 'timeline',
        'bucketing': {'label': '1m'},
        'lanes': ['a'],
        'totalLanes': 6,
        'truncatedLanes': true,
        'unbucketedRows': 3,
      }) as TimelineScene;
      expect(t.partialNotice, 'Showing 1 of 6 lanes; 3 undated rows not placed.');
    });
  });

  group('through the controller', () {
    test('a chart read asks the engine and returns a scene, not rows', () async {
      final bridge = _bridge(limit: 3);
      final engine = await _open(bridge);
      final r = await engine.chartData('breakdown_by_region');
      expect(bridge.chartCalls, ['breakdown_by_region']);
      expect(r, isNotNull);
      expect(r!.revision, engine.revision);
      final c = r.scene as CategoryScene;
      expect(c.dimension, 'region');
      expect(c.measure, 'avg_amount');
      // latam 60, eu (10+30)/2 = 20, us 5 -> descending by measure.
      expect(c.points.first.label, 'latam');
      expect(c.points.first.value, 60.0);
      expect(c.points.length, 3);
      expect(c.other, isNull);
    });

    test('a workspace filter moves the bars', () async {
      final bridge = _bridge(limit: 3);
      final engine = await _open(bridge);
      await engine.chartData('breakdown_by_region');
      await engine.applyCommands([
        Commands.setGlobalFilter([
          filterNode('eq', field: 'region', value: 'eu'),
        ]),
      ]);
      final r = await engine.chartData('breakdown_by_region');
      final c = r!.scene as CategoryScene;
      expect(c.totalCategories, 1);
      expect(c.points.single.label, 'eu');
      expect(c.points.single.value, 20.0);
      expect(c.points.single.rowCount, 2);
      expect(r.revision, engine.revision);
    });

    test('the Other bucket is re-aggregated, not subtracted', () async {
      // limit 1 keeps latam (60). The remainder is eu 10, us 5, eu 30: the true average is
      // 45/3 = 15, while averaging the two group averages (eu 20, us 5) would give 12.5. The
      // distinction is the whole point — an average of averages is not an average.
      final engine = await _open(_bridge(limit: 1));
      final c = (await engine.chartData('breakdown_by_region'))!.scene as CategoryScene;
      expect(c.points.length, 1);
      expect(c.points.single.label, 'latam');
      expect(c.other, isNotNull);
      expect(c.other!.label, 'Other');
      expect(c.other!.rowCount, 3);
      expect(c.other!.value, 15.0);
      expect(c.other!.value, isNot(12.5), reason: 'not an average of group averages');
      expect(c.hiddenCategories, 2);
    });

    test('a failing chart read sets error and returns null', () async {
      final bridge = _bridge();
      final engine = await _open(bridge);
      bridge.failChart = true;
      final r = await engine.chartData('breakdown_by_region');
      expect(r, isNull);
      expect(engine.error, contains('not a chart'));
    });

    test('a degraded workspace reports the engine error rather than an empty scene', () async {
      final bridge = _bridge()..sourceUnavailable = true;
      final engine = await _open(bridge);
      final r = await engine.chartData('breakdown_by_region');
      expect(r, isNull);
      expect(engine.error, contains('source data'));
    });

    test('with no workspace open it fails quietly instead of throwing', () async {
      final engine = EngineController(bridge: _bridge(), storageRoot: '/tmp/m');
      expect(await engine.chartData('breakdown_by_region'), isNull);
      expect(engine.error, 'no workspace open');
    });
  });
}