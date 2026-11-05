import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../../engine/bridge_scope.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = BridgeScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(MorphicSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Privacy', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: MorphicSpace.sm),
                  const Text(
                    'MORPHIC is local-first. In this build no data leaves the device and '
                    'no network permission is requested.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: MorphicSpace.md),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(MorphicSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Storage', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: MorphicSpace.sm),
                  Text(scope.storageRoot,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
          const SizedBox(height: MorphicSpace.md),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(MorphicSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('About', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: MorphicSpace.sm),
                  const Text('MORPHIC 0.1.0 · Phase 0 proof of concept'),
                  const Text('Your Data. Your Interface.'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
