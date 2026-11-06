/// `metric_card` renderer (M1.1 task 1.1.5).
///
/// The number is computed by Rust (`metricData` resolves the binding). This widget only
/// formats it and states honestly which of loading / error / no-data / value it is showing.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../component_registry.dart';
import '../value_format.dart';

class MetricCardView extends StatefulWidget {
  const MetricCardView({super.key, required this.ctx});

  final ComponentContext ctx;

  @override
  State<MetricCardView> createState() => _MetricCardViewState();
}

enum _Load { pending, ready, failed }

class _MetricCardViewState extends State<MetricCardView> {
  _Load _state = _Load.pending;
  Object? _value;
  String? _error;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(MetricCardView old) {
    super.didUpdateWidget(old);
    if (old.ctx.id != widget.ctx.id ||
        old.ctx.engine.revision != widget.ctx.engine.revision) {
      _fetch();
    }
  }

  Future<void> _fetch() async {
    final attempt = ++_attempt;
    setState(() {
      _state = _Load.pending;
      _error = null;
    });
    try {
      final v = await widget.ctx.engine.metric(widget.ctx.id);
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _value = v;
        _state = _Load.ready;
      });
    } catch (e) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _error = e.toString();
        _state = _Load.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = aggregationLabel(
        widget.ctx.binding['aggregation'] as Map<String, dynamic>?);
    final detail = widget.ctx.explanation['detail'] as String?;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.ctx.title, style: theme.textTheme.titleSmall),
            const SizedBox(height: MorphicSpace.sm),
            _body(theme),
            if (label.isNotEmpty) ...[
              const SizedBox(height: MorphicSpace.xs),
              Text(label, style: theme.textTheme.labelSmall),
            ],
            if (detail != null && detail.isNotEmpty) ...[
              const SizedBox(height: MorphicSpace.sm),
              // Clamped so several metrics plus chart placeholders cannot push the data
              // table off a phone screen. The full rationale stays one long-press away.
              Tooltip(
                message: detail,
                child: Text(
                  detail,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    switch (_state) {
      case _Load.pending:
        return const SizedBox(
          height: 34,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      case _Load.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Could not compute this metric',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: MorphicColors.error),
            ),
            if (_error != null)
              Text(_error!, style: theme.textTheme.bodySmall),
            TextButton(onPressed: _fetch, child: const Text('Retry')),
          ],
        );
      case _Load.ready:
        final isNull = _value == null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatCell(_value),
              style: theme.textTheme.headlineMedium,
              // A null aggregate means "no data", which is not the number zero.
              semanticsLabel: isNull ? 'No data' : formatCell(_value),
            ),
            if (isNull)
              Text(
                'No data for this metric',
                style: theme.textTheme.bodySmall,
              ),
          ],
        );
    }
  }
}
