import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';

/// Phase 0 workspace view: renders the *generated* workspace document's structure and
/// the engine's explanations. The full interactive component runtime (tables, charts,
/// timelines) is M1.1–M1.4; here we prove the schema was generated and persisted.
class WorkspaceScreen extends StatelessWidget {
  const WorkspaceScreen({super.key, this.document});

  /// Optional injected document (used by tests); otherwise read from route arguments.
  final Map<String, dynamic>? document;

  @override
  Widget build(BuildContext context) {
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
