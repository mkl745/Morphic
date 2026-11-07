/// Tests for the AT-07 device probe.
///
/// The probe's own correctness matters more than usual: it is the instrument that will decide
/// whether M1.3's exit is met. An instrument that reports a comfortable number for the wrong
/// reason is worse than no instrument, so these tests attack the ways it could lie — a cached
/// selection, an average hiding a slow tail, a small table impersonating a 100k one, and a
/// diagnostic that quietly rewrites the user's workspace.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/engine_controller.dart';
import 'package:morphic_flutter/engine/interaction.dart';
import 'package:morphic_flutter/engine/perf_probe.dart';

import '../support/scripted_bridge.dart';

/// Reports a 100k-row profile while serving a handful of rows.
///
/// The probe reads the row count from the engine's profile, which is exactly what a tester
/// could get wrong; this lets a test drive both sides of the representativeness gate without
/// allocating a 100k-row fake.
class _ProfileBridge extends ScriptedBridge {
  _ProfileBridge({
    required this.reportedRows,
    super.rows,
    super.dtypes,
    super.topValues,
    super.components,
    super.order,
    super.degraded,
  });

  final int reportedRows;

  @override
  Map<String, dynamic> profileJson() => {
        ...super.profileJson(),
        'rowCount': reportedRows,
      };
}

Map<String, dynamic> _table() => {
      'id': 'data_table',
      'type': 'data_table',
      'title': 'Data',
      'binding': {
        'kind': 'data_table',
        'columns': <String>[],
        'page_size': 256,
      },
      'interactions': {'search': true, 'sort': true, 'filter': true},
    };

const _rows = [
  ['eu', 10, null],
  ['us', 20, 'alpha'],
  ['eu', 30, 'beta'],
  ['latam', 40, null],
];

Future<EngineController> _open(ScriptedBridge bridge) async {
  final engine = EngineController(bridge: bridge, storageRoot: '/tmp/m');
  await engine.open('w1');
  return engine;
}

PerfSample _s(int i, double ms) =>
    PerfSample(iteration: i, ms: ms, matchedRows: 1000, bound: i);

PerfProbeResult _result(
  List<double> ms, {
  int rows = kRepresentativeRows,
  String? failure,
}) =>
    PerfProbeResult(
      samples: [for (var i = 0; i < ms.length; i++) _s(i, ms[i])],
      rowCount: rows,
      fieldCount: 10,
      filterField: 'amount',
      sortFields: const ['amount', 'region'],
      budgetMs: kFilterSortBudgetMs,
      failure: failure,
    );

void main() {
  group('verdict', () {
    test('the worst sample decides, not the median', () {
      // Six comfortable runs and one 400 ms stall is a phone that does not meet a 150 ms
      // ceiling. An instrument reporting the median here would certify it.
      final r = _result([40, 42, 41, 43, 40, 42, 400]);
      expect(r.medianMs, 42);
      expect(r.worstMs, 400);
      expect(r.passes, isFalse);
      expect(r.verdict, contains('AT-07 FAIL'));
    });

    test('every sample under the ceiling passes', () {
      final r = _result([40, 62, 88, 149.9]);
      expect(r.passes, isTrue);
      expect(r.verdict, contains('AT-07 PASS'));
    });

    test('the ceiling is inclusive', () {
      expect(_result([150]).passes, isTrue);
      expect(_result([150.1]).passes, isFalse);
    });

    test('percentiles are nearest-rank, so every figure quoted is a real sample', () {
      final r = _result([10, 20, 30, 40, 100]);
      expect(r.medianMs, 30);
      // ceil(0.95 * 5) = 5 -> the largest sample, not an interpolation toward it.
      expect(r.p95Ms, 100);
      expect(r.worstMs, 100);
    });

    test('a single sample is its own median and p95', () {
      final r = _result([77]);
      expect(r.medianMs, 77);
      expect(r.p95Ms, 77);
    });
  });

  group('representativeness gate', () {
    test('a fast run on a small table is not AT-07 evidence', () {
      // The 600-row device sample would sail under 150 ms and mean nothing.
      final r = _result([1, 2, 3], rows: 600);
      expect(r.ran, isTrue);
      expect(r.representative, isFalse);
      expect(r.passes, isFalse);
      expect(r.verdict, contains('NOT AT-07 EVIDENCE'));
      expect(r.verdict, contains('600'));
    });

    test('exactly 100k rows is representative', () {
      expect(_result([10], rows: kRepresentativeRows).representative, isTrue);
      expect(_result([10], rows: kRepresentativeRows - 1).representative, isFalse);
    });

    test('a run that never happened cannot pass', () {
      final r = _result([], failure: 'no workspace open');
      expect(r.ran, isFalse);
      expect(r.passes, isFalse);
      expect(r.verdict, contains('DID NOT RUN'));
      expect(r.toJson()['failure'], 'no workspace open');
    });
  });

  group('refusals', () {
    test('no workspace open', () async {
      final engine = EngineController(
        bridge: ScriptedBridge(rows: List.of(_rows)),
        storageRoot: '/tmp/m',
      );
      final r = await const PerfProbe().run(engine);
      expect(r.failure, 'no workspace open');
      expect(r.passes, isFalse);
    });

    test('a degraded workspace has no data to measure', () async {
      final engine = await _open(_ProfileBridge(
        reportedRows: kRepresentativeRows,
        rows: List.of(_rows),
        components: [_table()],
        order: const ['data_table'],
        degraded: true,
      ));
      final r = await const PerfProbe().run(engine);
      expect(r.failure, contains('degraded'));
    });

    test('a workspace with no table cannot be paged', () async {
      final engine = await _open(_ProfileBridge(
        reportedRows: kRepresentativeRows,
        rows: List.of(_rows),
        components: [],
      ));
      final r = await const PerfProbe().run(engine);
      expect(r.failure, contains('no data table'));
    });
  });

  group('workload', () {
    test('each iteration filters on a different bound, so the cache cannot answer', () async {
      final bridge = _ProfileBridge(
        reportedRows: kRepresentativeRows,
        rows: List.of(_rows),
        dtypes: const {'amount': 'int64'},
        components: [_table()],
        order: const ['data_table'],
      );
      final engine = await _open(bridge);
      final r = await const PerfProbe().run(engine, iterations: 5);

      expect(r.ran, isTrue, reason: r.failure ?? '');
      expect(r.samples.length, 5);
      // The bound actually sent to the engine, not the one the probe meant to send.
      final bounds = bridge.commandBatches
          .expand((b) => b)
          .where((c) => c['kind'] == 'setGlobalFilter')
          .expand((c) => (c['filters'] as List))
          .map((f) => (f as Map)['value'])
          .toList();
      expect(bounds.take(5).toSet().length, 5,
          reason: 'a repeated bound would be served from the query cache');
      expect(r.samples.map((s) => s.bound).toSet().length, 5);
    });

    test('refuses rather than timing a cache hit when bounds cannot differ', () async {
      // One text value means every iteration would send the same plan. Reporting a fast
      // number here would be measuring the cache, so the probe must decline instead.
      final bridge = _ProfileBridge(
        reportedRows: kRepresentativeRows,
        rows: List.of(_rows),
        dtypes: const {'region': 'utf8', 'amount': 'utf8', 'note': 'utf8'},
        topValues: const {
          'region': ['eu'],
          'amount': ['x'],
          'note': ['y'],
        },
        components: [_table()],
        order: const ['data_table'],
      );
      final engine = await _open(bridge);
      final r = await const PerfProbe().run(engine, iterations: 4);
      expect(r.ran, isFalse);
      expect(r.failure, contains('distinct selections'));
      expect(r.failure, contains('cache'));
    });

    test('restores the filters and sort the user had', () async {
      final bridge = _ProfileBridge(
        reportedRows: kRepresentativeRows,
        rows: List.of(_rows),
        dtypes: const {'amount': 'int64'},
        components: [_table()],
        order: const ['data_table'],
      );
      final engine = await _open(bridge);
      await engine.applyCommands([
        Commands.setGlobalFilter([
          filterNode('eq', field: 'region', value: 'eu'),
        ]),
        Commands.setComponentSort('data_table', [
          const SortRule(field: 'region', dir: SortDir.desc),
        ]),
      ]);
      final before = engine.globalFilters;

      await const PerfProbe().run(engine, iterations: 3);

      expect(engine.globalFilters, before,
          reason: 'a diagnostic must not rewrite the workspace it measured');
      final table = engine.components.firstWhere((c) => c['id'] == 'data_table');
      final sort = ((table['state'] as Map?)?['sort'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SortRule.fromJson)
          .toList();
      expect(sort, [const SortRule(field: 'region', dir: SortDir.desc)]);
    });

    test('a rejected command aborts the run instead of reporting a partial result', () async {
      final bridge = _ProfileBridge(
        reportedRows: kRepresentativeRows,
        rows: List.of(_rows),
        dtypes: const {'amount': 'int64'},
        components: [_table()],
        order: const ['data_table'],
      );
      final engine = await _open(bridge);
      bridge.failCommands = true;
      final r = await const PerfProbe().run(engine, iterations: 3);
      expect(r.ran, isFalse);
      expect(r.failure, contains('rejected'));
    });

    test('reports progress once per iteration', () async {
      final engine = await _open(_ProfileBridge(
        reportedRows: kRepresentativeRows,
        rows: List.of(_rows),
        dtypes: const {'amount': 'int64'},
        components: [_table()],
        order: const ['data_table'],
      ));
      final messages = <String>[];
      await const PerfProbe().run(engine, iterations: 3, onProgress: messages.add);
      expect(messages, ['Iteration 1 of 3', 'Iteration 2 of 3', 'Iteration 3 of 3']);
    });

    test('the JSON carries enough to audit the claim', () async {
      final engine = await _open(_ProfileBridge(
        reportedRows: kRepresentativeRows,
        rows: List.of(_rows),
        dtypes: const {'amount': 'int64'},
        components: [_table()],
        order: const ['data_table'],
      ));
      final json = (await const PerfProbe().run(engine, iterations: 2)).toJson();
      expect(json['schema'], 'morphic/perf-probe/1');
      expect(json['rowCount'], kRepresentativeRows);
      expect(json['representative'], isTrue);
      expect(json['budgetMs'], kFilterSortBudgetMs);
      expect(json['timed'], contains('JSON decode'));
      expect((json['samples'] as List).length, 2);
      expect(json['worstMs'], isA<num>());
    });
  });
}
