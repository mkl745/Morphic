import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../../engine/bridge.dart';
import '../../engine/bridge_scope.dart';
import '../../engine/bundle_location.dart';
import '../../engine/engine_controller.dart';
import '../../engine/file_source.dart';
import '../../engine/sample_import.dart';
import '../../engine/sample_source.dart';
import '../workspace/workspace_args.dart';

/// Home is a lightweight gateway (spec §10.1): engine status, the import/PoC action,
/// and recent workspaces. The workspace itself is the product, not this screen.
///
/// M1.5 task 1.5.3 adds the library lifecycle: each row has a menu for rename, duplicate,
/// delete and re-linking a degraded source. M1.5 task 1.5.6 adds `.morphic` bundle
/// export/import. Every action goes through the Rust bridge — Dart never edits the library
/// index or the document itself.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.fileSource,
    this.bundlePathResolver,
    this.bundleWriter,
    this.sampleLauncher,
  });

  /// Injectable so widget tests can exercise "re-link" and bundle import without the
  /// platform file picker.
  final PlatformFileSource? fileSource;

  /// Injectable so widget tests can exercise bundle export without `path_provider`.
  final BundlePathResolver? bundlePathResolver;

  /// Injectable so widget tests never wait on real disk I/O inside the fake-async test zone.
  final BundleWriter? bundleWriter;

  /// Shared bundled-sample path; injected in widget tests, built from the engine in production.
  final SampleLauncher? sampleLauncher;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<EngineInfo>? _engineInfo;
  Future<List<dynamic>>? _workspaces;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final scope = BridgeScope.of(context);
      _engineInfo = Future(() => scope.bridge.engineInfo());
      _workspaces = Future(() => scope.bridge.listWorkspaces(scope.storageRoot));
    }
  }

  void _reloadWorkspaces() {
    final scope = BridgeScope.of(context);
    setState(() {
      _workspaces = Future(() => scope.bridge.listWorkspaces(scope.storageRoot));
    });
  }

  void _reloadEngine() {
    final scope = BridgeScope.of(context);
    setState(() {
      _engineInfo = Future(() => scope.bridge.engineInfo());
    });
  }

  /// Import a `.morphic` bundle picked by the user. Rust verifies the manifest and every
  /// dataset hash; Dart only chooses the file and reports the outcome.
  Future<void> _importBundle(BuildContext context) async {
    final scope = BridgeScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final source = widget.fileSource ?? const FilePickerSource();
    String message;
    var imported = false;
    try {
      final picked = await source.pickBundle();
      if (picked == null) return; // cancelled, not an error
      final bytes = await _readBundleBytes(picked);
      final now = DateTime.now().toUtc();
      scope.bridge.importBundle(
        bytes: bytes,
        storageRoot: scope.storageRoot,
        workspaceId: 'w_${now.microsecondsSinceEpoch}',
        title: _bundleTitle(picked.name),
        nowIso: now.toIso8601String(),
      );
      message = 'Imported ${_bundleTitle(picked.name)}';
      imported = true;
    } catch (e) {
      message = 'Could not import bundle: $e';
    }
    if (!context.mounted) return;
    if (imported) _reloadWorkspaces();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<Uint8List> _readBundleBytes(PickedFile file) async {
    final bytes = file.bytes;
    if (bytes != null) return bytes;
    final path = file.path;
    if (path == null) {
      throw const FileSelectionException('the bundle picker returned nothing readable');
    }
    return File(path).readAsBytes();
  }

  String _bundleTitle(String name) {
    const suffix = '.morphic';
    return name.toLowerCase().endsWith(suffix) && name.length > suffix.length
        ? name.substring(0, name.length - suffix.length)
        : name;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MORPHIC'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        children: [
          Text(
            'Your Data. Your Interface.',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: MorphicColors.textSecondaryDark),
          ),
          const SizedBox(height: MorphicSpace.lg),
          _EngineStatusCard(future: _engineInfo, onRetry: _reloadEngine),
          const SizedBox(height: MorphicSpace.lg),
          FilledButton.icon(
            onPressed: () async {
              await Navigator.of(context).pushNamed('/import');
              _reloadWorkspaces();
            },
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Import a file'),
          ),
          const SizedBox(height: MorphicSpace.sm),
          OutlinedButton.icon(
            onPressed: () async {
              await Navigator.of(context).pushNamed('/poc');
              _reloadWorkspaces();
            },
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Run proof of concept'),
          ),
          const SizedBox(height: MorphicSpace.sm),
          OutlinedButton.icon(
            key: const Key('import-bundle-button'),
            onPressed: () => _importBundle(context),
            icon: const Icon(Icons.inventory_2_outlined),
            label: const Text('Import .morphic bundle'),
          ),
          const SizedBox(height: MorphicSpace.xl),
          Text('Recent workspaces', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: MorphicSpace.sm),
          _WorkspaceList(
            future: _workspaces,
            fileSource: widget.fileSource ?? const FilePickerSource(),
            bundlePathResolver:
                widget.bundlePathResolver ?? const DocumentsBundlePathResolver(),
            bundleWriter: widget.bundleWriter ?? const FileBundleWriter(),
            sampleLauncher: widget.sampleLauncher,
            onChanged: _reloadWorkspaces,
            onRetry: _reloadWorkspaces,
          ),
          const SizedBox(height: MorphicSpace.xl),
          Row(
            children: [
              Icon(Icons.lock_outline, size: 16, color: scheme.primary),
              const SizedBox(width: MorphicSpace.sm),
              Expanded(
                child: Text(
                  'All processing happens on this device.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EngineStatusCard extends StatelessWidget {
  const _EngineStatusCard({required this.future, required this.onRetry});
  final Future<EngineInfo>? future;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: FutureBuilder<EngineInfo>(
          future: future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: MorphicSpace.md),
                  Text('Starting Rust engine…'),
                ],
              );
            }
            if (snap.hasError) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.error_outline,
                          color: MorphicColors.error),
                      const SizedBox(width: MorphicSpace.md),
                      Expanded(
                          child: Text('Engine unavailable: ${snap.error}')),
                    ],
                  ),
                  const SizedBox(height: MorphicSpace.sm),
                  Text(
                    'The engine did not start. Try again; your files are not affected.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('engine-retry-button'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Try again'),
                    ),
                  ),
                ],
              );
            }
            final info = snap.data!;
            return Row(
              children: [
                Icon(Icons.memory, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: MorphicSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Rust engine connected',
                          style: Theme.of(context).textTheme.titleSmall),
                      Text(
                        'core ${info.coreVersion} · bridge API v${info.apiVersion}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The actions offered for one workspace row. `PopupMenuItem<String>` values are also the
/// labels in the menu, so tests and the UI agree on one vocabulary.
enum _WorkspaceAction { rename, duplicate, delete, relink, export }

class _WorkspaceList extends StatelessWidget {
  const _WorkspaceList({
    required this.future,
    required this.fileSource,
    required this.bundlePathResolver,
    required this.bundleWriter,
    required this.sampleLauncher,
    required this.onChanged,
    required this.onRetry,
  });

  final Future<List<dynamic>>? future;
  final PlatformFileSource fileSource;
  final BundlePathResolver bundlePathResolver;
  final BundleWriter bundleWriter;
  final SampleLauncher? sampleLauncher;
  final VoidCallback onChanged;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scope = BridgeScope.of(context);
    return FutureBuilder<List<dynamic>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(MorphicSpace.md),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (snap.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load workspaces: ${snap.error}'),
              const SizedBox(height: MorphicSpace.sm),
              Text(
                'Your workspaces are still saved. Try loading the list again.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('workspaces-retry-button'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Try again'),
                ),
              ),
            ],
          );
        }
        final items = snap.data ?? [];
        if (items.isEmpty) {
          return Card(
            key: const Key('sample-suggestion'),
            child: Padding(
              padding: const EdgeInsets.all(MorphicSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No workspaces yet. Run the proof of concept to generate one from data.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: MorphicSpace.md),
                  Text(
                    'First time here? Try a bundled sample. Nothing leaves this device.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (sampleLauncher != null) ...[
                    const SizedBox(height: MorphicSpace.md),
                    Wrap(
                      spacing: MorphicSpace.sm,
                      runSpacing: MorphicSpace.sm,
                      children: [
                        for (final sample in sampleDatasets)
                          OutlinedButton.icon(
                            key: Key('sample-${sample.id}'),
                            onPressed: () => _openSample(context, sample),
                            icon: const Icon(Icons.insert_drive_file_outlined),
                            label: Text(sample.title),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          children: [
            for (final item in items)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.dashboard_outlined),
                  title: Text((item as Map)['title'] as String? ?? 'Workspace'),
                  subtitle: Text(item['id'] as String? ?? ''),
                  trailing: PopupMenuButton<_WorkspaceAction>(
                    key: ValueKey('workspace-menu-${item['id']}'),
                    onSelected: (action) => _run(
                      context,
                      scope,
                      item['id'] as String,
                      item['title'] as String? ?? 'Workspace',
                      action,
                    ),
                    itemBuilder: (_) => const [
                      PopupMenuItem<_WorkspaceAction>(
                        value: _WorkspaceAction.rename,
                        child: Text('Rename'),
                      ),
                      PopupMenuItem<_WorkspaceAction>(
                        value: _WorkspaceAction.duplicate,
                        child: Text('Duplicate'),
                      ),
                      PopupMenuItem<_WorkspaceAction>(
                        value: _WorkspaceAction.delete,
                        child: Text('Delete'),
                      ),
                      PopupMenuItem<_WorkspaceAction>(
                        value: _WorkspaceAction.relink,
                        child: Text('Re-link source file'),
                      ),
                      PopupMenuItem<_WorkspaceAction>(
                        value: _WorkspaceAction.export,
                        child: Text('Export .morphic bundle'),
                      ),
                    ],
                  ),
                  onTap: () async {
                    // Reopen as a live session: Rust rehydrates from the persisted source
                    // so the table and metrics work, not just the document structure.
                    final engine = EngineController(
                      bridge: scope.bridge,
                      storageRoot: scope.storageRoot,
                    );
                    await engine.open(item['id'] as String);
                    if (!context.mounted) return;
                    // A failed open is intentionally still navigated: WorkspaceView renders
                    // the engine's error with a retry instead of a silent no-op tap.
                    Navigator.of(context).pushNamed(
                      '/workspace',
                      arguments: WorkspaceArgs(controller: engine),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _openSample(BuildContext context, SampleDataset sample) async {
    final launcher = sampleLauncher;
    if (launcher == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await launcher.launch(context, sample);
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open sample: $e')),
      );
      return;
    }
    if (context.mounted) onChanged();
  }

  String get _nowIso => DateTime.now().toUtc().toIso8601String();

  /// Every action is a bridge call, then a list refresh. Errors are shown, never swallowed:
  /// an engine rejection (empty title, id collision, wrong source bytes) leaves the library
  /// exactly as it was.
  Future<void> _run(
    BuildContext context,
    BridgeScope scope,
    String id,
    String title,
    _WorkspaceAction action,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    String message = '';
    try {
      switch (action) {
        case _WorkspaceAction.rename:
          if (!context.mounted) return;
          final next = await _askForTitle(context, title);
          if (next == null) return;
          scope.bridge.renameWorkspace(
            storageRoot: scope.storageRoot,
            workspaceId: id,
            title: next,
            nowIso: _nowIso,
          );
          message = 'Renamed to $next';
        case _WorkspaceAction.duplicate:
          final newId = 'w_${DateTime.now().microsecondsSinceEpoch}';
          scope.bridge.duplicateWorkspace(
            storageRoot: scope.storageRoot,
            workspaceId: id,
            newWorkspaceId: newId,
            title: '$title copy',
            nowIso: _nowIso,
          );
          message = 'Duplicated as $title copy';
        case _WorkspaceAction.delete:
          if (!context.mounted) return;
          final confirmed = await _confirmDelete(context, title);
          if (confirmed != true) return;
          scope.bridge.deleteWorkspace(
            storageRoot: scope.storageRoot,
            workspaceId: id,
          );
          message = 'Deleted $title';
        case _WorkspaceAction.relink:
          final picked = await fileSource.pick();
          if (picked == null) return; // cancelled, not an error
          final bytes = await _read(picked);
          scope.bridge.relinkWorkspace(
            bytes: bytes,
            storageRoot: scope.storageRoot,
            workspaceId: id,
          );
          message = 'Source restored for $title';
        case _WorkspaceAction.export:
          final result = scope.bridge.exportBundle(
            storageRoot: scope.storageRoot,
            workspaceId: id,
            nowIso: _nowIso,
          );
          final bundle = result['bundleJson'] as String?;
          if (bundle == null) {
            throw const FormatException('engine returned no bundleJson');
          }
          final path = await bundlePathResolver.exportPath(id);
          await bundleWriter.write(path, utf8.encode(bundle));
          message = 'Exported $title to $path';
      }
    } catch (e) {
      message = 'Could not ${_verb(action)}: $e';
    }
    onChanged();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  String _verb(_WorkspaceAction action) => switch (action) {
        _WorkspaceAction.rename => 'rename',
        _WorkspaceAction.duplicate => 'duplicate',
        _WorkspaceAction.delete => 'delete',
        _WorkspaceAction.relink => 're-link',
        _WorkspaceAction.export => 'export',
      };

  Future<Uint8List> _read(PickedFile file) async {
    final bytes = file.bytes;
    if (bytes != null) return bytes;
    final path = file.path;
    if (path == null) {
      throw const FileSelectionException('the picker returned nothing readable');
    }
    return File(path).readAsBytes();
  }

  Future<String?> _askForTitle(BuildContext context, String current) {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename workspace'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context, String title) =>
      showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete workspace?'),
          content: Text(
            '"$title" and its edits will be removed. Imported source files are kept '
            'because other workspaces may share them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
}
