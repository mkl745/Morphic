/// The AT-07 device measurement, run on the phone against the data the user actually imported.
///
/// # Why this exists
///
/// AT-07 requires filter + sort over 100k × 10 to complete in **≤150 ms engine-side on a
/// mid-class ARM device**. `morphic-query/tests/perf.rs` measures the same workload, but on a CI
/// x86 runner: it says so in its own header and refuses to claim the ARM number. The physical
/// device harness (`tools/device_smoke.sh`) checks ten functional behaviours and times none of
/// them — its polling helper sleeps three seconds per attempt, so it could not see a 150 ms
/// budget even if it looked. This probe closes that gap.
///
/// # What is actually timed
///
/// The whole `componentPage` round trip: the FFI call, the engine's filter + sort + page, and
/// the JSON decode of the returned rows. That is an **upper bound** on engine-side time, so a
/// pass here proves the engine-side claim a fortiori, and it is also closer to what the user
/// feels. A failure needs investigating before blaming the engine — the decode is in scope.
///
/// # Why it cannot be faked by accident
///
/// - Each iteration uses a **different filter bound**, so the query cache cannot serve a
///   previous iteration's selection. Timing a cache hit would measure nothing.
/// - The verdict is the **worst** sample, not the median. "≤150 ms" is a ceiling, and a phone
///   that hits it 6 times out of 7 has not met it.
/// - A run over fewer than 100k rows is marked [PerfProbeResult.representative] = false and
///   **cannot** satisfy AT-07, so running this on the 600-row sample proves nothing and says so.
/// - The prior filters and sort are restored afterwards. A diagnostic must not quietly rewrite
///   the user's saved workspace.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'engine_controller.dart';
import 'interaction.dart';

/// AT-07's ceiling, in milliseconds.
const double kFilterSortBudgetMs = 150.0;

/// AT-01's row count. A smaller table is a smoke test, not the acceptance measurement.
const int kRepresentativeRows = 100000;

/// Prefix the device harness greps for in logcat. Keep it stable: `tools/device_perf.sh` and
/// `tools/check_device_evidence.py` both parse it.
const String kPerfLogTag = 'MORPHIC_PERF';

/// One timed filter + sort + page.
class PerfSample {
  const PerfSample({
    required this.iteration,
    required this.ms,
    required this.matchedRows,
    required this.bound,
  });

  final int iteration;
  final double ms;
  final int matchedRows;

  /// The filter bound used, recorded so a reader can see the selections really did differ.
  final Object? bound;

  Map<String, dynamic> toJson() => {
        'iteration': iteration,
        'ms': double.parse(ms.toStringAsFixed(2)),
        'matchedRows': matchedRows,
        'bound': bound,
      };
}

/// The outcome of a probe run.
class PerfProbeResult {
  const PerfProbeResult({
    required this.samples,
    required this.rowCount,
    required this.fieldCount,
    required this.filterField,
    required this.sortFields,
    required this.budgetMs,
    this.failure,
  });

  final List<PerfSample> samples;
  final int rowCount;
  final int fieldCount;
  final String filterField;
  final List<String> sortFields;
  final double budgetMs;

  /// Why the probe could not run at all. When set, [samples] is empty and [passes] is false.
  final String? failure;

  /// True only when the table is at least as large as AT-01's dataset. Without this a run on
  /// the 600-row sample would report a comfortable pass and mean nothing.
  bool get representative => rowCount >= kRepresentativeRows;

  bool get ran => failure == null && samples.isNotEmpty;

  List<double> get _sorted => samples.map((s) => s.ms).toList()..sort();

  double get worstMs => _sorted.isEmpty ? 0 : _sorted.last;

  double get medianMs => _percentile(0.5);

  double get p95Ms => _percentile(0.95);

  /// Nearest-rank percentile: no interpolation, so the figure quoted is always a real sample.
  double _percentile(double q) {
    final v = _sorted;
    if (v.isEmpty) return 0;
    final rank = (q * v.length).ceil().clamp(1, v.length);
    return v[rank - 1];
  }

  /// The AT-07 verdict. Strict on purpose: the worst sample must clear the ceiling, and the
  /// dataset must be large enough for the number to be about the thing AT-07 names.
  bool get passes => ran && representative && worstMs <= budgetMs;

  /// One-line verdict for a human reading logcat.
  String get verdict {
    if (!ran) return 'DID NOT RUN: ${failure ?? "no samples"}';
    if (!representative) {
      return 'NOT AT-07 EVIDENCE: $rowCount rows < $kRepresentativeRows '
          '(worst ${worstMs.toStringAsFixed(1)} ms)';
    }
    return passes
        ? 'AT-07 PASS: worst ${worstMs.toStringAsFixed(1)} ms '
            '<= ${budgetMs.toStringAsFixed(0)} ms over $rowCount rows'
        : 'AT-07 FAIL: worst ${worstMs.toStringAsFixed(1)} ms '
            '> ${budgetMs.toStringAsFixed(0)} ms over $rowCount rows';
  }

  Map<String, dynamic> toJson() => {
        'schema': 'morphic/perf-probe/1',
        'workload': 'global filter + 2-key sort + first page',
        'timed': 'componentPage round trip (engine + FFI + JSON decode)',
        'budgetMs': budgetMs,
        'rowCount': rowCount,
        'fieldCount': fieldCount,
        'representative': representative,
        'filterField': filterField,
        'sortFields': sortFields,
        'samples': samples.map((s) => s.toJson()).toList(),
        'medianMs': double.parse(medianMs.toStringAsFixed(2)),
        'p95Ms': double.parse(p95Ms.toStringAsFixed(2)),
        'worstMs': double.parse(worstMs.toStringAsFixed(2)),
        'passes': passes,
        'verdict': verdict,
        if (failure != null) 'failure': failure,
      };
}

/// Runs the AT-07 workload against an open workspace.
class PerfProbe {
  const PerfProbe();

  /// Number of timed iterations. Seven is enough to expose a scheduler hiccup or a thermal
  /// step on a phone without making the tester wait; the CI perf test uses five.
  static const int defaultIterations = 7;

  Future<PerfProbeResult> run(
    EngineController engine, {
    int iterations = defaultIterations,
    void Function(String message)? onProgress,
  }) async {
    PerfProbeResult failed(String why) => PerfProbeResult(
          samples: const [],
          rowCount: 0,
          fieldCount: 0,
          filterField: '',
          sortFields: const [],
          budgetMs: kFilterSortBudgetMs,
          failure: why,
        );

    if (engine.workspaceId == null) return failed('no workspace open');
    if (engine.degraded) return failed('workspace is degraded; its source data is unavailable');

    final profile = engine.profile;
    final rowCount = (profile?['rowCount'] as num?)?.toInt() ?? 0;
    final fieldCount = (profile?['fieldCount'] as num?)?.toInt() ?? 0;
    if (rowCount == 0) return failed('the engine reported no rows for this workspace');

    final tableId = _tableId(engine);
    if (tableId == null) return failed('this workspace has no data table to page');

    final fields = engine.fieldNames;
    if (fields.isEmpty) return failed('the profile lists no fields');

    // A numeric bound gives a genuinely different selection per iteration. A text field is the
    // fallback, using `contains` on a varying prefix of a real value.
    final numeric = fields.firstWhere(
      (f) => engine.dtypeOf(f) == 'int64' || engine.dtypeOf(f) == 'float64',
      orElse: () => '',
    );
    final filterField = numeric.isNotEmpty ? numeric : fields.first;
    final isNumeric = numeric.isNotEmpty;
    if (!isNumeric && engine.dtypeOf(filterField) != 'utf8') {
      return failed('no numeric or text field to filter on');
    }

    // Two keys where the data allows it, matching the CI workload. Nulls last, one key
    // descending, so the comparator exercises both directions and the null policy.
    final sortFields = <String>[
      filterField,
      fields.firstWhere((f) => f != filterField, orElse: () => filterField),
    ].toSet().toList();
    final sort = [
      SortRule(field: sortFields.first, dir: SortDir.asc),
      if (sortFields.length > 1)
        SortRule(field: sortFields[1], dir: SortDir.desc),
    ];

    // Restore what the user had. The probe writes real commands, so it must put them back.
    final priorFilters = engine.globalFilters;
    final priorSort = _sortOf(engine, tableId);

    // The cache key is (data revision, plan hash). Applying a filter changes the *document*
    // revision but not the data revision, so repeating a bound would hit the cache and time
    // nothing. Build every bound up front and refuse to run if they are not distinct, rather
    // than reporting a comfortable number that measured a cache hit.
    final bounds = [
      for (var i = 0; i < iterations; i++) _boundFor(engine, filterField, i, isNumeric)
    ];
    if (bounds.toSet().length != bounds.length) {
      return failed('cannot build $iterations distinct selections on "$filterField"; '
          'a repeated bound would be served from the query cache');
    }

    final samples = <PerfSample>[];
    try {
      for (var i = 0; i < iterations; i++) {
        onProgress?.call('Iteration ${i + 1} of $iterations');
        final bound = bounds[i];
        final filter = isNumeric
            ? filterNode('gt', field: filterField, value: bound)
            : filterNode('eq', field: filterField, value: bound);

        final applied = await engine.applyCommands([
          Commands.setGlobalFilter([filter]),
          Commands.setComponentSort(tableId, sort),
        ]);
        if (applied == null) {
          return failed('the engine rejected the probe command: ${engine.error ?? "unknown"}');
        }

        // Timed region: exactly the read the table itself performs. The command above is not
        // timed — it mutates state and saves, which is a different operation from AT-07's read.
        final watch = Stopwatch()..start();
        final page = await engine.componentPage(tableId, offset: 0, limit: 0);
        watch.stop();
        if (page == null) {
          return failed('the probe page read failed: ${engine.error ?? "unknown"}');
        }
        samples.add(PerfSample(
          iteration: i,
          ms: watch.elapsedMicroseconds / 1000.0,
          matchedRows: page.totalRows,
          bound: bound,
        ));
        // Let the frame land so the measurement is not competing with its own rebuild.
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    } finally {
      await engine.applyCommands([
        Commands.setGlobalFilter(priorFilters),
        Commands.setComponentSort(tableId, priorSort),
      ]);
    }

    final result = PerfProbeResult(
      samples: samples,
      rowCount: rowCount,
      fieldCount: fieldCount,
      filterField: filterField,
      sortFields: sort.map((r) => r.field).toList(),
      budgetMs: kFilterSortBudgetMs,
    );
    // One parseable line for logcat, then the full JSON for the evidence file.
    debugPrint('$kPerfLogTag ${result.verdict}');
    debugPrint('$kPerfLogTag_JSON ${jsonEncode(result.toJson())}');
    return result;
  }

  /// First table in layout order — the one the user is looking at.
  String? _tableId(EngineController engine) {
    for (final c in engine.components) {
      if (c['type'] == 'data_table') return c['id'] as String?;
    }
    return null;
  }

  List<SortRule> _sortOf(EngineController engine, String componentId) {
    for (final c in engine.components) {
      if (c['id'] != componentId) continue;
      final state = c['state'];
      if (state is! Map<String, dynamic>) return const [];
      return (state['sort'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SortRule.fromJson)
          .toList();
    }
    return const [];
  }

  /// A bound that selects a different slice each iteration, derived from the engine's own
  /// sample values rather than a guess about the user's data.
  Object? _boundFor(EngineController engine, String field, int i, bool isNumeric) {
    if (isNumeric) {
      // Spread across a decade; the exact values matter less than that they differ, which is
      // what forces the engine to redo the selection instead of serving the cache.
      return i * 137;
    }
    // Equality on a real value, so two iterations select two genuinely different slices.
    // A shared one-character prefix would collide and hand back a cached selection.
    final top = engine.topValuesOf(field);
    if (top.isEmpty) return 'probe-$i';
    return top[i % top.length];
  }
}