/// Shared empty/error copy and recovery surfaces (M1.6 task 1.6.5).
///
/// Design-system §7 requires empty-after-filter and binding-error states to be designed
/// surfaces with recovery actions, never blank boxes. Shared recovery wording lives here;
/// existing surface-specific headlines and typed import failures stay with their owners.
/// Persistent surfaces carry a button or next-step sentence, and engine evidence is kept.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

abstract final class MorphicCopy {
  static const String noRowsMatch = 'No rows match the current filters.';
  static const String noWorkspaceRows = 'No rows match the workspace filters.';
  static const String clearWorkspaceFilters = 'Clear workspace filters';
  static const String clearViewFilters = 'Clear view filters';
  static const String clearSearchAndFilters = 'Clear search and filters';
  static const String retry = 'Retry';
  static const String tryAgain = 'Try again';

  static const String chartFailure = 'This chart could not be built.';
  static const String timelineFailure = 'This timeline could not be built.';
  static const String updateFailure = 'Could not apply that change. Try again.';

  static const String noWorkspaceOpenDetail =
      'Open a workspace from Home, or import a file to create one.';
  static const String workspaceOpenFailureDetail =
      'Return to Home and try opening the workspace again.';
  static const String noWorkspaceDocumentDetail =
      'Return to Home, then open a workspace or import a file.';
  static const String noComponentsDetail =
      'Try a different file, or return to Home to open another workspace.';
  static const String noRowsDetail =
      'Check the source data, or return to Home to import a different file.';
  static const String noTableRowsDetail =
      'Import a file with data rows to create a new workspace.';
  static const String noColumnsDetail =
      'Try importing a file with columns to create a new workspace.';
  static const String missingSourceDetail =
      'Restore the source file, or import it again to create a new workspace.';
  static const String metricFiltersHint =
      'Workspace filters may affect this metric.';
  static const String noProfileDetail =
      'Try reopening the workspace, or import a file with columns to create a new workspace.';
  static const String noProfileDegradedDetail =
      'Close this sheet, then choose Restore source file in the workspace.';
  static const String unsupportedViewDetail =
      'Return to Home and open another workspace, or update Morphic if a newer version is available.';
  static const String engineFailureDetail =
      'Try again. If the engine is still unavailable, restart Morphic.';
  static const String libraryFailureDetail =
      'Try loading the list again. If it still fails, check device storage.';
  static const String sampleLoadFailureDetail =
      'The sample data could not be loaded. Try again, or choose another file from Home.';
  static const String sampleBuildFailureDetail =
      'The workspace could not be built. Try again, or choose another file from Home.';
}

/// A shared empty/error surface. Errors can include the engine's verbatim evidence in
/// [detail], separately from the human-readable headline and recovery action.
class MorphicStateMessage extends StatelessWidget {
  const MorphicStateMessage({
    super.key,
    required this.icon,
    required this.headline,
    this.detail,
    this.action,
    this.isError = false,
  });

  final IconData icon;
  final String headline;
  final String? detail;
  final Widget? action;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MorphicSpace.md),
        child: Column(
          children: [
            Icon(
              icon,
              size: 20,
              color: dark
                  ? MorphicColors.textSecondaryDark
                  : MorphicColors.textSecondaryLight,
            ),
            const SizedBox(height: MorphicSpace.sm),
            Text(
              headline,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isError
                    ? (dark ? MorphicColors.error : MorphicColors.severityErrorLight)
                    : null,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: MorphicSpace.xs),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (action != null) action!,
          ],
        ),
      ),
    );
  }
}

/// Recovery controls distinguish workspace-wide filters from this view's filters/search.
/// A user can clear either scope without unexpectedly discarding the other.
class MorphicFilterActions extends StatelessWidget {
  const MorphicFilterActions({
    super.key,
    this.onClearWorkspace,
    this.onClearView,
    this.workspaceKey,
    this.viewKey,
    this.viewLabel = MorphicCopy.clearViewFilters,
    this.busy = false,
  });

  final VoidCallback? onClearWorkspace;
  final VoidCallback? onClearView;
  final Key? workspaceKey;
  final Key? viewKey;
  final String viewLabel;
  final bool busy;

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.center,
        children: [
          if (onClearWorkspace != null)
            TextButton(
              key: workspaceKey,
              onPressed: busy ? null : onClearWorkspace,
              child: const Text(MorphicCopy.clearWorkspaceFilters),
            ),
          if (onClearView != null)
            TextButton(
              key: viewKey,
              onPressed: busy ? null : onClearView,
              child: Text(viewLabel),
            ),
        ],
      );
}

/// A rejected command remains visible with its original engine evidence and a next step.
class MorphicCommandError extends StatelessWidget {
  const MorphicCommandError({
    super.key,
    required this.evidence,
    this.evidenceKey,
  });

  final String evidence;
  final Key? evidenceKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.brightness == Brightness.dark
        ? MorphicColors.error
        : MorphicColors.severityErrorLight;
    final style = theme.textTheme.labelSmall?.copyWith(color: color);
    return Padding(
      padding: const EdgeInsets.only(top: MorphicSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(MorphicCopy.updateFailure, style: style),
          Text(evidence, key: evidenceKey, style: style),
        ],
      ),
    );
  }
}
