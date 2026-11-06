/// Import UI v0 (M1.1 task 1.1.7).
///
/// Pick a file → the Rust engine analyzes, generates, validates and persists it on a worker
/// isolate → the interactive workspace opens. Every number on this screen came from the
/// engine; there is no fake percentage, because the engine reports no total.
///
/// The picked bytes are not copied by Dart: `put_dataset` content-addresses them into
/// app-private storage, which *is* the copy step, and makes re-importing the same file free.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../../engine/bridge_scope.dart';
import '../../engine/engine_controller.dart';
import '../../engine/file_source.dart';
import '../../engine/import_controller.dart';
import '../../engine/import_runner.dart';
import '../workspace/workspace_args.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key, this.fileSource, this.runner});

  /// Injected in tests. Production uses the SAF picker and a worker isolate.
  final PlatformFileSource? fileSource;
  final ImportRunner? runner;

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  ImportController? _controller;
  PlatformFileSource? _source;
  PickedFile? _picked;
  String? _pickError;
  bool _picking = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = BridgeScope.of(context);
    _source = widget.fileSource ?? const FilePickerSource();
    _controller = ImportController(
      bridge: scope.bridge,
      storageRoot: scope.storageRoot,
      runner: widget.runner ?? scope.importRunner ?? const IsolateImportRunner(),
    )..addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final source = _source;
    final controller = _controller;
    if (source == null || controller == null || controller.isBusy) return;
    setState(() {
      _picking = true;
      _pickError = null;
    });
    final PickedFile? file;
    try {
      file = await source.pick();
    } on FileSelectionException catch (e) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _pickError = e.message;
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _pickError = 'could not choose a file: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      _picked = file;
    });
    // Cancelling is a normal outcome, not an error.
    if (file != null) await _import(file);
  }

  Future<void> _import(PickedFile file) async {
    final controller = _controller;
    if (controller == null) return;
    final scope = BridgeScope.of(context);
    final id = await controller.importPicked(file);
    if (!mounted) return;
    final outcome = controller.result;
    if (id == null || outcome == null) {
      setState(() {});
      return;
    }
    final engine = EngineController(
      bridge: scope.bridge,
      storageRoot: scope.storageRoot,
    )..adoptImport(outcome, id);
    Navigator.of(context).pushReplacementNamed(
      '/workspace',
      arguments: WorkspaceArgs(controller: engine, warnings: controller.warnings),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;
    final busy = controller?.isBusy ?? false;
    final error = _pickError ?? controller?.error;

    return Scaffold(
      appBar: AppBar(title: const Text('Import a file')),
      body: ListView(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        children: [
          Text(
            'Choose a CSV, TSV or text table. MORPHIC inspects it and builds the '
            'workspace for you — nothing leaves this device.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: MorphicSpace.lg),
          FilledButton.icon(
            onPressed: (busy || _picking) ? null : _pick,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(_picking ? 'Opening picker…' : 'Choose a CSV file'),
          ),
          const SizedBox(height: MorphicSpace.lg),
          if (_picked != null) _PickedFileCard(file: _picked!),
          if (controller != null && (busy || controller.stage == ImportStage.done))
            _ImportProgressCard(controller: controller),
          if (error != null) ...[
            const SizedBox(height: MorphicSpace.md),
            _ErrorCard(message: error, onRetry: busy ? null : _pick),
          ],
          const SizedBox(height: MorphicSpace.xl),
          Text(
            'JSON and structured logs are not supported yet.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }
}

class _PickedFileCard extends StatelessWidget {
  const _PickedFileCard({required this.file});

  final PickedFile file;

  @override
  Widget build(BuildContext context) {
    final size = file.sizeBytes ?? file.bytes?.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Row(
          children: [
            const Icon(Icons.description_outlined),
            const SizedBox(width: MorphicSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(file.name,
                      style: Theme.of(context).textTheme.titleSmall),
                  if (size != null)
                    Text(formatByteCount(size),
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportProgressCard extends StatelessWidget {
  const _ImportProgressCard({required this.controller});

  final ImportController controller;

  @override
  Widget build(BuildContext context) {
    final progress = controller.progress;
    final done = controller.stage == ImportStage.done;
    final elapsed = controller.elapsed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  done ? Icons.check_circle : Icons.memory,
                  color: done ? MorphicColors.success : null,
                ),
                const SizedBox(width: MorphicSpace.md),
                Expanded(
                  child: Text(
                    switch (controller.stage) {
                      ImportStage.reading => 'Reading file',
                      ImportStage.done => 'Workspace ready',
                      _ => progress?.label ?? 'Starting engine',
                    },
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (!done) ...[
              const SizedBox(height: MorphicSpace.md),
              // Indeterminate on purpose: the engine reports rows read, not a total, so a
              // determinate bar would be an invented number.
              const LinearProgressIndicator(),
            ],
            if (progress != null && progress.rowsRead > 0) ...[
              const SizedBox(height: MorphicSpace.md),
              Text(
                '${progress.rowsRead} rows · ${formatByteCount(progress.bytesRead)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (done) ...[
              const SizedBox(height: MorphicSpace.md),
              Text(
                '${controller.rowsImported ?? 0} rows imported'
                '${elapsed == null ? '' : ' in ${elapsed.inMilliseconds} ms'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: MorphicSpace.sm),
              TextButton(onPressed: onRetry, child: const Text('Choose another file')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Binary units, one decimal above 1 KB. Shared so the picker card and the progress card
/// never disagree about the same file.
String formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
