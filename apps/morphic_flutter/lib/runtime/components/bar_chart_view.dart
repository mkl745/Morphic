/// `bar_chart` renderer (M1.4 task 1.4.2).
///
/// Draws the [CategoryScene] Rust returns. It does not group, total or rank anything: the bars,
/// their order and the `Other` remainder all come from the engine, and the sort toggle is a
/// persisted command rather than a local reordering — the same invariant the table holds.
///
/// # Interactions (docs/architecture/04 §2)
///
/// - **Tap a bar** toggles `dimension = label` in the workspace's global filter set, so the
///     table and every other component move with it. Tapping again restores.
/// - **Tap the null bar** toggles `is_null(dimension)`, because "no region" is a real group and
///     filtering it must not silently mean `= ''`.
/// - **Tap Other** toggles `not(in(dimension, kept labels))` — exactly the rows the engine
///     aggregated into that bucket, not a guess at them.
/// - **Sort toggle** switches between largest-first and label order via `setComponentSort`.
///
/// # Accessibility contract (docs/design/design-system.md §9)
///
/// Every bar is a ≥48 dp target with its own semantics node, the chart carries a spoken
/// summary, and "View as table" is always available: a chart is never the only way to reach
/// its numbers.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../../engine/chart_scene.dart';
import '../../engine/interaction.dart';
import '../component_registry.dart';
import 'bar_chart_painter.dart';

class BarChartView extends StatefulWidget {
  const BarChartView({super.key, required this.ctx});

  final ComponentContext ctx;

  @override
  State<BarChartView> createState() => _BarChartViewState();
}

enum _Load { pending, ready, failed }

class _BarChartViewState extends State<BarChartView> {
  _Load _state = _Load.pending;
  ChartResult? _result;
  String? _error;
  String? _commandError;
  int _attempt = 0;
  bool _busy = false;

  /// The revision this chart last rendered. Both contexts hold one controller, so comparing
  /// `old.ctx.engine.revision` to the current one can never differ (task 1.3.5).
  int _seenRevision = -1;

  @override
  void initState() {
    super.initState();
    _seenRevision = widget.ctx.engine.revision;
    _fetch();
  }

  @override
  void didUpdateWidget(BarChartView old) {
    super.didUpdateWidget(old);
    if (_seenRevision != widget.ctx.engine.revision) {
      _seenRevision = widget.ctx.engine.revision;
      _fetch();
    }
  }

  Future<void> _fetch() async {
    final attempt = ++_attempt;
    final revision = widget.ctx.engine.revision;
    setState(() {
      _state = _Load.pending;
      _error = null;
    });
    final result = await widget.ctx.engine.chartData(widget.ctx.id);
    if (!mounted || attempt != _attempt) return;
    // A response computed for a revision the document has left is not this chart's answer.
    if (revision != widget.ctx.engine.revision) {
      _fetch();
      return;
    }
    setState(() {
      if (result == null) {
        _state = _Load.failed;
        _error = widget.ctx.engine.error ?? 'The engine could not build this chart.';
      } else {
        _state = _Load.ready;
        _result = result;
      }
    });
  }

  CategoryScene? get _scene {
    final s = _result?.scene;
    return s is CategoryScene ? s : null;
  }

  String get _dimension => _scene?.dimension ?? '';

  /// True when the persisted sort orders by the dimension, i.e. by label.
  bool get _byLabel {
    final sort = widget.ctx.state.sort;
    return sort.isNotEmpty && sort.first.field == _dimension;
  }

  Future<void> _send(List<Map<String, dynamic>> commands) async {
    setState(() {
      _busy = true;
      _commandError = null;
    });
    final affected = await widget.ctx.engine.applyCommands(commands);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _commandError = affected == null ? widget.ctx.engine.error : null;
    });
    if (affected != null) {
      _seenRevision = widget.ctx.engine.revision;
      await _fetch();
    }
  }

  /// The predicate a bar stands for. Null category and the remainder need their own shapes.
  Map<String, dynamic> _filterFor(BarDatum bar) {
    if (bar.isOther) {
      final kept = [
        for (final b in _bars)
          if (!b.isOther && !b.isNullCategory) b.label,
      ];
      // `in` is false against a null, so `not(in(...))` includes the null group — which is
      // correct here. Selection sorts nulls last, so a remainder only exists when the null
      // category was itself cut; it is part of Other and must come back with it.
      return filterNode('not', args: [
        filterNode('in', field: _dimension, value: kept),
      ]);
    }
    if (bar.isNullCategory) {
      return filterNode('is_null', field: _dimension);
    }
    return filterNode('eq', field: _dimension, value: bar.label);
  }

  Future<void> _tapBar(BarDatum bar) async {
    if (!widget.ctx.canFilter || _busy) return;
    final next = toggledFilters(widget.ctx.engine.globalFilters, _filterFor(bar));
    await _send([Commands.setGlobalFilter(next)]);
  }

  Future<void> _toggleSort() async {
    if (!widget.ctx.canSort || _busy) return;
    // Clearing the sort returns to the engine's default (largest first), so the toggle has
    // two honest states rather than three with a hidden one.
    final next = _byLabel
        ? const <SortRule>[]
        : [SortRule(field: _dimension, dir: SortDir.asc)];
    await _send([Commands.setComponentSort(widget.ctx.id, next)]);
  }

  /// The scene's bars, plus the remainder.
  ///
  /// Memoised on scene identity and the active filter set. Rebuilding this list on every
  /// ancestor rebuild would hand the painter a new list each time and defeat its
  /// `identical(old.bars, bars)` check, repainting the chart for reasons unrelated to its data.
  ChartResult? _barsResult;
  String _barsFilterKey = '';
  List<BarDatum> _barsCached = const [];

  List<BarDatum> get _bars {
    final scene = _scene;
    if (scene == null) return const [];
    final active = widget.ctx.engine.globalFilters;
    final key = active.map(filterKey).join('|');
    if (identical(_barsResult, _result) && key == _barsFilterKey) return _barsCached;
    _barsResult = _result;
    _barsFilterKey = key;
    BarDatum toDatum(CategoryPoint p, {required bool isOther}) {
      final isNull = !isOther && p.label == null;
      final label = isOther
          ? kOtherLabel
          : (p.label ?? kNullCategoryLabel);
      final node = isOther
          ? null
          : isNull
              ? filterNode('is_null', field: scene.dimension)
              : filterNode('eq', field: scene.dimension, value: p.label);
      return BarDatum(
        label: label,
        value: p.value,
        rowCount: p.rowCount,
        isOther: isOther,
        isNullCategory: isNull,
        isActive: node != null && indexOfFilter(active, node) >= 0,
      );
    }

    _barsCached = [
      for (final p in scene.points) toDatum(p, isOther: false),
      if (scene.other != null) toDatum(scene.other!, isOther: true),
    ];
    return _barsCached;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bars = _bars;
    final dark = theme.brightness == Brightness.dark;
    return Card(
      // Pinned to the token surface rather than Material's default container role, so the
      // bars' contrast is the pair the token test actually measures.
      color: dark ? MorphicColors.surfaceDark : MorphicColors.surfaceLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MorphicRadius.md),
        side: BorderSide(
          color: dark ? MorphicColors.borderDark : MorphicColors.borderLight,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(theme),
            if (_commandError != null)
              Padding(
                padding: const EdgeInsets.only(top: MorphicSpace.xs),
                child: Text(
                  _commandError!,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: MorphicColors.error),
                ),
              ),
            if (_scene?.truncated == true) _partialNotice(theme),
            const SizedBox(height: MorphicSpace.sm),
            _body(theme, bars),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) => Row(
        children: [
          Expanded(
            child: Text(widget.ctx.title, style: theme.textTheme.titleSmall),
          ),
          if (_state == _Load.pending)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (widget.ctx.canSort)
            IconButton(
              key: const Key('bar-sort-toggle'),
              tooltip: _byLabel
                  ? 'Sorted by label — tap for largest first'
                  : 'Sorted by value — tap for label order',
              icon: Icon(_byLabel ? Icons.sort_by_alpha : Icons.bar_chart),
              onPressed: _busy || _state != _Load.ready ? null : _toggleSort,
            ),
          IconButton(
            key: const Key('bar-view-as-table'),
            tooltip: 'View as table',
            icon: const Icon(Icons.table_rows_outlined),
            onPressed: _scene == null ? null : () => _showTable(theme),
          ),
        ],
      );

  Widget _partialNotice(ThemeData theme) => Padding(
        padding: const EdgeInsets.only(top: MorphicSpace.xs),
        child: Text(
          _result!.scene.partialNotice ?? '',
          key: const Key('bar-partial-notice'),
          style: theme.textTheme.labelSmall?.copyWith(color: MorphicColors.warning),
        ),
      );

  Widget _body(ThemeData theme, List<BarDatum> bars) {
    if (_state == _Load.failed) {
      return _Message(
        icon: Icons.error_outline,
        text: _error ?? 'This chart could not be built.',
        action: TextButton(
          key: const Key('bar-retry'),
          onPressed: _fetch,
          child: const Text('Retry'),
        ),
      );
    }
    if (_state == _Load.pending && _result == null) {
      return const SizedBox(
        height: kBarRowHeight * 2,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (bars.isEmpty) {
      return const _Message(
        icon: Icons.filter_alt_off_outlined,
        text: 'No rows match the current filters.',
      );
    }

    final dark = theme.brightness == Brightness.dark;
    final style = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      color: dark ? MorphicColors.textPrimaryDark : MorphicColors.textPrimaryLight,
    );
    final valueStyle = style.copyWith(
      color: dark ? MorphicColors.textSecondaryDark : MorphicColors.textSecondaryLight,
    );
    final scaler = MediaQuery.textScalerOf(context);

    return Semantics(
      container: true,
      label: _summary(bars),
      child: SizedBox(
        height: bars.length * kBarRowHeight,
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: BarChartPainter(
                    bars: bars,
                    barColor:
                        dark ? MorphicColors.accent : MorphicColors.accentDark,
                    otherColor:
                        dark ? MorphicColors.info : MorphicColors.infoDark,
                    trackColor: dark
                        ? MorphicColors.borderDark
                        : MorphicColors.borderLight,
                    textColor: style.color ?? MorphicColors.textPrimaryDark,
                    mutedColor: valueStyle.color ?? MorphicColors.textSecondaryDark,
                    textStyle: style,
                    valueStyle: valueStyle,
                    textScaler: scaler,
                  ),
                ),
              ),
            ),
            // Hit targets and semantics live in the widget tree, not the canvas: a painted
            // bar is invisible to a screen reader and to `tester.tap` without this.
            Column(
              children: [
                for (var i = 0; i < bars.length; i++)
                  SizedBox(
                    height: kBarRowHeight,
                    child: Semantics(
                      button: widget.ctx.canFilter,
                      selected: bars[i].isActive,
                      label: _barSemantics(bars[i]),
                      child: InkWell(
                        key: Key(bars[i].isOther
                            ? 'bar-other-bucket'
                            : 'bar-${bars[i].label}'),
                        onTap: widget.ctx.canFilter && !_busy
                            ? () => _tapBar(bars[i])
                            : null,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _barSemantics(BarDatum b) {
    final value = b.value == null ? 'no value' : formatBarValue(b.value);
    final rows = '${b.rowCount} ${b.rowCount == 1 ? "row" : "rows"}';
    final active = b.isActive ? ', filtering the workspace' : '';
    return '${b.label}, $value, $rows$active';
  }

  String _summary(List<BarDatum> bars) {
    final scene = _scene;
    if (scene == null) return 'Bar chart';
    final named = bars.where((b) => !b.isOther).toList();
    // The largest by value, not the first bar: under a label sort the first bar is the
    // alphabetically first category, and calling it "largest" would be a spoken lie.
    BarDatum? largest;
    for (final b in named) {
      if (b.value == null) continue;
      if (largest == null || b.value! > largest.value!) largest = b;
    }
    final hidden = scene.hiddenCategories;
    return 'Bar chart of ${scene.measure} by ${scene.dimension}. '
        '${named.length} ${named.length == 1 ? "category" : "categories"}'
        '${scene.other != null ? " plus a remainder bucket" : ""}'
        '${hidden > 0 ? ", $hidden more folded into Other" : ""}.'
        '${largest == null ? "" : " Largest ${largest.label}."}';
  }

  /// The accessibility escape hatch: the same numbers as a plain table.
  ///
  /// This renders the **scene**, not rows — it is the chart's own aggregates in another shape,
  /// so it cannot disagree with the bars and does not put row-level work in Dart.
  Future<void> _showTable(ThemeData theme) async {
    final scene = _scene;
    if (scene == null) return;
    final bars = _bars;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(MorphicSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.ctx.title, style: theme.textTheme.titleSmall),
              const SizedBox(height: MorphicSpace.xs),
              Text(
                '${scene.measure} by ${scene.dimension}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: MorphicSpace.md),
              Flexible(
                child: SingleChildScrollView(
                  child: Table(
                    columnWidths: const {
                      0: FlexColumnWidth(3),
                      1: FlexColumnWidth(2),
                      2: FlexColumnWidth(2),
                    },
                    children: [
                      TableRow(
                        children: [
                          _cell(scene.dimension, bold: true),
                          _cell(scene.measure, bold: true),
                          _cell('Rows', bold: true),
                        ],
                      ),
                      for (final b in bars)
                        TableRow(
                          children: [
                            _cell(b.label),
                            _cell(formatBarValue(b.value)),
                            _cell('${b.rowCount}'),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: MorphicSpace.md),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('bar-table-close'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(String text, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: MorphicSpace.xs),
        child: Text(
          text,
          style: bold
              ? Theme.of(context).textTheme.labelMedium
              : Theme.of(context).textTheme.bodySmall,
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: MorphicSpace.md),
          child: Column(
            children: [
              Icon(
                icon,
                size: 20,
                color: Theme.of(context).brightness == Brightness.dark
                    ? MorphicColors.textSecondaryDark
                    : MorphicColors.textSecondaryLight,
              ),
              const SizedBox(height: MorphicSpace.sm),
              Text(
                text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (action != null) action!,
            ],
          ),
        ),
      );
}