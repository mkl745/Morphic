import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design_system/copy.dart';
import '../../design_system/tokens.dart';
import '../../engine/autosave.dart';
import '../../engine/engine_controller.dart';
import '../../engine/file_source.dart';
import '../../engine/interaction.dart';
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
    this.fileSource,
    this.animateEntrance = false,
  });

  /// Optional injected document (structural view / tests); otherwise read from route args.
  final Map<String, dynamic>? document;

  /// When present, the interactive runtime is used instead of the structural view.
  final EngineController? controller;
  final ComponentRegistry? registry;

  /// Ingest warnings carried over from the import, surfaced rather than discarded.
  final List<String> warnings;

  /// Injectable picker for the degraded-mode "Restore source file" action.
  final PlatformFileSource? fileSource;

  /// Used by direct hosts/tests; route-based imports use [WorkspaceArgs.animateEntrance].
  final bool animateEntrance;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with SingleTickerProviderStateMixin {
  bool _editingLayout = false;
  bool _focusMode = false;
  int _focusIndex = 0;
  late final AnimationController _entrance;
  bool _entranceStarted = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: MorphicMotion.entranceLimit,
      // Reduced motion still uses opacity; the child removes translation and stagger.
      animationBehavior: AnimationBehavior.preserve,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceStarted) return;
    _entranceStarted = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (widget.animateEntrance || (args is WorkspaceArgs && args.animateEntrance)) {
      _entrance.forward();
    } else {
      _entrance.value = 1;
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final argsObj = args is WorkspaceArgs ? args : null;
    final ctl = widget.controller ?? argsObj?.controller;
    // Bind the app-level checkpoint timer to the open controller. Idempotent and does not
    // notify listeners, so calling it from build is safe (M1.5 task 1.5.4).
    AutosaveScope.of(context)?.watch(ctl);
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
              title: ws == null || ctl.workspaceId == null
                  ? const Text('Workspace')
                  : _WorkspaceTitle(
                      title: ws['title'] as String? ?? 'Workspace',
                      onRename: () => _renameWorkspace(context, ctl),
                    ),
              actions: [
                _historyButton(context, ctl, undo: true),
                _historyButton(context, ctl, undo: false),
                // AT-16: degraded mode must offer a recovery action, not just an explanation.
                // The engine verifies the picked bytes against the document's dataset hash.
                // Compact chrome normally has a restore action in the notice; omit the
                // duplicate so the title is not squeezed out. If the document is absent,
                // the notice cannot be shown, so keep this fallback action available.
                if (ctl.degraded && (!phone || ctl.doc == null))
                  IconButton(
                    key: const Key('restore-source-button'),
                    tooltip: 'Restore source file',
                    icon: const Icon(Icons.link),
                    onPressed: () => _restoreSource(context, ctl),
                  ),
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
                if (ws != null) _WorkspaceSaveStatus(pendingCheckpoint: ctl.dirty),
                if (notices.isNotEmpty) _WarningBanner(warnings: notices),
                Expanded(
                  child: WorkspaceView(
                    controller: ctl,
                    registry: widget.registry ?? ComponentRegistry(),
                    entrance: _entrance,
                    onRetry: ctl.workspaceId == null
                        ? null
                        : () => ctl.open(ctl.workspaceId!),
                    onRestoreSource: ctl.degraded
                        ? () => _restoreSource(context, ctl)
                        : null,
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
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(MorphicSpace.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('No workspace document.'),
                    const SizedBox(height: MorphicSpace.sm),
                    Text(
                      MorphicCopy.noWorkspaceDocumentDetail,
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
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

  /// Rename as an ordinary engine command. The library rename API closes the live session
  /// and resets its history, so it must not be used from this screen.
  Future<void> _renameWorkspace(BuildContext context, EngineController ctl) async {
    final current = (ctl.doc?['workspace'] as Map?)?['title'] as String? ?? 'Workspace';
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameWorkspaceDialog(current: current),
    );
    if (!context.mounted || title == null) return;
    final result = await ctl.applyCommands([Commands.renameWorkspace(title)]);
    if (!context.mounted || result != null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not rename workspace: ${ctl.error ?? 'Try again.'}')),
    );
  }

  /// Re-link a degraded workspace to its original source bytes, then reopen so the table,
  /// profile and metrics are rehydrated. A different file is refused by Rust, and that error
  /// is shown rather than leaving the user guessing.
  Future<void> _restoreSource(BuildContext context, EngineController ctl) async {
    final messenger = ScaffoldMessenger.of(context);
    final id = ctl.workspaceId;
    if (id == null) return;
    try {
      final picked = await (widget.fileSource ?? const FilePickerSource()).pick();
      if (picked == null) return; // cancelled, not an error
      final Uint8List bytes =
          picked.bytes ?? await File(picked.path!).readAsBytes();
      ctl.bridge.relinkWorkspace(
        bytes: bytes,
        storageRoot: ctl.storageRoot,
        workspaceId: id,
      );
      await ctl.open(id);
      messenger.showSnackBar(
        const SnackBar(content: Text('Source data restored')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not restore source: $e')),
      );
    }
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

class _WorkspaceTitle extends StatelessWidget {
  const _WorkspaceTitle({required this.title, required this.onRename});
  final String title;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => Tooltip(
          message: 'Rename workspace',
          child: InkWell(
            key: const Key('workspace-rename'),
            onTap: onRename,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  // Leave room for an ellipsis as well as the 16 dp edit affordance.
                  if (constraints.maxWidth >=
                      MorphicSpace.lg + MorphicSpace.xs + MorphicSpace.sm) ...[
                    const SizedBox(width: MorphicSpace.xs),
                    const Icon(Icons.edit_outlined, size: 16),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}

class _WorkspaceSaveStatus extends StatelessWidget {
  const _WorkspaceSaveStatus({required this.pendingCheckpoint});
  final bool pendingCheckpoint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MorphicSpace.lg,
          vertical: MorphicSpace.xs,
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: MorphicSpace.sm),
            Expanded(
              child: Text(
                pendingCheckpoint ? 'Saved locally · checkpoint pending' : 'Saved locally',
                key: const Key('workspace-save-status'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RenameWorkspaceDialog extends StatefulWidget {
  const _RenameWorkspaceDialog({required this.current});
  final String current;

  @override
  State<_RenameWorkspaceDialog> createState() => _RenameWorkspaceDialogState();
}

class _RenameWorkspaceDialogState extends State<_RenameWorkspaceDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.current);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _controller.text.trim();
    if (title.isNotEmpty) Navigator.of(context).pop(title);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Rename workspace'),
        content: TextField(
          key: const Key('workspace-title-input'),
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('workspace-title-save'),
            onPressed: _controller.text.trim().isEmpty ? null : _submit,
            child: const Text('Save'),
          ),
        ],
      );
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
                    border: Border.all(color: Theme.of(context).colorScheme.outline),
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
          Icon(Icons.info_outline,
              size: 18, color: MorphicColors.warningText(theme.brightness)),
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
