import 'package:flutter/material.dart';

import 'design_system/tokens.dart';
import 'engine/bridge.dart';
import 'engine/bridge_scope.dart';
import 'engine/file_source.dart';
import 'engine/import_runner.dart';
import 'features/home/home_screen.dart';
import 'features/import/import_screen.dart';
import 'features/poc/poc_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/workspace/workspace_screen.dart';

class MorphicApp extends StatelessWidget {
  const MorphicApp({
    super.key,
    required this.bridge,
    required this.storageRoot,
    this.importRunner,
    this.fileSource,
  });

  final MorphicBridge bridge;
  final String storageRoot;

  /// Overrides where imports run. Production leaves this null (worker isolate).
  final ImportRunner? importRunner;

  /// Overrides the file picker used by the home library's "Re-link source file" action.
  final PlatformFileSource? fileSource;

  @override
  Widget build(BuildContext context) {
    return BridgeScope(
      bridge: bridge,
      storageRoot: storageRoot,
      importRunner: importRunner,
      child: MaterialApp(
        title: 'MORPHIC',
        debugShowCheckedModeBanner: false,
        theme: MorphicTheme.light(),
        darkTheme: MorphicTheme.dark(),
        themeMode: ThemeMode.dark,
        initialRoute: '/',
        routes: {
          '/': (_) => HomeScreen(fileSource: fileSource),
          '/poc': (_) => const PocScreen(),
          '/import': (_) => const ImportScreen(),
          '/workspace': (_) => WorkspaceScreen(fileSource: fileSource),
          '/settings': (_) => const SettingsScreen(),
        },
      ),
    );
  }
}
