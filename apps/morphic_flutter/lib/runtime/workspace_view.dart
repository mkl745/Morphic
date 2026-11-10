/// Adaptive workspace renderer (M1.1 task 1.1.5).
///
/// Draws the generated document in `layout.order` through the [ComponentRegistry]. Metric
/// cards flow into columns on wide viewports; everything else spans the full width. The
/// order the engine chose is never re-sorted here. M1.5 task 1.5.2 adds an edit mode whose
/// drag-reorder and pinch-free resize menu are *commands*: the rendered geometry always comes
/// back from `layout.order` and `layout.hints`, never from a Dart-side layout guess.
library;

import 'dart:async';

import 'package:flutter/material.dart';

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
    this.onRetry,
    this.layoutEditing = false,
    this.focusMode = false,
    this.focusIndex = 0,
    this.onFocusIndexChanged,
  });

  final EngineController controller;
  final ComponentRegistry registry;
  final VoidCallback? onRetry;

  /// App-bar-owned layout editing mode. Off by default so the 54 component goldens and the
  /// existing runtime tests see the exact widget tree they did before 1.5.2.
  final bool layoutEditing;

  /// Phone-only focus mode shows one component at a time. It is a view convenience, not
  /// persisted schema state; layout edits themselves are persisted by Rust as commands.
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
                if (onRetry != null) ...[
                  const SizedBox(height: MorphicSpace.md),
                  FilledButton(onPressed: onRetry, child: const Text('Retry')),
                ],
              ],
            ),
          ),
        );
      }
      return Center(
        child: Text('No workspace open.', style: theme.textTheme.bodySmall),
      );
    }

    final components = controller.components;
    if (components.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(MorphicSpace.xl),
          child: Text(
            'The engine generated no components for this file.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }

    final hints = _hints();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - MorphicSpace.lg * 2;
        final columns = width >= 1000 ? 3 : (width >= 640 ? 2 : 1);
        const gap = MorphicSpace.md;
        final cardWidth = (width - gap * (columns - 1)) / columns;
        final header = <Widget>[
          if (controller.degraded) DegradedNotice(message: controller.notice),
          GlobalFilterBar(engine: controller),
        ];

        if (layoutEditing) {
          return _editingLayout(
            context,
            header: header,
            components: components,
            hints: hints,
            columns: columns,
          );
        }
        if (focusMode && MediaQuery.sizeOf(context).width < 640) {
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

        // Group *consecutive* metric cards so they can flow, without reordering anything.
        final blocks = <Widget>[];
        var metrics = <Map<String, dynamic>>[];

        // Degraded mode: the layout is real, the data is gone. Lead with that so an empty
        // table is not mistaken for a broken import (docs/architecture/06 §3).
        blocks.addAll(header);

        void flushMetrics() {
          if (metrics.isEmpty) return;
          blocks.add(
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final spec in metrics)
                  _component(
                    spec,
                    hint: hints[_idOf(spec)],
                    defaultSpan: 1,
                    columns: columns,
                    width: width,
                    cardWidth: cardWidth,
                    gap: gap,
                  ),
              ],
            ),
          );
          metrics = [];
        }

        for (final spec in components) {
          if (spec['type'] == 'metric_card') {
            metrics.add(spec);
          } else {
            flushMetrics();
            blocks.add(
              _component(
                spec,
                hint: hints[_idOf(spec)],
                defaultSpan: columns,
                columns: columns,
                width: width,
                cardWidth: cardWidth,
                gap: gap,
              ),
            );
          }
        }
        flushMetrics();

        return ListView.separated(
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
          Padding(
            padding: const EdgeInsets.all(MorphicSpace.lg),
            child: Column(children: header),
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
              final span = _spanOf(hint, 1, columns);
              final heightName = hint?['height'] as String? ?? '';
              final height = heightName.isEmpty ? 'auto' : heightName;
              return Padding(
                key: ValueKey('layout-tile-$id'),
                padding: const EdgeInsets.only(bottom: MorphicSpace.md),
                child: Card(
                  child: ListTile(
                    leading: ReorderableDragStartListener(
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

    final spec = components[index];
    return Column(
      children: [
        if (header.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(MorphicSpace.lg),
            child: Column(children: header),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MorphicSpace.lg),
          child: Row(
            children: [
              IconButton(
                key: const Key('focus-prev-button'),
                tooltip: 'Previous component',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => step(-1),
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
                onPressed: () => step(1),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(MorphicSpace.lg),
            child: _component(
              spec,
              hint: hints[_idOf(spec)],
              defaultSpan: columns,
              columns: columns,
              width: width,
              cardWidth: cardWidth,
              gap: gap,
            ),
          ),
        ),
      ],
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
    return SizedBox(
      width: componentWidth,
      height: _layoutHeights[name],
      child: registry.build(ComponentContext(spec: spec, engine: controller)),
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

/// Shown when a workspace reopened without its source data. The engine's wording is used
/// verbatim so the UI never guesses at a cause.
class DegradedNotice extends StatelessWidget {
  const DegradedNotice({super.key, this.message});

  final String? message;

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
            child: Text(
              message ?? 'This workspace opened without its source data.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
