/// `timeline` renderer (M1.4 task 1.4.4).
///
/// Draws the [TimelineScene] Rust returns: density buckets, severity lanes in the engine's
/// frequency order, the bucket step, and the count of rows whose time was null. It never buckets,
/// counts or orders anything itself.
///
/// # Interactions (docs/architecture/04 §2)
///
/// - **Tap a bucket** → filter the workspace to that bucket's time range, half-open
///   `[start, start + step)`. Tapping the same bucket again clears it.
/// - **Lane toggle** → tap a severity to hide or show it.
///
/// # Why a tap replaces the previous bucket rather than adding to it
///
/// Two bucket ranges on the same field intersect to nothing, so appending would leave the user
/// staring at an empty workspace after a second tap. Only conjuncts this widget recognises as its
/// own bucket ranges are replaced; a time filter the user set elsewhere is left alone and
/// intersects normally.
///
/// # Why lane visibility is view state
///
/// Same reasoning as the line chart: hiding a lane changes nothing the engine computed, and the
/// schema has no persisted selection field. The time-range filter is the opposite case — it
/// changes which rows the engine returns, so it is a command.
///
/// # Accessibility (docs/design/design-system.md §9)
///
/// A spoken summary, ≥48 dp legend targets, semantic increase/decrease to move the selection
/// without a pointer, and "View as table" for the same numbers as text. Severity is never carried
/// by colour alone: the legend and the table name every lane.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
import 'timeline_painter.dart';

class TimelineView extends StatefulWidget {
  const TimelineView({super.key, required this.ctx});

  final ComponentContext ctx;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

enum _Load { pending, ready, failed }

class _TimelineViewState extends State<TimelineView> {
  _Load _state = _Load.pending;
  ChartResult? _result;
  String? _error;
  String? _commandError;
  int _attempt = 0;
  bool _busy = false;

  /// The revision this timeline last rendered; both contexts share one controller (task 1.3.5).
  int _seenRevision = -1;

  /// Lanes the user has hidden, by display label. View state, not a command.
  Set<String> _hidden = <String>{};

  /// Keyboard/screen-reader preview, identified by bucket start rather than list position.
  /// Previewing is not a filter: the user must explicitly activate the chosen bucket.
  int? _previewStartMs;
  bool _plotFocused = false;

  @override
  void initState() {
    super.initState();
    _seenRevision = widget.ctx.engine.revision;
    _fetch();
  }

  @override
  void didUpdateWidget(TimelineView old) {
    super.didUpdateWidget(old);
    if (_seenRevision != widget.ctx.engine.revision) {
      _seenRevision = widget.ctx.engine.revision;
      _previewStartMs = null;
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
    if (revision != widget.ctx.engine.revision) {
      _fetch();
      return;
    }
    setState(() {
      if (result == null) {
        _state = _Load.failed;
        _error = widget.ctx.engine.error ?? 'The engine could not build this timeline.';
      } else {
        _state = _Load.ready;
        _result = result;
      }
    });
  }

  /// Clear workspace filters without discarding this view's own state.
  Future<void> _clearFilters() async {
    await _send([Commands.setGlobalFilter([])]);
  }

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

  TimelineScene? get _scene {
    final s = _result?.scene;
    return s is TimelineScene ? s : null;
  }

  // --- the bucket range this widget owns ----------------------------------------------------

  /// Half-open `[start, start + step)`, so adjacent buckets never both claim a boundary event.
  /// The bound is a plain integer: the engine reads a number on a timestamp column as UTC
  /// milliseconds, which avoids a formatted-string round trip losing precision.
  Map<String, dynamic> _rangeFor(TimelineColumn c, TimelineScene scene) {
    final step = scene.bucketing.bucketMs;
    return filterNode('and', args: [
      filterNode('gte', field: scene.timeField, value: c.startMs),
      filterNode('lt', field: scene.timeField, value: c.startMs + step),
    ]);
  }

  /// Recognises only this widget's own ranges: same field, the exact `gte`/`lt` pair, and a width
  /// of one bucket. A user's broader time filter must survive a tap on the chart.
  bool _isOwnBucketRange(Map<String, dynamic> node, TimelineScene scene) {
    if (node['op'] != 'and') return false;
    final args = node['args'];
    if (args is! List || args.length != 2) return false;
    final lo = args[0];
    final hi = args[1];
    if (lo is! Map || hi is! Map) return false;
    if (lo['op'] != 'gte' || hi['op'] != 'lt') return false;
    if (lo['field'] != scene.timeField || hi['field'] != scene.timeField) return false;
    final a = lo['value'];
    final b = hi['value'];
    if (a is! int || b is! int) return false;
    return b - a == scene.bucketing.bucketMs;
  }

  Future<void> _tapBucket(TimelineColumn c) async {
    final scene = _scene;
    if (scene == null || !widget.ctx.canFilter || _busy) return;
    if (_previewStartMs != null) setState(() => _previewStartMs = null);
    final range = _rangeFor(c, scene);
    final current = widget.ctx.engine.globalFilters;
    if (indexOfFilter(current, range) >= 0) {
      await _send([Commands.setGlobalFilter(toggledFilters(current, range))]);
      return;
    }
    final kept = current.where((f) => !_isOwnBucketRange(f, scene)).toList();
    await _send([Commands.setGlobalFilter([...kept, range])]);
  }

  /// The bucket the workspace is filtered to, or null. Read from the filters rather than kept as
  /// local state, so a chip removed elsewhere un-highlights the column too.
  int? _activeIndex(TimelineGeometry geo, TimelineScene scene) {
    for (final f in widget.ctx.engine.globalFilters) {
      if (!_isOwnBucketRange(f, scene)) continue;
      final start = (f['args'] as List)[0]['value'] as int;
      for (var i = 0; i < geo.columns.length; i++) {
        if (geo.columns[i].startMs == start) return i;
      }
    }
    return null;
  }

  // --- geometry, memoised -------------------------------------------------------------------

  ChartResult? _geoResult;
  String _geoKey = '';
  bool _geoDark = true;
  TextStyle? _geoAxisStyle;
  TextScaler? _geoScaler;
  TimelineGeometry? _geoCache;

  TimelineGeometry _geometry(bool dark, TextStyle axisStyle, TextScaler scaler) {
    final scene = _scene;
    if (scene == null) {
      return TimelineGeometry(
        lanes: const [],
        columns: const [],
        bucketMs: 0,
        hasSeveritySplit: false,
      );
    }
    final key = (_hidden.toList()..sort()).join('|');
    if (identical(_geoResult, _result) &&
        key == _geoKey &&
        dark == _geoDark &&
        axisStyle == _geoAxisStyle &&
        scaler == _geoScaler) {
      return _geoCache!;
    }
    final hasSplit = scene.lanes.isNotEmpty;
    final lanes = <TimelineLane>[];
    if (!hasSplit) {
      // No severity field: one neutral lane, so the painter has a single code path. The legend
      // stays hidden because `hasSeveritySplit` is false — there is no split to name.
      lanes.add(TimelineLane(
        label: null,
        color: dark ? MorphicColors.accent : MorphicColors.accentDark,
        engineIndex: 0,
      ));
    } else {
      for (var i = 0; i < scene.lanes.length; i++) {
        final label = scene.lanes[i];
        if (_hidden.contains(label ?? kNullLaneLabel)) continue;
        lanes.add(TimelineLane(
          label: label,
          // Colour follows the engine's index, so hiding a lane never recolours the rest.
          color: severityColor(label, dark: dark, index: i),
          engineIndex: i,
        ));
      }
    }

    // Bucket lanes carry a label, not an index. Labels are unique per scene: the engine's group
    // key and its display label are one-to-one within a column, so this mapping is unambiguous.
    final engineIndexOf = <String, int>{};
    for (var i = 0; i < scene.lanes.length; i++) {
      engineIndexOf.putIfAbsent(scene.lanes[i] ?? kNullLaneLabel, () => i);
    }
    final positionOf = <int, int>{};
    for (var p = 0; p < lanes.length; p++) {
      positionOf[lanes[p].engineIndex] = p;
    }

    final columns = <TimelineColumn>[];
    for (final b in scene.buckets) {
      if (!hasSplit) {
        columns.add(TimelineColumn(
          startMs: b.startMs,
          count: b.count,
          segments: [TimelineSegment(laneIndex: 0, count: b.count)],
        ));
        continue;
      }
      final segments = <TimelineSegment>[];
      for (final lc in b.lanes) {
        final ei = engineIndexOf[lc.lane ?? kNullLaneLabel];
        if (ei == null) continue;
        final pos = positionOf[ei];
        if (pos == null) continue; // hidden lane
        segments.add(TimelineSegment(laneIndex: pos, count: lc.count));
      }
      columns.add(TimelineColumn(
        startMs: b.startMs,
        count: b.count,
        segments: segments,
      ));
    }

    _geoResult = _result;
    _geoKey = key;
    _geoDark = dark;
    _geoAxisStyle = axisStyle;
    _geoScaler = scaler;
    _geoCache = TimelineGeometry(
      lanes: lanes,
      columns: columns,
      bucketMs: scene.bucketing.bucketMs,
      hasSeveritySplit: hasSplit,
      axisTextStyle: axisStyle,
      axisTextScaler: scaler,
    );
    return _geoCache!;
  }

  void _toggleLane(String label) {
    setState(() {
      final next = Set<String>.of(_hidden);
      if (!next.remove(label)) next.add(label);
      _hidden = next;
    });
  }

  int? _previewIndex(TimelineGeometry geo) {
    final start = _previewStartMs;
    if (start == null) return null;
    final index = geo.columns.indexWhere((column) => column.startMs == start);
    return index < 0 ? null : index;
  }

  int? _nextPreview(int delta, TimelineGeometry geo, TimelineScene scene) {
    final n = geo.columns.length;
    if (n == 0) return null;
    final current = _previewIndex(geo) ?? _activeIndex(geo, scene) ?? (delta > 0 ? -1 : n);
    return (current + delta).clamp(0, n - 1);
  }

  /// Stepping previews without filtering. Filtering on the first step would re-query the chart
  /// with only that bucket left, making middle buckets impossible to reach without a pointer.
  void _movePreview(int delta, TimelineGeometry geo, TimelineScene scene) {
    final next = _nextPreview(delta, geo, scene);
    if (next == null || _busy) return;
    setState(() => _previewStartMs = geo.columns[next].startMs);
  }

  KeyEventResult _plotKey(FocusNode _, KeyEvent event, TimelineGeometry geo, TimelineScene scene) {
    if (_busy || !widget.ctx.canFilter || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowUp) {
      _movePreview(1, geo, scene);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowDown) {
      _movePreview(-1, geo, scene);
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space)) {
      final index = _previewIndex(geo) ?? _activeIndex(geo, scene);
      if (index != null) {
        unawaited(_tapBucket(geo.columns[index]));
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final scene = _scene;
    final geo = _geometry(dark, _axisStyle(theme, dark), MediaQuery.textScalerOf(context));
    final active = scene == null ? null : _activeIndex(geo, scene);
    return Card(
      // Pinned to the token surface so the severity palette's contrast is the pair the token test
      // measures, not Material's default container role.
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
            if (scene != null && scene.isPartial) _partialNotice(theme, scene),
            if (_commandError != null)
              MorphicCommandError(
                evidence: _commandError!,
                evidenceKey: const Key('timeline-command-error'),
              ),
            const SizedBox(height: MorphicSpace.sm),
            _body(theme, dark, scene, geo, active),
            if (scene != null && geo.hasSeveritySplit && scene.lanes.length > 1)
              _legend(theme, dark, scene),
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
            key: const Key('timeline-view-as-table'),
            tooltip: 'View as table',
            icon: const Icon(Icons.table_rows_outlined),
            onPressed: _scene == null ? null : _showTable,
          ),
        ],
      );

  Widget _partialNotice(ThemeData theme, TimelineScene scene) => Padding(
        padding: const EdgeInsets.only(top: MorphicSpace.xs),
        child: Text(
          scene.partialNotice ?? '',
          key: const Key('timeline-partial-notice'),
          style: theme.textTheme.labelSmall?.copyWith(
            color: MorphicColors.warningText(theme.brightness),
          ),
        ),
      );

  TextStyle _axisStyle(ThemeData theme, bool dark) =>
      (MorphicTypography.dataStyle(theme.textTheme.labelSmall) ?? const TextStyle(fontSize: 11))
          .copyWith(
        color: dark ? MorphicColors.textSecondaryDark : MorphicColors.textSecondaryLight,
      );

  Widget _body(
    ThemeData theme,
    bool dark,
    TimelineScene? scene,
    TimelineGeometry geo,
    int? active,
  ) {
    if (_state == _Load.failed) {
      return MorphicStateMessage(
        icon: Icons.error_outline,
        headline: MorphicCopy.timelineFailure,
        detail: _error,
        isError: true,
        action: TextButton(
          key: const Key('timeline-retry'),
          onPressed: _fetch,
          child: const Text(MorphicCopy.retry),
        ),
      );
    }
    if (_state == _Load.pending && _result == null) {
      return const SizedBox(
        height: kTimelinePlotHeight,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (scene == null || scene.buckets.isEmpty) {
      final hasWorkspaceFilters = widget.ctx.engine.globalFilters.isNotEmpty;
      final viewCommands = clearViewNarrowingCommands(widget.ctx);
      return MorphicStateMessage(
        icon: Icons.filter_alt_off_outlined,
        headline: 'No dated rows match the current filters.',
        detail: !hasWorkspaceFilters && viewCommands.isEmpty
            ? MorphicCopy.noRowsDetail
            : null,
        action: hasWorkspaceFilters || viewCommands.isNotEmpty
            ? MorphicFilterActions(
                workspaceKey: const Key('timeline-clear-filters'),
                viewKey: const Key('timeline-clear-view-filters'),
                onClearWorkspace: hasWorkspaceFilters ? _clearFilters : null,
                onClearView: viewCommands.isEmpty ? null : () => _send(viewCommands),
                busy: _busy,
              )
            : null,
      );
    }
    if (geo.columns.every((c) => c.visibleCount == 0)) {
      return SizedBox(
        height: kTimelinePlotHeight,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Every lane is hidden.'),
              TextButton(
                key: const Key('timeline-show-all-lanes'),
                onPressed: () => setState(() => _hidden = <String>{}),
                child: const Text('Show all lanes'),
              ),
            ],
          ),
        ),
      );
    }

    final style = _axisStyle(theme, dark);
    final preview = _previewIndex(geo);
    final selected = preview ?? active;
    final adjustable = widget.ctx.canFilter && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          key: const Key('timeline-plot-semantics'),
          container: true,
          slider: widget.ctx.canFilter,
          label: _summary(scene, geo),
          value: _bucketValue(scene, geo, selected, active),
          increasedValue:
              adjustable ? _bucketValue(scene, geo, _nextPreview(1, geo, scene), active) : null,
          decreasedValue:
              adjustable ? _bucketValue(scene, geo, _nextPreview(-1, geo, scene), active) : null,
          hint: widget.ctx.canFilter
              ? 'Adjust or use arrow keys to preview. Activate to filter or clear the selected bucket.'
              : 'View as table lists the values.',
          onIncrease: adjustable ? () => _movePreview(1, geo, scene) : null,
          onDecrease: adjustable ? () => _movePreview(-1, geo, scene) : null,
          onTap: adjustable && selected != null ? () => _tapBucket(geo.columns[selected]) : null,
          onTapHint: adjustable && selected != null
              ? (selected == active ? 'clear bucket filter' : 'filter to this bucket')
              : null,
          child: Focus(
            key: const Key('timeline-plot-focus'),
            canRequestFocus: widget.ctx.canFilter,
            onKeyEvent: (node, event) => _plotKey(node, event, geo, scene),
            onFocusChange: (focused) {
              if (mounted && _plotFocused != focused) setState(() => _plotFocused = focused);
            },
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _plotFocused ? theme.colorScheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: SizedBox(
                key: const Key('timeline-plot'),
                height: kTimelinePlotHeight,
                width: double.infinity,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(constraints.maxWidth, constraints.maxHeight);
                    return GestureDetector(
                      // Semantic activation targets the preview above, not an invented center tap.
                      excludeFromSemantics: true,
                      behavior: HitTestBehavior.opaque,
                      onTapUp: widget.ctx.canFilter
                          ? (d) {
                              final i = geo.columnAt(
                                d.localPosition.dx,
                                geo.plotIn(size),
                              );
                              if (i != null) _tapBucket(geo.columns[i]);
                            }
                          : null,
                      child: RepaintBoundary(
                        child: CustomPaint(
                          key: const Key('timeline-paint'),
                          size: size,
                          painter: TimelinePainter(
                            geometry: geo,
                            gridColor: dark ? MorphicColors.borderDark : MorphicColors.borderLight,
                            textStyle: style,
                            textScaler: MediaQuery.textScalerOf(context),
                            activeColumn: selected,
                            activeColor: dark
                                ? MorphicColors.textPrimaryDark
                                : MorphicColors.textPrimaryLight,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        if (selected != null)
          _selectedBucket(theme, scene, geo, selected, previewing: selected != active),
      ],
    );
  }

  /// The selected bucket's own numbers, as text. A widget rather than painted text so the render
  /// tree caches its layout and a screen reader can read it.
  Widget _selectedBucket(
    ThemeData theme,
    TimelineScene scene,
    TimelineGeometry geo,
    int index, {
    required bool previewing,
  }) {
    final c = geo.columns[index];
    final at = formatBucketLabel(
      c.startMs.toDouble(),
      temporal: true,
      bucketMs: scene.bucketing.bucketMs,
    );
    final parts = <String>[
      for (final s in c.segments) '${geo.lanes[s.laneIndex].displayLabel} ${s.count}',
    ];
    return Container(
      key: const Key('timeline-selection'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: MorphicSpace.sm),
      padding: const EdgeInsets.all(MorphicSpace.sm),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? MorphicColors.surfaceElevatedDark
            : MorphicColors.bgLight,
        borderRadius: BorderRadius.circular(MorphicRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (previewing)
            Text(
              'Preview — not filtering the workspace',
              style: theme.textTheme.labelMedium,
            ),
          Text(
            '$at · ${c.count} events',
            style: theme.textTheme.labelMedium,
          ),
          if (parts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: MorphicSpace.xs),
              child: Text(parts.join(' · '), style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Widget _legend(ThemeData theme, bool dark, TimelineScene scene) => Padding(
        padding: const EdgeInsets.only(top: MorphicSpace.xs),
        child: Wrap(
          spacing: MorphicSpace.xs,
          children: [
            for (var i = 0; i < scene.lanes.length; i++)
              _legendChip(
                theme,
                scene.lanes[i] ?? kNullLaneLabel,
                severityColor(scene.lanes[i], dark: dark, index: i),
              ),
            if (_hidden.isNotEmpty)
              SizedBox(
                height: 48,
                child: TextButton(
                  key: const Key('timeline-show-all'),
                  onPressed: () => setState(() => _hidden = <String>{}),
                  child: const Text('Show all'),
                ),
              ),
          ],
        ),
      );

  Widget _legendChip(ThemeData theme, String label, Color color) {
    final hidden = _hidden.contains(label);
    return SizedBox(
      // 48 dp is the accessibility floor for a tap target, even though the chip draws smaller.
      height: 48,
      child: TextButton(
        key: Key('timeline-legend-$label'),
        onPressed: widget.ctx.canSelect ? () => _toggleLane(label) : null,
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
        child: Semantics(
          label: '$label lane',
          value: hidden ? 'Hidden' : 'Visible',
          toggled: widget.ctx.canSelect ? !hidden : null,
          onTapHint: widget.ctx.canSelect ? (hidden ? 'show lane' : 'hide lane') : null,
          excludeSemantics: true,
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
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  decoration: hidden ? TextDecoration.lineThrough : null,
                  color: hidden ? theme.colorScheme.onSurfaceVariant : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _summary(TimelineScene scene, TimelineGeometry geo) {
    final base = 'Timeline of ${scene.timeField}, '
        '${geo.columns.length} buckets of ${scene.bucketing.label}'
        '${geo.hasSeveritySplit ? ", ${geo.lanes.length} lanes shown" : ""}'
        '${_hidden.isEmpty ? "" : ", ${_hidden.length} hidden"}.';
    final partial = scene.partialNotice;
    return partial == null ? base : '$base $partial';
  }

  String _bucketValue(TimelineScene scene, TimelineGeometry geo, int? index, int? active) {
    if (index == null || index < 0 || index >= geo.columns.length) {
      return 'No bucket selected';
    }
    final column = geo.columns[index];
    final at = formatBucketLabel(
      column.startMs.toDouble(),
      temporal: true,
      bucketMs: scene.bucketing.bucketMs,
    );
    final parts = [
      for (final segment in column.segments)
        '${geo.lanes[segment.laneIndex].displayLabel} ${segment.count}',
    ];
    final state = index == active ? 'Filtering to' : 'Preview, not filtering:';
    final lanes = parts.isEmpty ? '' : ', visible lanes ${parts.join(", ")}';
    return '$state $at, ${column.count} events total$lanes';
  }

  /// The accessibility escape hatch: the scene's own numbers as text.
  ///
  /// A scene can hold 2000 buckets, so rows are built lazily. Bucket labels and lane breakdowns
  /// can wrap rather than squeezing or truncating up to eight lanes in a narrow detail rail.
  Future<void> _showTable() async {
    final scene = _scene;
    if (scene == null) return;
    final hostTheme = Theme.of(context);
    final dark = hostTheme.brightness == Brightness.dark;
    final geo = _geometry(dark, _axisStyle(hostTheme, dark), MediaQuery.textScalerOf(context));
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
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: MorphicSpace.xs),
                Text(
                  '${geo.columns.length} buckets of ${scene.bucketing.label}'
                  '${hiddenCount == 0 ? "" : " · $hiddenCount lanes hidden"}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (WorkspaceDetailScope.maybeOf(context) != null)
                  Text(
                    'Snapshot of the visible lanes. Open again after changing the legend.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (scene.partialNotice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: MorphicSpace.xs),
                    child: Text(
                      scene.partialNotice!,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: MorphicColors.warningText(Theme.of(context).brightness),
                      ),
                    ),
                  ),
                const Divider(height: MorphicSpace.md),
                Expanded(
                  child: ListView.builder(
                    key: const Key('timeline-table-buckets'),
                    itemCount: geo.columns.length,
                    itemBuilder: (context, i) {
                      final c = geo.columns[i];
                      final parts = <String>[
                        for (final s in c.segments)
                          '${geo.lanes[s.laneIndex].displayLabel} ${s.count}',
                      ];
                      return Padding(
                        key: Key('timeline-table-bucket-$i'),
                        padding: const EdgeInsets.symmetric(vertical: MorphicSpace.xs),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    formatBucketLabel(
                                      c.startMs.toDouble(),
                                      temporal: true,
                                      bucketMs: scene.bucketing.bucketMs,
                                    ),
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    '${c.count}',
                                    textAlign: TextAlign.right,
                                    style: Theme.of(context).textTheme.labelMedium,
                                  ),
                                ),
                              ],
                            ),
                            if (parts.isNotEmpty)
                              Text(
                                parts.join(' · '),
                                key: Key('timeline-table-lanes-$i'),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const Key('timeline-table-close'),
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
}
