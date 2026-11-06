/// Arguments for the workspace route.
///
/// Two modes, deliberately distinct: a live [EngineController] renders the interactive
/// runtime, while a bare [document] renders the read-only structural view used to inspect a
/// saved document. Ingest warnings travel with the navigation so they are surfaced on the
/// workspace rather than lost when the import screen is disposed.
library;

import '../../engine/engine_controller.dart';

class WorkspaceArgs {
  const WorkspaceArgs({this.controller, this.document, this.warnings = const []});

  final EngineController? controller;
  final Map<String, dynamic>? document;
  final List<String> warnings;
}
