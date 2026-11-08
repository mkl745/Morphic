import 'package:flutter/material.dart';

import '../../build_info.dart';
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
                  const Text('MORPHIC $kAppVersion · $kPhaseLabel'),
                  const SizedBox(height: MorphicSpace.xs),
                  // Selectable so a tester can copy the exact build into a bug report instead
                  // of retyping a SHA.
                  SelectableText(
                    BuildInfo.fromEnvironment.label,
                    key: const Key('about-build'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: MorphicSpace.xs),
                  Text(
                    BuildInfo.fromEnvironment.explanation,
                    key: const Key('about-build-explanation'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.color
                              ?.withValues(alpha: 0.7),
                        ),
                  ),
                  const SizedBox(height: MorphicSpace.sm),
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
