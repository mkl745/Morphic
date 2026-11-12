/// Canonical empty/error copy (M1.6 task 1.6.5).
///
/// Design-system §7 requires empty-after-filter and binding-error states to be designed
/// surfaces with recovery actions, never blank boxes. This module is the single place those
/// strings live, so every surface says the same thing and a copy change is one edit.
/// Persistent surfaces carry a next action (a button or a next-step sentence); transient
/// snackbars keep the engine's evidence verbatim and are out of scope here.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Shared empty/error strings. Headlines stay identical to what the widgets rendered before
/// 1.6.5 so existing tests and goldens keep pinning the same words; the sweep adds the
/// missing next actions around them.
abstract final class MorphicCopy {
  /// Empty-after-filter headline shared by the three charts.
  static const String noRowsMatch = 'No rows match the current filters.';

  /// The recovery action for an empty-after-filter surface.
  static const String clearFilters = 'Clear filters';

  /// The recovery action for a failed read.
  static const String retry = 'Retry';

  /// Next step when a workspace was never opened.
  static const String noWorkspaceOpenDetail =
      'Open a workspace from Home, or import a file to create one.';

  /// Next step when the engine generated nothing chartable.
  static const String noComponentsDetail =
      'The file was read, but nothing in it could be charted. '
      'Try a different file with a header row and data rows.';

  /// Next step when a chart has no rows and no filters are set.
  static const String noRowsDetail =
      'The imported file has no rows for this view.';
}

/// The shared empty/error surface: icon, headline, optional next-step detail and optional
/// recovery action. Centred, like the chart messages it replaces, so a surface that gains
/// an action changes by one button rather than a whole layout.
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

  /// The next step in prose, for surfaces with no button of their own.
  final String? detail;
  final Widget? action;

  /// Renders the headline in the error colour (binding-error states).
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MorphicSpace.md),
        child: Column(
          children: [
            Icon(
              icon,
              size: 20,
              color: theme.brightness == Brightness.dark
                  ? MorphicColors.textSecondaryDark
                  : MorphicColors.textSecondaryLight,
            ),
            const SizedBox(height: MorphicSpace.sm),
            Text(
              headline,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isError ? MorphicColors.error : null,
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
