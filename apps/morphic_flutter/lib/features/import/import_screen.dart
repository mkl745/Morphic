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
import '../../engine/import_failure.dart';
import '../../engine/import_facts.dart';
import '../../engine/import_runner.dart';
import '../workspace/workspace_args.dart';

/// The chooser value meaning "let the engine decide". Shared by the dropdown and the
/// report sheet so the two cannot drift apart.
const String kAutoDetect = 'auto';

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

  /// Set when an import succeeded but deserves review before the workspace is opened.
  String? _readyId;

  /// `'auto'` means let the engine detect the format; anything else is the override the user
  /// picks when a sniff was wrong (docs/architecture/05 §1.1). A sentinel rather than a null
  /// dropdown value, so "detect automatically" is a real, visible choice.
  String _formatChoice = _autoDetect;

  static const String _autoDetect = kAutoDetect;

  /// The engine's format hint for the current choice, or null to let it detect.
  String? get _formatHint => _formatChoice == _autoDetect ? null : _formatChoice;

  /// The choices the engine accepts, in the order a user is likely to need them.
  static const Map<String, String> _formats = {
    'csv': 'CSV / TSV',
    'json': 'JSON',
    'jsonl': 'JSON Lines',
    'log': 'Structured log',
    'txt': 'Plain text',
  };
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
    final id = await controller.importPicked(file, formatHint: _formatHint);
    if (!mounted) return;
    _afterImport(id);
  }

  /// Re-read the same bytes as a different format. Offered when a sniff was wrong or the
  /// user wants to compare interpretations.
  Future<void> _reimportAs(String? hint) async {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _formatChoice = hint ?? _autoDetect;
      _readyId = null;
    });
    final id = await controller.reimport(formatHint: hint);
    if (!mounted) return;
    _afterImport(id);
  }

  /// A clean, confident import goes straight to the workspace. One with quarantined rows or
  /// low confidence stays here so the user sees the report before trusting the table.
  void _afterImport(String? id) {
    final controller = _controller;
    if (controller == null) return;
    final outcome = controller.result;
    if (id == null || outcome == null) {
      setState(() => _readyId = null);
      return;
    }
    if (controller.needsReview) {
      setState(() => _readyId = id);
      return;
    }
    _openWorkspace(id);
  }

  void _openWorkspace(String id) {
    final controller = _controller;
    final outcome = controller?.result;
    if (controller == null || outcome == null) return;
    final scope = BridgeScope.of(context);
    final engine = EngineController(
      bridge: scope.bridge,
      storageRoot: scope.storageRoot,
    )..adoptImport(outcome, id);
    Navigator.of(context).pushReplacementNamed(
      '/workspace',
      arguments: WorkspaceArgs(controller: engine, warnings: controller.warnings),
    );
  }

  Future<void> _showReport() async {
    final controller = _controller;
    if (controller == null) return;
    final hint = await showImportReportSheet(
      context,
      facts: controller.facts,
      failure: controller.failure,
      canReimport: controller.canReimport,
    );
    if (!mounted || hint == null) return;
    // The sheet returns `_autoDetect` or a format id when the user chose to re-import.
    await _reimportAs(hint == _autoDetect ? null : hint);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;
    final busy = controller?.isBusy ?? false;
    final failure = controller?.failure;
    final error = _pickError ?? failure?.headline;
    final facts = controller?.facts;

    return Scaffold(
      appBar: AppBar(title: const Text('Import a file')),
      body: ListView(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        children: [
          Text(
            'Choose a CSV, JSON, JSON Lines, log or text file. MORPHIC detects the '
            'format and builds the workspace for you — nothing leaves this device.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: MorphicSpace.lg),
          FilledButton.icon(
            onPressed: (busy || _picking) ? null : _pick,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(_picking ? 'Opening picker…' : 'Choose a file'),
          ),
          const SizedBox(height: MorphicSpace.lg),
          DropdownButtonFormField<String>(
            initialValue: _formatChoice,
            decoration: const InputDecoration(
              labelText: 'Format',
              helperText: 'Detect automatically unless the result looks wrong.',
            ),
            items: [
              const DropdownMenuItem<String>(
                value: _autoDetect,
                child: Text('Detect automatically'),
              ),
              for (final entry in _formats.entries)
                DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(entry.value),
                ),
            ],
            onChanged: (busy || _picking)
                ? null
                : (value) => setState(
                    () => _formatChoice = value ?? _autoDetect,
                  ),
          ),
          const SizedBox(height: MorphicSpace.lg),
          if (_picked != null) _PickedFileCard(file: _picked!),
          if (controller != null && (busy || controller.stage == ImportStage.done))
            _ImportProgressCard(controller: controller),
          if (controller != null &&
              controller.stage == ImportStage.cancelled) ...[
            const SizedBox(height: MorphicSpace.md),
            _CancelledCard(onRetry: _pick),
          ],
          if (_readyId != null) ...[
            const SizedBox(height: MorphicSpace.md),
            _ReviewCard(
              onOpen: () => _openWorkspace(_readyId!),
              onReport: _showReport,
            ),
          ],
          if (facts != null) ...[
            const SizedBox(height: MorphicSpace.md),
            _ImportFactsCard(facts: facts, onReport: _showReport),
          ],
          if (error != null) ...[
            const SizedBox(height: MorphicSpace.md),
            _ErrorCard(
              message: error,
              failure: _pickError == null ? failure : null,
              onRetry: busy ? null : _pick,
              onReport: failure == null ? null : _showReport,
            ),
          ],
          const SizedBox(height: MorphicSpace.xl),
          Text(
            'Morphic reports how it read the file, plus any rows it was unable to '
            'parse. If it guessed wrong, choose the format above and import again.',
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
            if (controller.canCancel) ...[
              const SizedBox(height: MorphicSpace.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: controller.cancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Cancel import'),
                ),
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
  const _ErrorCard({
    required this.message,
    this.failure,
    this.onRetry,
    this.onReport,
  });

  final String message;

  /// Present for engine failures; null for picker-level refusals, whose message is already
  /// written for a person.
  final ImportFailure? failure;
  final VoidCallback? onRetry;
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final f = failure;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
            if (f != null) ...[
              const SizedBox(height: MorphicSpace.sm),
              Text(
                f.nextStep,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
              const SizedBox(height: MorphicSpace.sm),
              // The engine's own words stay visible. They are the evidence, and a bug
              // report is useless without them.
              Text(
                f.raw,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer.withValues(alpha: 0.7),
                ),
              ),
            ],
            if (onRetry != null || onReport != null) ...[
              const SizedBox(height: MorphicSpace.sm),
              Wrap(
                spacing: MorphicSpace.sm,
                children: [
                  if (onRetry != null)
                    TextButton(
                        onPressed: onRetry,
                        child: const Text('Choose another file')),
                  if (onReport != null)
                    TextButton(
                        onPressed: onReport,
                        child: const Text('Details and re-import')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Cancellation is a decision, not a failure — so it gets a neutral card, not a red one.
class _CancelledCard extends StatelessWidget {
  const _CancelledCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Import cancelled',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: MorphicSpace.sm),
            Text(
              'Nothing was saved — no workspace and no copy of the file.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: MorphicSpace.sm),
            TextButton(onPressed: onRetry, child: const Text('Choose a file')),
          ],
        ),
      ),
    );
  }
}

/// What the engine actually read. Every number here is the engine's, never a UI estimate.
class _ImportFactsCard extends StatelessWidget {
  const _ImportFactsCard({required this.facts, required this.onReport});

  final ImportFacts facts;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final confidence = facts.confidencePercent;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What Morphic read', style: theme.textTheme.titleSmall),
            const SizedBox(height: MorphicSpace.md),
            _FactRow(label: 'Format', value: facts.formatLabel),
            if (facts.encoding.isNotEmpty)
              _FactRow(label: 'Encoding', value: facts.encoding),
            _FactRow(label: 'Rows', value: '${facts.rowsImported}'),
            _FactRow(label: 'Fields', value: '${facts.fieldCount}'),
            if (facts.hasQuarantine)
              _FactRow(
                label: 'Set aside',
                value: '${facts.rowsQuarantined} rows '
                    '(${(facts.quarantineRate * 100).toStringAsFixed(1)}%)',
              ),
            if (confidence != null)
              _FactRow(label: 'Confidence', value: '$confidence%'),
            const SizedBox(height: MorphicSpace.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onReport,
                child: Text(facts.notes.isEmpty
                    ? 'Import report'
                    : 'Import report (${facts.notes.length})'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: MorphicSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Shown instead of navigating when the result needs a look first.
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.onOpen, required this.onReport});

  final VoidCallback onOpen;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Worth a look first', style: theme.textTheme.titleSmall),
            const SizedBox(height: MorphicSpace.sm),
            Text(
              'Morphic built the workspace, but some rows were set aside or the format '
              'was a close call. Check the report before relying on the numbers.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: MorphicSpace.sm),
            Wrap(
              spacing: MorphicSpace.sm,
              children: [
                FilledButton(onPressed: onReport, child: const Text('View report')),
                TextButton(onPressed: onOpen, child: const Text('Open anyway')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The full import report: the detection headline, every caveat, and a way to re-read the
/// file as something else. Returns the chosen format id (or `auto`) when the user asks to
/// re-import, and null when they simply close it.
Future<String?> showImportReportSheet(
  BuildContext context, {
  required ImportFacts? facts,
  required ImportFailure? failure,
  required bool canReimport,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final notes = facts?.notes ?? const <String>[];
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(MorphicSpace.lg),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Import report', style: theme.textTheme.titleMedium),
                const SizedBox(height: MorphicSpace.md),
                if (facts?.detectionSummary != null) ...[
                  Text(facts!.detectionSummary!, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: MorphicSpace.md),
                ],
                if (facts != null && facts.hasQuarantine) ...[
                  Text(
                    '${facts.rowsQuarantined} of '
                    '${facts.rowsImported + facts.rowsQuarantined} rows were set aside '
                    'because they did not fit the shape of the rest of the file.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: MorphicSpace.md),
                ],
                if (failure != null) ...[
                  Text(failure.headline, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: MorphicSpace.sm),
                  Text(failure.raw, style: theme.textTheme.bodySmall),
                  const SizedBox(height: MorphicSpace.md),
                ],
                if (notes.isEmpty && failure == null)
                  Text('No caveats were reported.', style: theme.textTheme.bodySmall)
                else
                  for (final note in notes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: MorphicSpace.sm),
                      child: Text('• $note', style: theme.textTheme.bodySmall),
                    ),
                if (canReimport) ...[
                  const SizedBox(height: MorphicSpace.md),
                  Text('Read it as something else', style: theme.textTheme.titleSmall),
                  const SizedBox(height: MorphicSpace.sm),
                  Text(
                    'This re-imports the same file into a new workspace. The current one '
                    'is left as it is.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: MorphicSpace.sm),
                  Wrap(
                    spacing: MorphicSpace.sm,
                    runSpacing: MorphicSpace.sm,
                    children: [
                      ActionChip(
                        label: const Text('Detect automatically'),
                        onPressed: () => Navigator.of(sheetContext).pop(kAutoDetect),
                      ),
                      for (final entry in kFormatLabels.entries)
                        ActionChip(
                          label: Text(entry.value),
                          onPressed: () => Navigator.of(sheetContext).pop(entry.key),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: MorphicSpace.md),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('Close'),
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

/// Binary units, one decimal above 1 KB. Shared so the picker card and the progress card
/// never disagree about the same file.
String formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
