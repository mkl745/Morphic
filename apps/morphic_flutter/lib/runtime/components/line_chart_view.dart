/// `line_chart` renderer (M1.4 task 1.4.3).
///
/// Draws the [SeriesScene] Rust returns: bucketed points, the engine's bucket step, and its
/// truncation flags. It never groups, buckets or averages anything itself.
///
/// # Interactions (docs/architecture/04 §2)
///
/// - **Scrub** — drag or tap the plot to read the bucket under the finger. The crosshair and
///     markers live on a separate painter layer, so moving a finger across a 2000-point chart
///     does not repaint the lines (docs/architecture/07 §3).
/// - **Legend toggle** — tap a series to hide or show it.
///
/// # Why legend visibility is view state, not a command
///
/// Hiding a series does not change the engine's answer: the scene still carries every series
/// and every point, and nothing is re-aggregated. The schema has no persisted selection field,
/// so inventing one would be a schema change for a display preference. Visibility therefore
/// lives in this widget, like scroll position. The sort toggle on the bar chart is the opposite
/// case — it changes which bars the engine returns, so it is a command.
///
/// # Accessibility (docs/design/design-system.md §9)
///
/// A spoken summary, ≥48 dp legend targets, semantic increase/decrease to move the scrub without
/// a pointer, and "View as table" for the same numbers in text. Colour is never the only channel:
/// the legend and tooltip name every series.
library;

import 'package:flutter/material.dart';

import '../../design_system/copy.dart';
import '../../design_system/tokens.dart';
import '../../engine/chart_scene.dart';
import '../../engine/interaction.dart';
import '../change_type_button.dart';
import '../component_registry.dart';
import '../explanation_sheet.dart';
import '../filter_recovery.dart';
import '../responsive_detail.dart';
import 'chart_format.dart';
import 'line_chart_painter.dart';

/// A null group is a real series and needs a name a screen reader can say.
const String kNullSeriesLabel = '(none)';

class LineChartView extends StatefulWidget {
  const LineChartView({super.key, required this.ctx});

  final ComponentContext ctx;

  @override
  State<LineChartView> createState() => _LineChartViewState();
}

enum _Load { pending, ready, failed }

class _LineChartViewState extends State<LineChartView> {
  _Load _state = _Load.pending;
  ChartResult? _result;
  String? _error;
  String? _commandError;
  int _attempt = 0;
  bool _busy = false;

  /// The revision this chart last rendered. Both contexts hold one controller, so comparing
  /// `old.ctx.engine.revision` to the current one can never differ (task 1.3.5).
  int _seenRevision = -1;

  /// Series the user has hidden, by name. View state, not a command — see the class doc.
  Set<String> _hidden = <String>{};

  /// The bucket under the finger, or null when not scrubbing.
  int? _scrub;

  @override
  void initState() {
    super.initState();
    _seenRevision = widget.ctx.engine.revision;
    _fetch();
  }

  @override
  void didUpdateWidget(LineChartView old) {
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
        _scrub = null; // the old bucket index need not exist in the new scene
      }
    });
  }

  SeriesScene? get _scene {
    final s = _result?.scene;
    return s is SeriesScene ? s : null;
  }

  static String _keyOf(ChartSeries s) => s.name ?? kNullSeriesLabel;

  // --- geometry, memoised -----------------------------------------------------------------
  //
  // Rebuilt only when the scene, the hidden set or the theme changes. Rebuilding it on every
  // pointer move would hand the base painter a new object and defeat its identity check,
  // repainting 2000 points per frame — the exact cost the two-layer split exists to avoid.
  ChartResult? _geoResult;
  String _geoKey = '';
  bool _geoDark = true;
  LineGeometry? _geoCache;

  LineGeometry _geometry(bool dark) {
    final scene = _scene;
    if (scene == null) {
      return LineGeometry(series: const [], temporal: false, bucketMs: 0);
    }
    final key = (_hidden.toList()..sort()).join('|');
    if (identical(_geoResult, _result) && key == _geoKey && dark == _geoDark) {
      return _geoCache!;
    }
    final palette = dark ? MorphicColors.seriesDark : MorphicColors.seriesLight;
    final visible = <LineSeriesDatum>[];
    for (var i = 0; i < scene.series.length; i++) {
      final s = scene.series[i];
      if (_hidden.contains(_keyOf(s))) continue;
      visible.add(LineSeriesDatum(
        name: _keyOf(s),
        points: s.points,
        // Colour follows the engine's index, so hiding one series never recolours the others.
        color: palette[i % palette.length],
      ));
    }
    _geoResult = _result;
    _geoKey = key;
    _geoDark = dark;
    _geoCache = LineGeometry(
      series: visible,
      temporal: scene.temporal,
      bucketMs: scene.bucketing.bucketMs,
    );
    return _geoCache!;
  }

  void _toggleSeries(String name) {
    setState(() {
      final next = Set<String>.of(_hidden);
      if (!next.remove(name)) next.add(name);
      _hidden = next;
      _scrub = null;
    });
  }

  void _moveScrub(int delta, LineGeometry geo) {
    final n = geo.firstPoints.length;
    if (n == 0) return;
    setState(() {
      final current = _scrub ?? (delta > 0 ? -1 : n);
      _scrub = (current + delta).clamp(0, n - 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final scene = _scene;
    final geo = _geometry(dark);
    return Card(
      // Pinned to the token surface so the series palette's contrast is the pair the token
      // test measures, not Material's default container role.
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
              MorphicCommandError(
                evidence: _commandError!,
                evidenceKey: const Key('line-command-error'),
              ),
            if (scene != null && scene.isPartial) _partialNotice(theme, scene),
            const SizedBox(height: MorphicSpace.sm),
            _body(theme, dark, scene, geo),
            if (scene != null && scene.series.length > 1 && widget.ctx.canSelect)
              _legend(theme, scene),
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
          if (_state == _Load.pending || _busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ExplanationButton(
            id: widget.ctx.id,
            title: widget.ctx.title,
            explanation: widget.ctx.explanation,
          ),
          ChangeTypeButton(
            engine: widget.ctx.engine,
            id: widget.ctx.id,
            type: widget.ctx.type,
          ),
          IconButton(
            key: const Key('line-view-as-table'),
            tooltip: 'View as table',
            icon: const Icon(Icons.table_rows_outlined),
            onPressed: _scene == null ? null : () => _showTable(theme),
          ),
        ],
      );

  Widget _partialNotice(ThemeData theme, SeriesScene scene) => Padding(
        padding: const EdgeInsets.only(top: MorphicSpace.xs),
        child: Text(
          scene.partialNotice ?? '',
          key: const Key('line-partial-notice'),
          style: theme.textTheme.labelSmall?.copyWith(
            color: MorphicColors.warningText(theme.brightness),
          ),
        ),
      );

  Future<void> _send(List<Map<String, dynamic>> commands) async {
    if (_busy) return;
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

  Future<void> _clearFilters() => _send([Commands.setGlobalFilter([])]);

  Widget _emptyMessage(String headline, IconData icon) {
    final hasWorkspaceFilters = widget.ctx.engine.globalFilters.isNotEmpty;
    final viewCommands = clearViewNarrowingCommands(widget.ctx);
    return MorphicStateMessage(
      icon: icon,
      headline: headline,
      detail: !hasWorkspaceFilters && viewCommands.isEmpty
          ? MorphicCopy.noRowsDetail
          : null,
      action: hasWorkspaceFilters || viewCommands.isNotEmpty
          ? MorphicFilterActions(
              workspaceKey: const Key('line-clear-filters'),
              viewKey: const Key('line-clear-view-filters'),
              onClearWorkspace: hasWorkspaceFilters ? _clearFilters : null,
              onClearView: viewCommands.isEmpty ? null : () => _send(viewCommands),
              busy: _busy,
            )
          : null,
    );
  }

  Widget _body(ThemeData theme, bool dark, SeriesScene? scene, LineGeometry geo) {
    if (_state == _Load.failed) {
      return MorphicStateMessage(
        icon: Icons.error_outline,
        headline: MorphicCopy.chartFailure,
        detail: _error,
        isError: true,
        action: TextButton(
          key: const Key('line-retry'),
          onPressed: _fetch,
          child: const Text(MorphicCopy.retry),
        ),
      );
    }
    if (_state == _Load.pending && _result == null) {
      return const SizedBox(
        height: kLinePlotHeight,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (scene == null || scene.series.isEmpty) {
      return _emptyMessage(MorphicCopy.noRowsMatch, Icons.filter_alt_off_outlined);
    }
    if (geo.series.isEmpty) {
      return MorphicStateMessage(
        icon: Icons.visibility_off_outlined,
        headline: 'All series are hidden.',
        action: TextButton(
          key: const Key('line-show-all'),
          onPressed: () => setState(() => _hidden = <String>{}),
          child: const Text('Show all'),
        ),
      );
    }
    if (geo.isEmpty) {
      return _emptyMessage(
        'No values in range: every bucket is empty.',
        Icons.show_chart,
      );
    }

    final style = (MorphicTypography.dataStyle(theme.textTheme.labelSmall) ??
            const TextStyle()).copyWith(
      color: dark ? MorphicColors.textSecondaryDark : MorphicColors.textSecondaryLight,
    );
    final scaler = MediaQuery.textScalerOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          container: true,
          label: _summary(scene, geo),
          onIncrease: () => _moveScrub(1, geo),
          onDecrease: () => _moveScrub(-1, geo),
          child: SizedBox(
            key: const Key('line-plot'),
            height: kLinePlotHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _scrubTo(d.localPosition.dx, geo, size),
                  onPanStart: (d) => _scrubTo(d.localPosition.dx, geo, size),
                  onPanUpdate: (d) => _scrubTo(d.localPosition.dx, geo, size),
                  child: Stack(
                    children: [
                      // Layer 1: axes and lines. Cached; untouched by scrubbing.
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            key: const Key('line-base-paint'),
                            painter: LineChartPainter(
                              geometry: geo,
                              gridColor: dark
                                  ? MorphicColors.borderDark
                                  : MorphicColors.borderLight,
                              textStyle: style,
                              textScaler: scaler,
                            ),
                          ),
                        ),
                      ),
                      // Layer 2: crosshair and markers. The only thing a pointer move repaints.
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            key: const Key('line-overlay-paint'),
                            painter: ScrubOverlayPainter(
                              geometry: geo,
                              bucketIndex: _scrub,
                              crosshairColor: style.color ?? Colors.grey,
                              markerFill: dark
                                  ? MorphicColors.surfaceDark
                                  : MorphicColors.surfaceLight,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        if (_scrub != null) _tooltip(theme, dark, geo, scene),
      ],
    );
  }

  void _scrubTo(double dx, LineGeometry geo, Size size) {
    final index = geo.bucketAt(dx, geo.plotIn(size));
    // Only rebuild when the bucket actually changes. A drag crosses many pixels per bucket;
    // setState per pixel would rebuild the tooltip and overlay for no visible difference.
    if (index == null || index == _scrub) return;
    setState(() => _scrub = index);
  }

  /// The tooltip is a widget, not painted text: Flutter caches its layout, a screen reader can
  /// read it, and the overlay painter stays free of per-move text allocation.
  Widget _tooltip(ThemeData theme, bool dark, LineGeometry geo, SeriesScene scene) {
    final index = _scrub!;
    final points = geo.firstPoints;
    if (index < 0 || index >= points.length) return const SizedBox.shrink();
    final label = formatBucketLabel(
      points[index].x,
      temporal: scene.temporal,
      bucketMs: scene.bucketing.bucketMs,
    );
    return Container(
      key: const Key('line-tooltip'),
      margin: const EdgeInsets.only(top: MorphicSpace.sm),
      padding: const EdgeInsets.all(MorphicSpace.sm),
      decoration: BoxDecoration(
        color: dark ? MorphicColors.surfaceElevatedDark : MorphicColors.bgLight,
        borderRadius: BorderRadius.circular(MorphicRadius.sm),
        border: Border.all(
          color: dark ? MorphicColors.borderDark : MorphicColors.borderLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: MorphicSpace.xs),
          for (final s in geo.series)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: MorphicSpace.sm),
                  Expanded(
                    child: Text(s.name, style: theme.textTheme.bodySmall),
                  ),
                  Text(
                    index < s.points.length
                        ? formatChartValue(s.points[index].y)
                        : '—',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _legend(ThemeData theme, SeriesScene scene) {
    final dark = theme.brightness == Brightness.dark;
    final palette = dark ? MorphicColors.seriesDark : MorphicColors.seriesLight;
    return Padding(
      padding: const EdgeInsets.only(top: MorphicSpace.sm),
      child: Wrap(
        spacing: MorphicSpace.sm,
        children: [
          for (var i = 0; i < scene.series.length; i++)
            _legendChip(theme, _keyOf(scene.series[i]), palette[i % palette.length]),
        ],
      ),
    );
  }

  Widget _legendChip(ThemeData theme, String name, Color color) {
    final hidden = _hidden.contains(name);
    return SizedBox(
      // 48 dp is the accessibility floor for a tap target, even though the chip draws smaller.
      height: 48,
      child: TextButton(
        key: Key('line-legend-$name'),
        onPressed: () => _toggleSeries(name),
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: hidden ? Colors.transparent : color,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2),
              ),
            ),
            const SizedBox(width: MorphicSpace.xs + 2),
            Text(
              name,
              style: theme.textTheme.bodySmall?.copyWith(
                decoration: hidden ? TextDecoration.lineThrough : null,
                color: hidden
                    ? theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _summary(SeriesScene scene, LineGeometry geo) {
    final shown = geo.series.length;
    final base = 'Line chart of ${scene.xField}'
        '${scene.temporal ? " over time" : ""}, '
        '$shown series shown'
        '${_hidden.isEmpty ? "" : ", ${_hidden.length} hidden"}, '
        '${geo.firstPoints.length} buckets of ${scene.bucketing.label}.';
    final index = _scrub;
    if (index == null || index >= geo.firstPoints.length) return base;
    final values = geo.series
        .map((s) => '${s.name} '
            '${index < s.points.length ? formatChartValue(s.points[index].y) : "no value"}')
        .join(', ');
    final at = formatBucketLabel(
      geo.firstPoints[index].x,
      temporal: scene.temporal,
      bucketMs: scene.bucketing.bucketMs,
    );
    return '$base At $at: $values.';
  }

  /// The accessibility escape hatch: the scene's own numbers as text.
  ///
  /// A line scene can hold 2000 buckets, so the rows are built lazily — a `Table` of 2000 rows
  /// would lay out all of them to show twenty.
  Future<void> _showTable(ThemeData theme) async {
    final scene = _scene;
    if (scene == null) return;
    final dark = theme.brightness == Brightness.dark;
    final geo = _geometry(dark);
    final title = widget.ctx.title;
    final hiddenCount = _hidden.length;
    await showWorkspaceDetail(
      context,
      builder: (context, close) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(MorphicSpace.lg),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.7,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: MorphicSpace.xs),
                Text(
                  '${geo.firstPoints.length} buckets of ${scene.bucketing.label}'
                  '${hiddenCount == 0 ? "" : " · $hiddenCount series hidden"}',
                  style: theme.textTheme.bodySmall,
                ),
                if (WorkspaceDetailScope.maybeOf(context) != null)
                  Text(
                    'Snapshot of the visible series. Open again after changing the legend.',
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: MorphicSpace.md),
                _tableRow(
                  theme,
                  [scene.xField, for (final s in geo.series) s.name],
                  bold: true,
                ),
                const Divider(height: MorphicSpace.md),
                Expanded(
                  child: ListView.builder(
                    itemCount: geo.firstPoints.length,
                    itemExtent: 32,
                    itemBuilder: (context, i) => _tableRow(
                      theme,
                      [
                        formatBucketLabel(
                          geo.firstPoints[i].x,
                          temporal: scene.temporal,
                          bucketMs: scene.bucketing.bucketMs,
                        ),
                        for (final s in geo.series)
                          i < s.points.length ? formatChartValue(s.points[i].y) : '—',
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const Key('line-table-close'),
                    onPressed: close,
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _tableRow(ThemeData theme, List<String> cells, {bool bold = false}) => Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              flex: i == 0 ? 3 : 2,
              child: Text(
                cells[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: bold ? theme.textTheme.labelMedium : theme.textTheme.bodySmall,
              ),
            ),
        ],
      );
}
