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
        final gap = MorphicSpace.md;
        final cardWidth = (width - gap * (columns - 1)) / columns;

        // Group *consecutive* metric cards so they can flow, without reordering anything.
        final blocks = <Widget>[];
        var metrics = <Map<String, dynamic>>[];

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
