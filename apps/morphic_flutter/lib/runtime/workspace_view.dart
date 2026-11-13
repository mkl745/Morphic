/// Adaptive workspace renderer (M1.1 task 1.1.5).
///
/// Draws the generated document in `layout.order` through the [ComponentRegistry]. Compact
/// windows use one column; medium and expanded windows arrange views in columns while
/// respecting persisted span hints. Editing emits engine commands rather than keeping a
/// second layout document in Dart.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../design_system/copy.dart';
import '../design_system/motion.dart';
import '../design_system/responsive.dart';
import '../design_system/tokens.dart';
import '../engine/engine_controller.dart';
import '../engine/interaction.dart';
import 'component_registry.dart';
import 'global_filter_bar.dart';

/// Bounded heights for the three resize-menu choices. The table view already clamps its own
/// body to at least 280 dp, so "small" deliberately starts there rather than clipping it.
const Map<String, double> _layoutHeights = <String, double>{
  'small': 280,
  'medium': 400,
  'large': 560,
};

class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.controller,
    required this.registry,
    this.entrance,
    this.onRetry,
    this.onRestoreSource,
    this.layoutEditing = false,
    this.focusMode = false,
    this.focusIndex = 0,
    this.onFocusIndexChanged,
  });

  final EngineController controller;
  final ComponentRegistry registry;

  /// One clock started after a real import completes; null means no entrance animation.
  final Animation<double>? entrance;
  final VoidCallback? onRetry;

  /// Optional degraded-mode recovery action. Supplied by the host screen, which owns the
  /// bridge call; the notice only renders the affordance (M1.5 task 1.5.3, AT-16).
  final VoidCallback? onRestoreSource;

  /// App-bar-owned layout editing mode. Off by default so the 54 component goldens and the
  /// existing runtime tests see the exact widget tree they did before 1.5.2.
  final bool layoutEditing;

  /// Compact focus mode expands one component and keeps the others as summaries. It is
  /// view-only; layout edits themselves are persisted by Rust as commands.
  final bool focusMode;
  final int focusIndex;
  final ValueChanged<int>? onFocusIndexChanged;

  Map<String, Map<String, dynamic>> _hints() {
    final ws = controller.doc?['workspace'];
    if (ws is! Map) return const <String, Map<String, dynamic>>{};
    final layout = ws['layout'];
    if (layout is! Map) return const <String, Map<String, dynamic>>{};
    return <String, Map<String, dynamic>>{
      for (final raw in (layout['hints'] as List? ?? const []))
        if (raw is Map && raw['componentId'] is String)
          raw['componentId'] as String: Map<String, dynamic>.from(raw),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (controller.doc == null) {
      if (controller.busy) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      if (controller.error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(MorphicSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Could not open this workspace',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: MorphicSpace.sm),
                Text(controller.error!, style: theme.textTheme.bodySmall),
                const SizedBox(height: MorphicSpace.md),
                if (onRetry != null)
                  FilledButton(
                    onPressed: onRetry,
                    child: const Text(MorphicCopy.retry),
                  )
                else
                  Text(
                    MorphicCopy.workspaceOpenFailureDetail,
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
              ],
            ),
          ),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(MorphicSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('No workspace open.', style: theme.textTheme.bodySmall),
              const SizedBox(height: MorphicSpace.sm),
              Text(
                MorphicCopy.noWorkspaceOpenDetail,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final components = controller.components;
    if (components.isEmpty) {
      final empty = Center(
        child: Padding(
          padding: const EdgeInsets.all(MorphicSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'The engine generated no components for this file.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: MorphicSpace.sm),
              Text(
                MorphicCopy.noComponentsDetail,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
      if (!controller.degraded) return empty;
      // The compact app bar relies on this notice for recovery. An empty component list
      // must not bypass the notice and leave the user without a way to restore the source.
      return ListView(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        children: [
          DegradedNotice(message: controller.notice, onRestoreSource: onRestoreSource),
          empty,
        ],
      );
    }

    final hints = _hints();
    return LayoutBuilder(
      builder: (context, constraints) {
        final windowClass = MorphicResponsive.classify(MediaQuery.sizeOf(context).width);
        final width = (constraints.maxWidth - MorphicSpace.lg * 2)
            .clamp(0.0, double.infinity)
            .toDouble();
        final columns = MorphicResponsive.workspaceColumns(windowClass, width);
        const gap = MorphicSpace.md;
        final cardWidth = ((width - gap * (columns - 1)) / columns)
            .clamp(0.0, double.infinity)
            .toDouble();
        final header = <Widget>[
          if (controller.degraded)
            DegradedNotice(
              message: controller.notice,
              onRestoreSource: onRestoreSource,
            ),
          GlobalFilterBar(engine: controller),
        ];

        if (layoutEditing) {
          return _editingLayout(
            context,
            header: header,
            components: components,
            hints: hints,
            columns: columns,
            headerMaxHeight: constraints.maxHeight.isFinite ? constraints.maxHeight * 0.4 : 240.0,
          );
        }
        if (focusMode && windowClass == MorphicWindowClass.compact) {
          return _focusedLayout(
            context,
            header: header,
            components: components,
            hints: hints,
            columns: columns,
            width: width,
            cardWidth: cardWidth,
            gap: gap,
          );
        }

        Widget flow(List<Map<String, dynamic>> specs, {Key? key}) => Wrap(
              key: key,
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final spec in specs)
                  _component(
                    spec,
                    hint: hints[_idOf(spec)],
                    defaultSpan: spec['type'] == 'metric_card' ? 1 : columns,
                    columns: columns,
                    width: width,
                    cardWidth: cardWidth,
                    gap: gap,
                  ),
              ],
            );

        final blocks = <Widget>[...header];
        // Normal generated workspaces contain at most six components. Keeping them in one
        // keyed flow preserves local chart/table state across rotation. The schema also accepts
        // larger imported documents (up to 64), so group those into lazy rows rather than
        // launching a query for every off-screen component at once.
        if (components.length <= 6) {
          blocks.add(flow(components, key: const Key('workspace-small-flow')));
        } else {
          var row = <Map<String, dynamic>>[];
          var used = 0;
          void flush() {
            if (row.isEmpty) return;
            blocks.add(flow(row, key: ValueKey('workspace-row-${_idOf(row.first)}')));
            row = <Map<String, dynamic>>[];
            used = 0;
          }

          for (final spec in components) {
            final span = _spanOf(
              hints[_idOf(spec)],
              spec['type'] == 'metric_card' ? 1 : columns,
              columns,
            );
            if (used + span > columns) flush();
            row.add(spec);
            used += span;
          }
          flush();
        }

        return ListView.separated(
          key: const Key('workspace-component-flow'),
          padding: const EdgeInsets.all(MorphicSpace.lg),
          itemCount: blocks.length,
          separatorBuilder: (_, __) => const SizedBox(height: MorphicSpace.md),
          itemBuilder: (_, i) => blocks[i],
        );
      },
    );
  }

  Widget _editingLayout(
    BuildContext context, {
    required List<Widget> header,
    required List<Map<String, dynamic>> components,
    required Map<String, Map<String, dynamic>> hints,
    required int columns,
    required double headerMaxHeight,
  }) {
    Future<void> reorder(int oldIndex, int newIndex) async {
      final id = _idOf(components[oldIndex]);
      if (id.isEmpty) return;
      // onReorderItem already adjusts newIndex for the removed item; do not subtract again.
      final applied =
          await controller.applyCommands([Commands.moveComponent(id, newIndex)]);
      if (applied == null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(controller.error ?? 'Could not reorder this view')),
        );
      }
    }

    Future<void> resize(String id, String value) async {
      final parts = value.split(':');
      final command = parts.first == 'span'
          ? Commands.resizeComponent(id, span: int.parse(parts.last))
          : Commands.resizeComponent(id, height: parts.last);
      final applied = await controller.applyCommands([command]);
      if (applied == null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(controller.error ?? 'Could not resize this view')),
        );
      }
    }

    return Column(
      children: [
        if (header.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: headerMaxHeight),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(MorphicSpace.lg),
                child: Column(children: header),
              ),
            ),
          ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.all(MorphicSpace.lg),
            buildDefaultDragHandles: false,
            itemCount: components.length,
            onReorderItem: (oldIndex, newIndex) =>
                unawaited(reorder(oldIndex, newIndex)),
            itemBuilder: (context, index) {
              final spec = components[index];
              final id = _idOf(spec);
              final hint = hints[id];
              // Show the saved span, even when the current narrow window displays fewer
              // columns. The menu is editing the persisted hint, not today's clamped width.
              final span = (hint?['span'] as num?)?.toInt() ?? _spanOf(hint, 1, columns);
              final heightName = hint?['height'] as String? ?? '';
              final height = heightName.isEmpty ? 'auto' : heightName;
              return Padding(
                key: ValueKey('layout-tile-$id'),
                padding: const EdgeInsets.only(bottom: MorphicSpace.md),
                child: Card(
                  child: ListTile(
                    leading: ReorderableDelayedDragStartListener(
                      key: Key('layout-drag-$id'),
                      index: index,
                      child: const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                    title: Text(spec['title'] as String? ?? id),
                    subtitle: Text('span $span · height $height'),
                    trailing: PopupMenuButton<String>(
                      key: Key('layout-menu-$id'),
                      tooltip: 'Resize',
                      onSelected: (value) => unawaited(resize(id, value)),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'span:1', child: Text('Span 1')),
                        PopupMenuItem(value: 'span:2', child: Text('Span 2')),
                        PopupMenuItem(value: 'span:3', child: Text('Span 3')),
                        PopupMenuItem(value: 'height:small', child: Text('Small height')),
                        PopupMenuItem(value: 'height:medium', child: Text('Medium height')),
                        PopupMenuItem(value: 'height:large', child: Text('Large height')),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _focusedLayout(
    BuildContext context, {
    required List<Widget> header,
    required List<Map<String, dynamic>> components,
    required Map<String, Map<String, dynamic>> hints,
    required int columns,
    required double width,
    required double cardWidth,
    required double gap,
  }) {
    var index = focusIndex;
    if (index < 0) index = 0;
    if (index >= components.length) index = components.length - 1;
    void step(int delta) {
      final next = (index + delta + components.length) % components.length;
      onFocusIndexChanged?.call(next);
    }

    final blocks = <Widget>[
      ...header,
      for (var i = 0; i < components.length; i++)
        if (i == index)
          _component(
            components[i],
            hint: hints[_idOf(components[i])],
            defaultSpan: columns,
            columns: columns,
            width: width,
            cardWidth: cardWidth,
            gap: gap,
          )
        else
          _focusSummary(components[i], i),
    ];
    return Column(
      children: [
        Expanded(
          child: _FocusContent(
            blocks: blocks,
            focusIndex: index,
            activeBlockIndex: header.length + index,
          ),
        ),
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            top: false,
            child: Row(
              key: const Key('focus-controls'),
              children: [
                IconButton(
                  key: const Key('focus-prev-button'),
                  tooltip: 'Previous component',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: onFocusIndexChanged == null ? null : () => step(-1),
                ),
                Expanded(
                  child: Text(
                    '${index + 1} of ${components.length}',
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  key: const Key('focus-next-button'),
                  tooltip: 'Next component',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: onFocusIndexChanged == null ? null : () => step(1),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _focusSummary(Map<String, dynamic> spec, int index) {
    final title = spec['title'] as String? ?? _idOf(spec);
    final explanation = spec['explanation'];
    final detail = explanation is Map ? explanation['detail'] : null;
    final type = spec['type'] as String? ?? 'view';
    final summary = detail is String && detail.trim().isNotEmpty
        ? detail
        : 'View type: ${type.replaceAll('_', ' ')}';
    return Card(
      child: ListTile(
        key: ValueKey('focus-summary-${_idOf(spec)}'),
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onFocusIndexChanged == null ? null : () => onFocusIndexChanged!(index),
      ),
    );
  }

  Widget _component(
    Map<String, dynamic> spec, {
    required Map<String, dynamic>? hint,
    required int defaultSpan,
    required int columns,
    required double width,
    required double cardWidth,
    required double gap,
  }) {
    final span = _spanOf(hint, defaultSpan, columns);
    final spanWidth = cardWidth * span + gap * (span - 1);
    final componentWidth = spanWidth > width ? width : spanWidth;
    final name = hint?['height'] as String? ?? '';
    final component = registry.build(ComponentContext(spec: spec, engine: controller));
    final clock = entrance;
    final index = controller.components.indexWhere((item) => _idOf(item) == _idOf(spec));
    return SizedBox(
      key: ValueKey('workspace-component-${_idOf(spec)}'),
      width: componentWidth,
      height: _layoutHeights[name],
      child: clock == null
          ? component
          : MorphicEntrance(animation: clock, index: index, child: component),
    );
  }

  int _spanOf(Map<String, dynamic>? hint, int defaultSpan, int columns) {
    final raw = (hint?['span'] as num?)?.toInt() ?? defaultSpan;
    if (raw < 1) return 1;
    return raw > columns ? columns : raw;
  }

  String _idOf(Map<String, dynamic> spec) =>
      spec['id'] as String? ?? spec['type'] as String? ?? '';
}

/// Only the selected view is mounted; the remaining children are inexpensive summaries. Keep
/// them in one scrollable so selecting a summary or using Next can reveal the newly expanded
/// view even when it was previously far below the fold.
class _FocusContent extends StatefulWidget {
  const _FocusContent({
    required this.blocks,
    required this.focusIndex,
    required this.activeBlockIndex,
  });

  final List<Widget> blocks;
  final int focusIndex;
  final int activeBlockIndex;

  @override
  State<_FocusContent> createState() => _FocusContentState();
}

class _FocusContentState extends State<_FocusContent> {
  final GlobalKey _active = GlobalKey();

  @override
  void initState() {
    super.initState();
    _revealActive();
  }

  @override
  void didUpdateWidget(_FocusContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusIndex != oldWidget.focusIndex) _revealActive();
  }

  void _revealActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final active = _active.currentContext;
      if (!mounted || active == null) return;
      final viewBox = context.findRenderObject();
      final activeBox = active.findRenderObject();
      if (viewBox is RenderBox && activeBox is RenderBox && viewBox.hasSize && activeBox.hasSize) {
        final viewTop = viewBox.localToGlobal(Offset.zero).dy;
        final activeTop = activeBox.localToGlobal(Offset.zero).dy;
        final fullyVisible = activeTop >= viewTop &&
            activeTop + activeBox.size.height <= viewTop + viewBox.size.height;
        if (fullyVisible) return;
      }
      final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : MorphicMotion.standard;
      unawaited(Scrollable.ensureVisible(active, duration: duration));
    });
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        key: const Key('focus-content'),
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.blocks.length; i++) ...[
              if (i > 0) const SizedBox(height: MorphicSpace.md),
              if (i == widget.activeBlockIndex)
                KeyedSubtree(key: _active, child: widget.blocks[i])
              else
                widget.blocks[i],
            ],
          ],
        ),
      );
}

/// Shown when a workspace reopened without its source data. The engine's wording is used
/// verbatim so the UI never guesses at a cause.
class DegradedNotice extends StatelessWidget {
  const DegradedNotice({super.key, this.message, this.onRestoreSource});

  final String? message;
  final VoidCallback? onRestoreSource;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MorphicSpace.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(MorphicRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: MorphicSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message ?? 'This workspace opened without its source data.',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onErrorContainer),
                ),
                if (onRestoreSource != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('restore-source-notice-button'),
                      onPressed: onRestoreSource,
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('Restore source file'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
