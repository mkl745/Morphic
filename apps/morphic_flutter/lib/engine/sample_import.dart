/// Sample import and launch seams (M1.6 task 1.6.4).
///
/// A sample is not a second import implementation: it loads bytes from a [SampleSource],
/// hands them to the real [ImportController] with the catalog's format facts, then adopts
/// the engine result into an [EngineController]. The launcher owns navigation so both the
/// home first-run suggestion and the import screen's sample row share one path.
library;

import 'package:flutter/material.dart';

import 'bridge.dart';
import 'engine_controller.dart';
import 'import_controller.dart';
import 'import_runner.dart';
import 'sample_source.dart';
import '../features/workspace/workspace_args.dart';

class SampleImportOutcome {
  const SampleImportOutcome({
    required this.workspaceId,
    required this.controller,
    required this.warnings,
  });

  final String workspaceId;
  final EngineController controller;
  final List<String> warnings;
}

abstract interface class SampleImporter {
  Future<SampleImportOutcome> open(SampleDataset dataset);
}

class EngineSampleImporter implements SampleImporter {
  const EngineSampleImporter({
    required this.bridge,
    required this.storageRoot,
    required this.runner,
    this.source = const AssetSampleSource(),
    this.now,
  });

  final MorphicBridge bridge;
  final String storageRoot;
  final ImportRunner runner;
  final SampleSource source;

  /// Injected so unit tests can pin the workspace id and `nowIso` exactly.
  final DateTime? now;

  @override
  Future<SampleImportOutcome> open(SampleDataset dataset) async {
    final bytes = await source.load(dataset);
    final controller = ImportController(
      bridge: bridge,
      storageRoot: storageRoot,
      runner: runner,
    );
    try {
      final id = await controller.importBytes(
        bytes,
        title: dataset.title,
        now: now,
        formatHint: dataset.formatHint,
        extension: dataset.extension,
      );
      final result = controller.result;
      if (id == null || result == null) {
        throw StateError(controller.error ?? 'the engine did not return a workspace');
      }
      final engine = EngineController(
        bridge: bridge,
        storageRoot: storageRoot,
      );
      engine.adoptImport(result, id);
      return SampleImportOutcome(
        workspaceId: id,
        controller: engine,
        warnings: controller.warnings,
      );
    } finally {
      controller.dispose();
    }
  }
}

abstract interface class SampleLauncher {
  Future<void> launch(BuildContext context, SampleDataset sample);
}

class EngineSampleLauncher implements SampleLauncher {
  const EngineSampleLauncher(this.importer);

  final SampleImporter importer;

  @override
  Future<void> launch(BuildContext context, SampleDataset sample) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final outcome = await importer.open(sample);
      if (!context.mounted) return;
      await Navigator.of(context).pushNamed(
        '/workspace',
        arguments: WorkspaceArgs(
          controller: outcome.controller,
          warnings: outcome.warnings,
          animateEntrance: true,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open sample: $e')),
      );
    }
  }
}
