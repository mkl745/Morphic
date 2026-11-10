import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../../engine/engine_controller.dart';
import '../../runtime/component_registry.dart';
import '../../runtime/explanation_sheet.dart';
import '../../runtime/workspace_view.dart';
import 'perf_probe_screen.dart';
import 'workspace_args.dart';

/// Workspace host.
///
/// With an [EngineController] it renders the **live runtime** (task 1.1.5): real values,
/// engine-driven paging, explicit loading/empty/error states. Without one it falls back to
/// the Phase 0 *structural* view, which shows the generated document and its explanations —
/// still useful for inspecting a saved document, and kept so existing callers keep working.
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    this.document,
    this.controller,
    this.registry,
    this.warnings = const [],
  });

  /// Optional injected document (structural view / tests); otherwise read from route args.
  final Map<String, dynamic>? document;

  /// When present, the interactive runtime is used instead of the structural view.
  final EngineController? controller;
  final ComponentRegistry? registry;

  /// Ingest warnings carried over from the import, surfaced rather than discarded.
  final List<String> warnings;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  bool _editingLayout = false;
  bool _focusMode = false;
  int _focusIndex = 0;

  @override
  Widget build(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final argsObj = args is WorkspaceArgs ? args : null;
    final ctl = widget.controller ?? argsObj?.controller;
    final notices = widget.warnings.isNotEmpty
        ? widget.warnings
        : (argsObj?.warnings ?? const []);

    if (ctl != null) {
      // The whole scaffold listens: the app bar's enabled state and tooltips come from the
      // engine's undo/redo depths, not from a Dart-side guess about what changed.
      return AnimatedBuilder(
        animation: ctl,
        builder: (context, _) {
          final ws = ctl.doc?['workspace'] as Map<String, dynamic>?;
          final phone = MediaQuery.sizeOf(context).width < 640;
          return Scaffold(
            appBar: AppBar(
              title: Text(ws?['title'] as String? ?? 'Workspace'),
              actions: [
                _historyButton(context, ctl, undo: true),
                _historyButton(context, ctl, undo: false),
                IconButton(
                  key: const Key('layout-edit-button'),
                  tooltip:
                      _editingLayout ? 'Finish layout editing' : 'Edit layout',
                  icon: Icon(_editingLayout ? Icons.check : Icons.tune),
                  onPressed: () => setState(() {
                    _editingLayout = !_editingLayout;
                    if (_editingLayout) _focusMode = false;
                  }),
                ),
                if (phone)
                  IconButton(
                    key: const Key('focus-mode-button'),
                    tooltip:
                        _focusMode ? 'Show all components' : 'Focus one component',
                    icon: Icon(_focusMode ? Icons.view_list : Icons.filter_center_focus),
                    onPressed: () => setState(() {
                      _focusMode = !_focusMode;
                      _editingLayout = false;
                      _focusIndex = 0;
                    }),
                  ),
                // AT-07's measurement has to be runnable on the phone that is being judged, in
                // the build the harness installs. Tucking it here keeps it one tap from the data
                // it measures without putting a benchmark in the user's face.
                IconButton(
                  tooltip: 'Performance probe',
                  icon: const Icon(Icons.speed),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PerfProbeScreen(controller: ctl),
                    ),
                  ),
                ),
              ],
            ),
            body: Column(
              children: [
                if (notices.isNotEmpty) _WarningBanner(warnings: notices),
                Expanded(
                  child: WorkspaceView(
                    controller: ctl,
                    registry: widget.registry ?? ComponentRegistry(),
                    onRetry: ctl.workspaceId == null
                        ? null
                        : () => ctl.open(ctl.workspaceId!),
                    layoutEditing: _editingLayout,
                    focusMode: _focusMode,
                    focusIndex: _focusIndex,
                    onFocusIndexChanged: (index) =>
                        setState(() => _focusIndex = index),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    final doc = widget.document ??
        argsObj?.document ??
        (args is Map<String, dynamic> ? args : null);
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

  /// Engine-owned undo/redo control. Disabled when Rust says the depth is zero; the label
  /// and result come back with the response so Dart never invents what was undone.
  Widget _historyButton(
    BuildContext context,
    EngineController ctl, {
    required bool undo,
  }) {
    final depth = undo ? ctl.undoDepth : ctl.redoDepth;
    final label = undo ? ctl.undoLabel : ctl.redoLabel;
    final nothing = undo ? 'Nothing to undo' : 'Nothing to redo';
    final fallback = undo ? 'Undo complete' : 'Redo complete';
    return IconButton(
      key: Key(undo ? 'undo-button' : 'redo-button'),
      tooltip: depth == 0 ? nothing : '${undo ? 'Undo' : 'Redo'} $label',
      icon: Icon(undo ? Icons.undo : Icons.redo),
      onPressed: depth == 0
          ? null
          : () async {
              final res = undo ? await ctl.undo() : await ctl.redo();
              if (!context.mounted) return;
              final text = res == null
                  ? (ctl.error ?? fallback)
                  : (res['label'] as String? ?? fallback);
              final messenger = ScaffoldMessenger.of(context);
              messenger.hideCurrentSnackBar();
              messenger.showSnackBar(
                SnackBar(
                  key: Key(undo ? 'undo-snackbar' : 'redo-snackbar'),
                  content: Text(text),
                ),
              );
            },
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
    final id = component['id'] as String? ?? type;
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
                ExplanationButton(
                  id: id,
                  title: title,
                  explanation: explanation,
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

/// Ingest warnings are part of the result, not noise: an encoding fallback or an ambiguous
/// date column changes what the numbers mean, so the user is told.
class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: MorphicColors.warning.withValues(alpha: 0.14),
      padding: const EdgeInsets.all(MorphicSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: MorphicColors.warning),
          const SizedBox(width: MorphicSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Import notes (${warnings.length})',
                  style: theme.textTheme.labelMedium,
                ),
                for (final w in warnings.take(5))
                  Text('• $w', style: theme.textTheme.bodySmall),
                if (warnings.length > 5)
                  Text('and ${warnings.length - 5} more…',
                      style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
