import 'package:flutter/material.dart';

import 'design_system/tokens.dart';
import 'engine/bridge.dart';
import 'engine/bridge_scope.dart';
import 'features/home/home_screen.dart';
import 'features/import/import_screen.dart';
import 'features/poc/poc_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/workspace/workspace_screen.dart';

class MorphicApp extends StatelessWidget {
  const MorphicApp({super.key, required this.bridge, required this.storageRoot});

  final MorphicBridge bridge;
  final String storageRoot;

  @override
  Widget build(BuildContext context) {
    return BridgeScope(
      bridge: bridge,
      storageRoot: storageRoot,
      child: MaterialApp(
        title: 'MORPHIC',
        debugShowCheckedModeBanner: false,
        theme: MorphicTheme.light(),
        darkTheme: MorphicTheme.dark(),
        themeMode: ThemeMode.dark,
        initialRoute: '/',
        routes: {
          '/': (_) => const HomeScreen(),
          '/poc': (_) => const PocScreen(),
          '/import': (_) => const ImportScreen(),
          '/workspace': (_) => const WorkspaceScreen(),
          '/settings': (_) => const SettingsScreen(),
        },
      ),
    );
  }
}
