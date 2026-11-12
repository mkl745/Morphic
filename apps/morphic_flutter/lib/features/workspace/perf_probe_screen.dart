import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../../engine/engine_controller.dart';
import '../../engine/perf_probe.dart';

/// Runs AT-07's workload on this device against this workspace and shows the honest verdict.
///
/// Reachable from the workspace app bar in every build, not just debug: the physical-device
/// harness installs a release APK, and a probe that only exists in debug could never produce
/// the evidence the milestone exit needs.
class PerfProbeScreen extends StatefulWidget {
  const PerfProbeScreen({super.key, required this.controller, this.probe = const PerfProbe()});

  final EngineController controller;
  final PerfProbe probe;

  @override
  State<PerfProbeScreen> createState() => _PerfProbeScreenState();
}

class _PerfProbeScreenState extends State<PerfProbeScreen> {
  bool _running = false;
  String _progress = '';
  PerfProbeResult? _result;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _result = null;
      _progress = 'Starting';
    });
    final result = await widget.probe.run(
      widget.controller,
      onProgress: (m) {
        if (mounted) setState(() => _progress = m);
      },
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
      _progress = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = widget.controller.profile;
    final rows = (profile?['rowCount'] as num?)?.toInt() ?? 0;
    final fields = (profile?['fieldCount'] as num?)?.toInt() ?? 0;
    final representative = rows >= kRepresentativeRows;

    return Scaffold(
      appBar: AppBar(title: const Text('Performance probe')),
      body: ListView(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(MorphicSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('This workspace', style: theme.textTheme.titleSmall),
                  const SizedBox(height: MorphicSpace.sm),
                  Text('$rows rows · $fields fields'),
                  const SizedBox(height: MorphicSpace.sm),
                  Text(
                    'Times a global filter + two-key sort + first page, '
                    '${PerfProbe.defaultIterations} times, each on a different selection so '
                    'the query cache cannot answer for the engine. The budget is '
                    '${kFilterSortBudgetMs.toStringAsFixed(0)} ms and the verdict uses the '
                    'worst run, not the average.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: MorphicSpace.sm),
                  Text(
                    'Your filters and sort are restored afterwards.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          if (!representative) ...[
            const SizedBox(height: MorphicSpace.md),
            Card(
              color: MorphicColors.warning.withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.all(MorphicSpace.lg),
                child: Text(
                  'AT-07 names a 100,000-row table. This workspace has $rows, so a run here '
                  'is a smoke test and will be reported as NOT AT-07 EVIDENCE. Import the '
                  'generated 100k × 10 CSV to measure the acceptance figure.',
                  key: const Key('perf-not-representative'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
          const SizedBox(height: MorphicSpace.md),
          FilledButton(
            key: const Key('perf-run'),
            onPressed: _running ? null : _run,
            child: Text(_running ? 'Measuring…' : 'Run probe'),
          ),
          if (_running) ...[
            const SizedBox(height: MorphicSpace.md),
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: MorphicSpace.sm),
                Text(_progress, style: theme.textTheme.bodySmall),
              ],
            ),
          ],
          if (_result != null) ...[
            const SizedBox(height: MorphicSpace.md),
            _ResultCard(result: _result!),
          ],
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final PerfProbeResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = !result.ran
        ? theme.colorScheme.error
        : !result.representative
            ? MorphicColors.warningText(theme.brightness)
            : result.passes
                ? MorphicColors.successText(theme.brightness)
                : theme.colorScheme.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.verdict,
              key: const Key('perf-verdict'),
              style: theme.textTheme.titleSmall?.copyWith(color: color),
            ),
            if (result.ran) ...[
              const SizedBox(height: MorphicSpace.sm),
              Text('Worst ${result.worstMs.toStringAsFixed(1)} ms · '
                  'median ${result.medianMs.toStringAsFixed(1)} ms · '
                  'p95 ${result.p95Ms.toStringAsFixed(1)} ms'),
              const SizedBox(height: MorphicSpace.sm),
              Text('Filter field: ${result.filterField} · '
                  'sort: ${result.sortFields.join(", ")}',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: MorphicSpace.sm),
              for (final s in result.samples)
                Text(
                  '${s.iteration + 1}. ${s.ms.toStringAsFixed(1)} ms '
                  '· ${s.matchedRows} matched',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }
}