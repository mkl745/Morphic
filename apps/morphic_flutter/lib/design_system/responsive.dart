/// Shared window classes for the workspace and its detail surfaces.
///
/// Widths are logical pixels, not physical pixels or orientation guesses. A phone in
/// landscape therefore gets the same layout as any other window of that width.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

enum MorphicWindowClass { compact, medium, expanded }

abstract final class MorphicResponsive {
  static const double mediumStart = 600;
  static const double expandedAfter = 840;
  static const double pageMaxWidth = 840;

  static MorphicWindowClass classify(double width) {
    if (width < mediumStart) return MorphicWindowClass.compact;
    if (width <= expandedAfter) return MorphicWindowClass.medium;
    return MorphicWindowClass.expanded;
  }

  /// The expanded rail leaves a useful workspace even just above the breakpoint.
  static double railWidth(double width) => (width * 0.25).clamp(240.0, 320.0).toDouble();

  /// [availableWidth] excludes the workspace's horizontal padding and any detail rail.
  static int workspaceColumns(MorphicWindowClass windowClass, double availableWidth) {
    switch (windowClass) {
      case MorphicWindowClass.compact:
        return 1;
      case MorphicWindowClass.medium:
        return 2;
      case MorphicWindowClass.expanded:
        return availableWidth >= 900 ? 3 : 2;
    }
  }

  static double sideSheetWidth(double width) => math.min(420.0, width * 0.75);
}

/// Keeps single-column gateway screens readable on large windows without constraining height
/// or changing the scrollable's viewport on a phone.
class MorphicPageWidth extends StatelessWidget {
  const MorphicPageWidth({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          key: const Key('morphic-page-width'),
          constraints: const BoxConstraints(maxWidth: MorphicResponsive.pageMaxWidth),
          child: child,
        ),
      );
}
