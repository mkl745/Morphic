import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../design_system/tokens.dart';
import '../../engine/bridge_scope.dart';
import '../../engine/engine_controller.dart';
import '../../engine/import_controller.dart';
import '../../engine/import_runner.dart';
import '../workspace/workspace_args.dart';

/// The Phase 0 vertical-slice demo: load a sample CSV, have **Rust** profile it, then
/// generate + persist a workspace and open it. This is the "demonstrable data-processing
/// proof of concept" required by spec §13 Phase 0.
class PocScreen extends StatefulWidget {
  const PocScreen({super.key});

  @override
  State<PocScreen> createState() => _PocScreenState();
}

class _PocScreenState extends State<PocScreen> {
  Uint8List? _bytes;
  Map<String, dynamic>? _profile;
  String? _error;
  bool _generating = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _loadAndProfile();
    }
  }

  Future<void> _loadAndProfile() async {
    final scope = BridgeScope.of(context);
    setState(() => _error = null);
    try {
      final data = await rootBundle.load('assets/samples/sample_logs.csv');
      final bytes = data.buffer.asUint8List();
      final profile = scope.bridge.profileCsv(bytes);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _profile = profile;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _generate() async {
    final scope = BridgeScope.of(context);
    final bytes = _bytes;
    if (bytes == null) return;
    setState(() => _generating = true);
    // Real import: Rust analyzes, compiles, validates, persists, and keeps a live session
    // so the workspace can page and aggregate without re-reading the file.
    final importer = ImportController(
      bridge: scope.bridge,
      storageRoot: scope.storageRoot,
      runner: scope.importRunner ?? const IsolateImportRunner(),
    );
    final id = await importer.importBytes(bytes, title: 'Sample Logs');
    if (!mounted) return;
    final outcome = importer.result;
    if (id == null || outcome == null) {
      setState(() {
        _generating = false;
        _error = importer.error ?? 'the engine did not return a workspace';
      });
      return;
    }
    final engine =
        EngineController(bridge: scope.bridge, storageRoot: scope.storageRoot);
    engine.adoptImport(outcome, id);
    Navigator.of(context).pushReplacementNamed(
      '/workspace',
      arguments: WorkspaceArgs(controller: engine, warnings: importer.warnings),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Proof of concept')),
      body: ListView(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        children: [
          _stage(1, 'Inspecting data', done: _bytes != null),
          _stage(2, 'Discovering structure (Rust)', done: _profile != null),
          _stage(3, 'Planning visualizations', done: _profile != null),
          const SizedBox(height: MorphicSpace.lg),
          if (_error != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(MorphicSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Error: $_error',
                        style: const TextStyle(color: MorphicColors.error)),
                    const SizedBox(height: MorphicSpace.sm),
                    const Text(
                      'The sample data could not be loaded. '
                      'Try again; nothing was saved.',
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('poc-retry-button'),
                        onPressed: _generating ? null : _loadAndProfile,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Try again'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_profile != null) ...[
            Text('Detected schema', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: MorphicSpace.sm),
            _ProfileView(profile: _profile!),
            const SizedBox(height: MorphicSpace.lg),
            FilledButton.icon(
              onPressed: _generating ? null : _generate,
              icon: _generating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_generating ? 'Building workspace…' : 'Generate workspace'),
            ),
          ] else if (_error == null)
            const Padding(
              padding: EdgeInsets.all(MorphicSpace.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          const SizedBox(height: MorphicSpace.md),
          Text(
            'The schema above was computed by the Rust engine, not Dart.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurface.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }

  Widget _stage(int n, String label, {required bool done}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MorphicSpace.xs),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
            color: done ? MorphicColors.success : MorphicColors.textSecondaryDark,
          ),
          const SizedBox(width: MorphicSpace.md),
          Text('$n. $label'),
        ],
      ),
    );
  }
}

class _ProfileView extends StatelessWidget {
  const _ProfileView({required this.profile});
  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final fields = (profile['fields'] as List? ?? []).cast<Map<String, dynamic>>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${profile['rowCount']} rows · ${profile['fieldCount']} fields',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: MorphicSpace.md),
            for (final f in fields)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: MorphicSpace.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(f['name'] as String? ?? ''),
                    ),
                    _chip(context, f['dtype'] as String? ?? '?'),
                    const SizedBox(width: MorphicSpace.sm),
                    _chip(
                      context,
                      (f['inference'] as Map?)?['role'] as String? ?? 'unknown',
                      accent: true,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String text, {bool accent = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: MorphicSpace.sm, vertical: 2),
      decoration: BoxDecoration(
        color: accent ? scheme.primary.withValues(alpha: 0.15) : scheme.surface,
        borderRadius: BorderRadius.circular(MorphicRadius.sm),
        border: Border.all(
          color: accent ? scheme.primary : MorphicColors.borderDark,
        ),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
