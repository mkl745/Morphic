import 'dart:async';

import 'package:flutter/material.dart';

import 'bridge.dart';
import 'engine_controller.dart';

/// Engine-owned autosave is durable on every command; Flutter's job is only to ask for an
/// explicit checkpoint (docs/architecture/06 §2). This is a *checkpoint* debounce, not a
/// write debounce: Rust has already persisted the document before the timer starts.
const Duration autosaveDebounce = Duration(seconds: 2);

/// Owns the checkpoint timer, the lifecycle flush and the startup recovery report.
///
/// Registered once by the app widget and exposed to the workspace screen through
/// [AutosaveScope]. A process that is killed before the timer fires still has all of its
/// edits on disk; the timer only folds the journal and acknowledges the flush.
class AutosaveCoordinator extends ChangeNotifier {
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Captured once when the engine for this storage root was created.
  RecoveryReport recovery = const RecoveryReport();

  Timer? _timer;
  EngineController? _controller;
  bool _disposed = false;

  /// Bind the currently open workspace controller. Idempotent: the workspace screen calls
  /// this from `build`, so it must not notify listeners or rebuild anything.
  void watch(EngineController? controller) {
    if (_controller == controller) return;
    _controller?.removeListener(_onControllerChanged);
    _timer?.cancel();
    _timer = null;
    _controller = controller;
    controller?.addListener(_onControllerChanged);
    // Imports are adopted before the workspace first binds this coordinator. Their dirty
    // notification has already happened, so schedule the pending checkpoint on attachment.
    if (controller?.dirty == true) _schedule();
  }

  void _onControllerChanged() {
    if (_controller?.dirty == true) _schedule();
  }

  void _schedule() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(autosaveDebounce, () {
      unawaited(flushNow());
    });
  }

  /// Immediate flush for `AppLifecycleState.paused`/`hidden`/`detached` and for dispose.
  /// No debounce: the process may never resume. Returns before the bridge call completes
  /// only if there is nothing to checkpoint.
  Future<void> flushNow() async {
    _timer?.cancel();
    _timer = null;
    final controller = _controller;
    if (controller == null || !controller.dirty) return;
    // EngineController.save() handles bridge errors and leaves `dirty` set, so the next
    // lifecycle pause retries rather than silently dropping the checkpoint.
    await controller.save();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _controller?.removeListener(_onControllerChanged);
    super.dispose();
  }
}

/// Makes the one app-level autosave coordinator reachable from the workspace screen.
class AutosaveScope extends InheritedNotifier<AutosaveCoordinator> {
  const AutosaveScope({
    super.key,
    required AutosaveCoordinator coordinator,
    required super.child,
  }) : super(notifier: coordinator);

  static AutosaveCoordinator? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AutosaveScope>()
      ?.notifier;
}

/// Honest recovery UI after a forced kill (M1.5 task 1.5.4). Every line comes from a field
/// the engine actually reported; no damage is invented and none is hidden by a silent fix.
Future<void> showRecoveryDialog({
  required BuildContext context,
  required RecoveryReport report,
}) async {
  final lines = report.messages;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('recovery-dialog'),
      title: const Text('Workspace recovered'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('MORPHIC repaired the workspace before opening it.'),
          const SizedBox(height: 12),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('• $line'),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('recovery-dismiss-button'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}
