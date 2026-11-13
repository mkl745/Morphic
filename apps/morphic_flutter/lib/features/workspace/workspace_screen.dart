import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design_system/copy.dart';
import '../../design_system/responsive.dart';
import '../../design_system/tokens.dart';
import '../../engine/autosave.dart';
import '../../engine/engine_controller.dart';
import '../../engine/file_source.dart';
import '../../engine/interaction.dart';
import '../../runtime/component_registry.dart';
import '../../runtime/explanation_sheet.dart';
import '../../runtime/responsive_detail.dart';
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
  final GlobalKey _detailAnchor = GlobalKey();
  WorkspaceDetailBuilder? _detail;
  WorkspaceDetailBuilder? _detailBottom;
  int? _detailRevision;
  String? _detailWorkspaceId;
  MorphicWindowClass? _lastWindowClass;
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
    final args = ModalRoute.of(context)?.settings.arguments;
    final nextClass = MorphicResponsive.classify(MediaQuery.sizeOf(context).width);
    final selected = _detail;
    if (_lastWindowClass == MorphicWindowClass.expanded &&
        nextClass != MorphicWindowClass.expanded &&
        selected != null) {
      final bottom = _detailBottom;
      final revision = _detailRevision;
      final workspaceId = _detailWorkspaceId;
      final ctl = widget.controller ?? (args is WorkspaceArgs ? args.controller : null);
      _detail = null;
      _detailBottom = null;
      _detailRevision = null;
      _detailWorkspaceId = null;
      // The anchor receives its new scope during this frame. Reopen afterwards, but only
      // if the selected data still belongs to the current engine revision/workspace.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ctl == null || ctl.revision != revision || ctl.workspaceId != workspaceId) {
          return;
        }
        _reopenDetail(selected, bottom);
      });
    }
    _lastWindowClass = nextClass;
    if (_entranceStarted) return;
    _entranceStarted = true;
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
          final windowWidth = MediaQuery.sizeOf(context).width;
          final windowClass = MorphicResponsive.classify(windowWidth);
          final compact = windowClass == MorphicWindowClass.compact;
          // A short landscape phone has room horizontally for the controls but precious
          // vertical space. Narrow portrait windows get a second row to protect the title.
          final compactControlsRow = compact && windowWidth < 480;
          final scopeRevision = ctl.revision;
          final scopeWorkspaceId = ctl.workspaceId;
          final controls = <Widget>[
            _historyButton(context, ctl, undo: true),
            _historyButton(context, ctl, undo: false),
            // Compact chrome normally has the restore action in the notice. If the
            // document is absent, retain the app-bar action as a recovery fallback.
            if (ctl.degraded && (!compact || ctl.doc == null))
              IconButton(
                key: const Key('restore-source-button'),
                tooltip: 'Restore source file',
                icon: const Icon(Icons.link),
                onPressed: () => _restoreSource(context, ctl),
              ),
            IconButton(
              key: const Key('layout-edit-button'),
              tooltip: _editingLayout ? 'Finish layout editing' : 'Edit layout',
              icon: Icon(_editingLayout ? Icons.check : Icons.tune),
              onPressed: () => setState(() {
                _editingLayout = !_editingLayout;
                if (_editingLayout) _focusMode = false;
              }),
            ),
            if (compact)
              IconButton(
                key: const Key('focus-mode-button'),
                tooltip: _focusMode ? 'Show all components' : 'Focus one component',
                icon: Icon(_focusMode ? Icons.view_list : Icons.filter_center_focus),
                onPressed: () => setState(() {
                  _focusMode = !_focusMode;
                  _editingLayout = false;
                  _focusIndex = 0;
                }),
              ),
          ];
          final detail = _detailRevision == ctl.revision &&
                  _detailWorkspaceId == ctl.workspaceId
              ? _detail
              : null;
          return Scaffold(
            appBar: AppBar(
              title: ws == null || ctl.workspaceId == null
                  ? const Text('Workspace')
                  : _WorkspaceTitle(
                      title: ws['title'] as String? ?? 'Workspace',
                      onRename: () => _renameWorkspace(context, ctl),
                    ),
              actions: [
                if (!compactControlsRow) ...controls,
                // The device harness finds this action by its tooltip; keep it directly
                // reachable in the app bar even when compact controls get a second row.
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
              bottom: compactControlsRow
                  ? PreferredSize(
                      preferredSize: const Size.fromHeight(kMinInteractiveDimension),
                      child: Row(
                        key: const Key('compact-workspace-controls'),
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: controls,
                      ),
                    )
                  : null,
            ),
            body: WorkspaceDetailScope(
              windowClass: windowClass,
              openInRail: (builder, bottom) => _showDetail(ctl, builder, bottom),
              reopen: (builder, bottom) {
                if (ctl.revision == scopeRevision && ctl.workspaceId == scopeWorkspaceId) {
                  _reopenDetail(builder, bottom);
                }
              },
              child: Builder(
                key: _detailAnchor,
                builder: (context) => Column(
                  children: [
                    if (ws != null) _WorkspaceSaveStatus(pendingCheckpoint: ctl.dirty),
                    if (notices.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * 0.25,
                        ),
                        child: SingleChildScrollView(
                          key: const Key('workspace-import-notices'),
                          child: _WarningBanner(warnings: notices),
                        ),
                      ),
                    Expanded(
                      child: Row(
                        children: [
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
                          if (windowClass == MorphicWindowClass.expanded)
                            _WorkspaceDetailRail(
                              width: MorphicResponsive.railWidth(windowWidth),
                              detail: detail,
                              onClose: _closeDetail,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
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

  void _showDetail(
    EngineController ctl,
    WorkspaceDetailBuilder builder,
    WorkspaceDetailBuilder? bottomBuilder,
  ) {
    setState(() {
      _detail = builder;
      _detailBottom = bottomBuilder;
      _detailRevision = ctl.revision;
      _detailWorkspaceId = ctl.workspaceId;
    });
  }

  void _reopenDetail(WorkspaceDetailBuilder builder, WorkspaceDetailBuilder? bottomBuilder) {
    final anchor = _detailAnchor.currentContext;
    if (!mounted || anchor == null) return;
    unawaited(showWorkspaceDetail(anchor, builder: builder, bottomBuilder: bottomBuilder));
  }

  void _closeDetail() {
    setState(() {
      _detail = null;
      _detailBottom = null;
      _detailRevision = null;
      _detailWorkspaceId = null;
    });
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

/// A persistent, independently scrollable inspection surface on expanded windows. Detail
/// content is bound to the engine revision that produced it, so a filter, undo or type change
/// cannot leave old row values or explanations presented as current.
class _WorkspaceDetailRail extends StatelessWidget {
  const _WorkspaceDetailRail({
    required this.width,
    required this.detail,
    required this.onClose,
  });

  final double width;
  final WorkspaceDetailBuilder? detail;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('workspace-detail-rail'),
      width: width,
      height: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: BorderDirectional(start: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: detail == null
          ? SingleChildScrollView(
              padding: const EdgeInsets.all(MorphicSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Details', style: theme.textTheme.titleSmall),
                  const SizedBox(height: MorphicSpace.sm),
                  Text(
                    'Choose a view’s information or table button, or a data row, to inspect it here.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            )
          : Builder(builder: (context) => detail!(context, onClose)),
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
