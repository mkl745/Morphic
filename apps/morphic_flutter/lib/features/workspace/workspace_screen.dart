import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../../engine/engine_controller.dart';
import '../../runtime/component_registry.dart';
import '../../runtime/workspace_view.dart';

/// Workspace host.
///
/// With an [EngineController] it renders the **live runtime** (task 1.1.5): real values,
/// engine-driven paging, explicit loading/empty/error states. Without one it falls back to
/// the Phase 0 *structural* view, which shows the generated document and its explanations —
/// still useful for inspecting a saved document, and kept so existing callers keep working.
class WorkspaceScreen extends StatelessWidget {
  const WorkspaceScreen({
    super.key,
    this.document,
    this.controller,
    this.registry,
  });

  /// Optional injected document (structural view / tests); otherwise read from route args.
  final Map<String, dynamic>? document;

  /// When present, the interactive runtime is used instead of the structural view.
  final EngineController? controller;
  final ComponentRegistry? registry;

  @override
  Widget build(BuildContext context) {
    final ctl = controller;
    if (ctl != null) {
      final ws = ctl.doc?['workspace'] as Map<String, dynamic>?;
      return Scaffold(
        appBar: AppBar(title: Text(ws?['title'] as String? ?? 'Workspace')),
        body: WorkspaceView(
          controller: ctl,
          registry: registry ?? ComponentRegistry(),
          onRetry: ctl.workspaceId == null
              ? null
              : () => ctl.open(ctl.workspaceId!),
        ),
      );
    }

    final doc =
        document ?? ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    final ws = doc?['workspace'] as Map<String, dynamic>?;
    final components = (ws?['components'] as List? ?? []).cast<Map<String, dynamic>>();

    return Scaffold(
      appBar: AppBar(title: Text(ws?['title'] as String? ?? 'Workspace')),
      body: ws == null
          ? const Center(child: Text('No workspace document.'))
          : ListView(
              padding: const EdgeInsets.all(MorphicSpace.lg),
              children: [
                Text(
                  'Generated workspace · revision ${ws['revision']}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: MorphicSpace.lg),
                for (final c in components) _ComponentCard(component: c),
                const SizedBox(height: MorphicSpace.lg),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(MorphicSpace.lg),
                    child: Text(
                      'This workspace was compiled by the Rust engine from your data and '
                      'saved to disk. Reopen it from Home to verify persistence.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ComponentCard extends StatelessWidget {
  const _ComponentCard({required this.component});
  final Map<String, dynamic> component;

  IconData _icon(String type) {
    switch (type) {
      case 'metric_card':
        return Icons.tag;
      case 'data_table':
        return Icons.table_chart_outlined;
      case 'bar_chart':
        return Icons.bar_chart;
      case 'line_chart':
        return Icons.show_chart;
      case 'timeline':
        return Icons.timeline;
      default:
        return Icons.widgets_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = component['type'] as String? ?? '?';
    final title = component['title'] as String? ?? type;
    final explanation = component['explanation'] as Map<String, dynamic>?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_icon(type), color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: MorphicSpace.md),
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleSmall),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: MorphicSpace.sm, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(MorphicRadius.sm),
                    border: Border.all(color: MorphicColors.borderDark),
                  ),
                  child: Text(type, style: Theme.of(context).textTheme.labelSmall),
                ),
              ],
            ),
            if (explanation != null) ...[
              const SizedBox(height: MorphicSpace.sm),
              Text(
                explanation['detail'] as String? ?? '',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
