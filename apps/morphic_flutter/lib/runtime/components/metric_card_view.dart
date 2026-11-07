/// `metric_card` renderer (M1.1 task 1.1.5; tap-to-filter M1.3 task 1.3.4).
///
/// The number is computed by Rust (`metricData` resolves the binding). This widget only
/// formats it and states honestly which of loading / error / no-data / value it is showing.
///
/// A filterable card is also a control. If its binding declares a filter, tapping the card
/// toggles *that predicate* in the workspace's global set — so "Errors" narrows the whole
/// workspace to errors, and tapping again restores it. A card with no binding filter has no
/// predicate of its own to toggle, so its tap opens the workspace filter menu instead.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../../engine/interaction.dart';
import '../component_registry.dart';
import '../global_filter_bar.dart';
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
  bool _busy = false;
  String? _filterError;

  /// The revision this card last rendered. `old.ctx.engine` and `widget.ctx.engine` are the
  /// same controller, so comparing their revisions can never differ — without remembering
  /// the value here, a global filter change would leave every card showing a stale number.
  int _seenRevision = -1;

  @override
  void initState() {
    super.initState();
    _seenRevision = widget.ctx.engine.revision;
    _fetch();
  }

  @override
  void didUpdateWidget(MetricCardView old) {
    super.didUpdateWidget(old);
    final revision = widget.ctx.engine.revision;
    if (old.ctx.id != widget.ctx.id || revision != _seenRevision) {
      _seenRevision = revision;
      _fetch();
    }
  }

  /// The predicate this card is *about*, if its binding declares one.
  Map<String, dynamic>? get _ownFilter {
    final agg = widget.ctx.binding['aggregation'] as Map<String, dynamic>?;
    final f = agg?['filter'];
    return f is Map<String, dynamic> ? f : null;
  }

  bool get _active {
    final own = _ownFilter;
    return own != null && indexOfFilter(widget.ctx.engine.globalFilters, own) >= 0;
  }

  Future<void> _send(List<Map<String, dynamic>> next) async {
    setState(() {
      _busy = true;
      _filterError = null;
    });
    final affected =
        await widget.ctx.engine.applyCommands([Commands.setGlobalFilter(next)]);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _filterError = affected == null ? widget.ctx.engine.error : null;
    });
    if (affected != null) {
      _seenRevision = widget.ctx.engine.revision;
      await _fetch();
    }
  }

  Future<void> _onTap() async {
    if (_busy) return;
    final engine = widget.ctx.engine;
    final own = _ownFilter;
    if (own != null) {
      await _send(toggledFilters(engine.globalFilters, own));
      return;
    }
    final choice = await showWorkspaceFilterMenu(context, engine);
    if (choice == null || !mounted || choice.cleared || choice.filter == null) return;
    await _send([...engine.globalFilters, choice.filter!]);
  }

  Future<void> _fetch() async {
    final attempt = ++_attempt;
    // See DataTableView: a value computed for an old selection must not be painted next to
    // a component already showing the new one (task 1.3.5).
    final revision = widget.ctx.engine.revision;
    setState(() {
      _state = _Load.pending;
      _error = null;
    });
    try {
      final v = await widget.ctx.engine.metric(widget.ctx.id);
      if (!mounted || attempt != _attempt) return;
      if (revision != widget.ctx.engine.revision) {
        _fetch();
        return;
      }
      setState(() {
        _value = v;
        _state = _Load.ready;
      });
    } catch (e) {
      if (!mounted || attempt != _attempt) return;
      // A failure for a superseded selection is not this workspace's answer either.
      if (revision != widget.ctx.engine.revision) {
        _fetch();
        return;
      }
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
    final tappable = widget.ctx.canFilter;
    final active = _active;
    final own = _ownFilter;
    final scheme = theme.colorScheme;

    final content = Padding(
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
          if (tappable) ...[
            const SizedBox(height: MorphicSpace.sm),
            Row(
              children: [
                Icon(
                  active ? Icons.filter_alt : Icons.filter_alt_outlined,
                  size: 14,
                  color: active ? scheme.onSecondaryContainer : theme.hintColor,
                ),
                const SizedBox(width: MorphicSpace.xs),
                Expanded(
                  child: Text(
                    active
                        ? 'Filtering the workspace — tap to clear'
                        : (own != null ? 'Tap to filter the workspace' : 'Tap to add a filter'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: active ? scheme.onSecondaryContainer : theme.hintColor,
                    ),
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ],
          if (_filterError != null)
            Padding(
              padding: const EdgeInsets.only(top: MorphicSpace.xs),
              child: Text(
                _filterError!,
                style: theme.textTheme.labelSmall?.copyWith(color: MorphicColors.error),
              ),
            ),
        ],
      ),
    );

    return Card(
      key: Key('metric-${widget.ctx.id}'),
      color: active ? scheme.secondaryContainer : null,
      child: tappable
          ? InkWell(
              key: Key('metric-tap-${widget.ctx.id}'),
              onTap: _busy ? null : _onTap,
              child: content,
            )
          : content,
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
