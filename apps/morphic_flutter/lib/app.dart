import 'dart:async';

import 'package:flutter/material.dart';

import 'design_system/tokens.dart';
import 'engine/autosave.dart';
import 'engine/bundle_location.dart';
import 'engine/bridge.dart';
import 'engine/bridge_scope.dart';
import 'engine/file_source.dart';
import 'engine/import_runner.dart';
import 'engine/sample_import.dart';
import 'features/home/home_screen.dart';
import 'features/import/import_screen.dart';
import 'features/poc/poc_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/workspace/workspace_screen.dart';

class MorphicApp extends StatefulWidget {
  const MorphicApp({
    super.key,
    required this.bridge,
    required this.storageRoot,
    this.importRunner,
    this.fileSource,
    this.bundlePathResolver,
    this.bundleWriter,
    this.sampleLauncher,
  });

  final MorphicBridge bridge;
  final String storageRoot;

  /// Overrides where imports run. Production leaves this null (worker isolate).
  final ImportRunner? importRunner;

  /// Overrides the file picker used by the home library's "Re-link source file" action and
  /// the `.morphic` bundle import action.
  final PlatformFileSource? fileSource;

  /// Overrides where exported `.morphic` bundles are written. Production leaves this null.
  final BundlePathResolver? bundlePathResolver;

  /// Overrides the byte sink used by bundle export. Production leaves this null (real disk).
  final BundleWriter? bundleWriter;

  /// Overrides the bundled-sample import/launch path. Production leaves this null.
  final SampleLauncher? sampleLauncher;

  @override
  State<MorphicApp> createState() => _MorphicAppState();
}

/// Owns the autosave lifecycle observer (M1.5 task 1.5.4). A stateful wrapper is required
/// because the observer must be registered once and disposed with the app, not rebuilt.
class _MorphicAppState extends State<MorphicApp>
    with WidgetsBindingObserver {
  final _autosave = AutosaveCoordinator();
  bool _recoveryShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Captured once at process start. An FFI failure here must never stop the app from
    // opening; an empty app is strictly worse than an unshown recovery banner.
    try {
      _autosave.recovery =
          widget.bridge.recoveryReport(widget.storageRoot);
    } catch (_) {
      _autosave.recovery = const RecoveryReport();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // Immediate flush, not a debounce: the process may never resume (doc 06 §2).
      unawaited(_autosave.flushNow());
    }
  }

  @override
  void dispose() {
    unawaited(_autosave.flushNow());
    _autosave.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sampleLauncher = widget.sampleLauncher ??
        EngineSampleLauncher(
          EngineSampleImporter(
            bridge: widget.bridge,
            storageRoot: widget.storageRoot,
            runner: widget.importRunner ?? const IsolateImportRunner(),
          ),
        );
    // Schedule after this build finishes: the banner is shown with the app's navigator,
    // and pushing a route during build would be a framework error.
    if (!_recoveryShown && !_autosave.recovery.isClean) {
      _recoveryShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final nav = _autosave.navigatorKey.currentState;
        if (nav == null) return;
        unawaited(showRecoveryDialog(
          context: nav.context,
          report: _autosave.recovery,
        ));
      });
    }
    return AutosaveScope(
      coordinator: _autosave,
      child: BridgeScope(
        bridge: widget.bridge,
        storageRoot: widget.storageRoot,
        importRunner: widget.importRunner,
        child: MaterialApp(
          navigatorKey: _autosave.navigatorKey,
          title: 'MORPHIC',
          debugShowCheckedModeBanner: false,
          theme: MorphicTheme.light(),
          darkTheme: MorphicTheme.dark(),
          themeMode: ThemeMode.dark,
          initialRoute: '/',
          routes: {
            '/': (_) => HomeScreen(
              fileSource: widget.fileSource,
              bundlePathResolver: widget.bundlePathResolver,
              bundleWriter: widget.bundleWriter,
              sampleLauncher: sampleLauncher,
            ),
            '/poc': (_) => const PocScreen(),
            '/import': (_) => ImportScreen(sampleLauncher: sampleLauncher),
            '/workspace': (_) =>
                WorkspaceScreen(fileSource: widget.fileSource),
            '/settings': (_) => const SettingsScreen(),
          },
        ),
      ),
    );
  }
}
