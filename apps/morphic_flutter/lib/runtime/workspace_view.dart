/// Adaptive workspace renderer (M1.1 task 1.1.5).
///
/// Draws the generated document in `layout.order` through the [ComponentRegistry]. Metric
/// cards flow into columns on wide viewports; everything else spans the full width. The
/// order the engine chose is never re-sorted here.
library;

import 'package:flutter/material.dart';

import '../design_system/tokens.dart';
import '../engine/engine_controller.dart';
import 'component_registry.dart';
import 'global_filter_bar.dart';

class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.controller,
    required this.registry,
    this.onRetry,
  });

  final EngineController controller;
  final ComponentRegistry registry;
  final VoidCallback? onRetry;

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

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - MorphicSpace.lg * 2;
        final columns = width >= 1000 ? 3 : (width >= 640 ? 2 : 1);
        const gap = MorphicSpace.md;
        final cardWidth = (width - gap * (columns - 1)) / columns;

        // Group *consecutive* metric cards so they can flow, without reordering anything.
        final blocks = <Widget>[];
        var metrics = <Map<String, dynamic>>[];

        // Degraded mode: the layout is real, the data is gone. Lead with that so an empty
        // table is not mistaken for a broken import (docs/architecture/06 §3).
        if (controller.degraded) {
          blocks.add(DegradedNotice(message: controller.notice));
        }

        // The workspace filter bar sits above every component, because what it sets applies
        // to every component. It is part of the scroll view rather than pinned: on a phone
        // a pinned bar plus a table header would leave very little room for rows.
        blocks.add(GlobalFilterBar(engine: controller));

        void flushMetrics() {
          if (metrics.isEmpty) return;
          blocks.add(
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final spec in metrics)
                  SizedBox(
                    width: cardWidth,
                    child: registry.build(
                      ComponentContext(spec: spec, engine: controller),
                    ),
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
              registry.build(ComponentContext(spec: spec, engine: controller)),
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
