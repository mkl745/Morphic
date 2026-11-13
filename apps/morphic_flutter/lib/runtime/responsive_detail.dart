/// Workspace detail presentation: bottom sheet, side sheet, or the persistent detail rail.
///
/// Isolated component hosts without a [WorkspaceDetailScope] retain the original bottom-sheet
/// behavior. The workspace provides the scope so the same content can move between surfaces.
library;

import 'package:flutter/material.dart';

import '../design_system/responsive.dart';
import '../design_system/tokens.dart';

typedef WorkspaceDetailBuilder = Widget Function(BuildContext context, VoidCallback close);
typedef WorkspaceDetailPresenter = void Function(
  WorkspaceDetailBuilder builder,
  WorkspaceDetailBuilder? bottomBuilder,
);

class WorkspaceDetailScope extends InheritedWidget {
  const WorkspaceDetailScope({
    super.key,
    required this.windowClass,
    required this.openInRail,
    required this.reopen,
    required super.child,
  });

  final MorphicWindowClass windowClass;
  final WorkspaceDetailPresenter openInRail;
  final WorkspaceDetailPresenter reopen;

  static WorkspaceDetailScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<WorkspaceDetailScope>();

  @override
  bool updateShouldNotify(WorkspaceDetailScope oldWidget) =>
      windowClass != oldWidget.windowClass ||
      openInRail != oldWidget.openInRail ||
      reopen != oldWidget.reopen;
}

/// The caller provides content and a close callback, rather than assuming Navigator.pop is
/// safe: on expanded screens the content is part of the workspace, not a new route.
Future<void> showWorkspaceDetail(
  BuildContext context, {
  required WorkspaceDetailBuilder builder,
  WorkspaceDetailBuilder? bottomBuilder,
}) async {
  final scope = WorkspaceDetailScope.maybeOf(context);
  if (scope?.windowClass == MorphicWindowClass.expanded) {
    scope!.openInRail(builder, bottomBuilder);
    return;
  }

  Widget watchSize(Widget child) => scope == null
      ? child
      : _DetailResizeWatcher(
          onClassChanged: () => scope.reopen(builder, bottomBuilder),
          child: child,
        );
  if (scope?.windowClass == MorphicWindowClass.medium) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final barrier = Theme.of(context).colorScheme.scrim.withValues(alpha: 0.32);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: barrier,
      transitionDuration: reduced ? Duration.zero : MorphicMotion.standard,
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
      pageBuilder: (dialogContext, animation, secondaryAnimation) => watchSize(
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Material(
            key: const Key('workspace-detail-side-sheet'),
            color: Theme.of(dialogContext).colorScheme.surface,
            elevation: 4,
            child: SizedBox(
              width: MorphicResponsive.sideSheetWidth(MediaQuery.sizeOf(dialogContext).width),
              height: double.infinity,
              child: builder(dialogContext, () => Navigator.of(dialogContext).pop()),
            ),
          ),
        ),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => watchSize(
      (bottomBuilder ?? builder)(
        sheetContext,
        () => Navigator.of(sheetContext).pop(),
      ),
    ),
  );
}

/// A modal route is outside the workspace subtree. On a breakpoint transition, dismiss only
/// that route and ask the still-mounted workspace anchor to re-present the same detail in the
/// new surface. Checking the route prevents a resize from popping an unrelated screen.
class _DetailResizeWatcher extends StatefulWidget {
  const _DetailResizeWatcher({required this.onClassChanged, required this.child});

  final VoidCallback onClassChanged;
  final Widget child;

  @override
  State<_DetailResizeWatcher> createState() => _DetailResizeWatcherState();
}

class _DetailResizeWatcherState extends State<_DetailResizeWatcher> {
  MorphicWindowClass? _observed;
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = MorphicResponsive.classify(MediaQuery.sizeOf(context).width);
    if (_observed != null && _observed != next && !_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route?.isCurrent != true) {
          _scheduled = false;
          return;
        }
        Navigator.of(context).pop();
        widget.onClassChanged();
      });
    }
    _observed = next;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
