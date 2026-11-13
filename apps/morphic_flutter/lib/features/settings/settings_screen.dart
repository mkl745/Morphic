import 'package:flutter/material.dart';

import '../../build_info.dart';
import '../../design_system/responsive.dart';
import '../../design_system/theme_preference.dart';
import '../../design_system/tokens.dart';
import '../../engine/bridge_scope.dart';
import '../../engine/file_source.dart';
import '../../engine/import_limits.dart';
import '../../engine/storage_usage.dart';
import '../../runtime/value_format.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.storageUsage});

  /// Allows previews and tests to supply a deterministic measurement.
  final Future<int> Function(String root)? storageUsage;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _root;
  Future<int>? _usage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final root = BridgeScope.of(context).storageRoot;
    if (_root != root) {
      _root = root;
      _usage = (widget.storageUsage ?? measureStorageBytes)(root);
    }
  }

  void _retryUsage() {
    final root = _root;
    if (root != null) {
      final next = (widget.storageUsage ?? measureStorageBytes)(root);
      setState(() {
        _usage = next;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preference = MorphicThemeScope.maybeOf(context);
    final mode = preference?.mode ??
        (theme.brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light);
    const sizeMiB = FilePickerSource.defaultMaxBytes ~/ (1024 * 1024);
    const memoryMiB = ImportLimits.memoryBytes ~/ (1024 * 1024);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: MorphicPageWidth(
        child: ListView(
          padding: const EdgeInsets.all(MorphicSpace.lg),
          children: [
            _SettingsCard(
              title: 'Appearance',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<ThemeMode>(
                    key: ValueKey('theme-picker-${mode.name}'),
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: 'Theme'),
                    items: const [
                      DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                      DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                      DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                    ],
                    onChanged: preference == null
                        ? null
                        : (value) {
                            if (value != null) preference.select(value);
                          },
                  ),
                  const SizedBox(height: MorphicSpace.sm),
                  Text(
                    preference?.message ??
                        (preference == null
                            ? 'Theme controls are available in the app.'
                            : 'Theme choice is stored on this device.'),
                    key: const Key('theme-preference-message'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: preference?.message == null
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: MorphicSpace.md),
            _SettingsCard(
              title: 'Storage',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FutureBuilder<int>(
                    future: _usage,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Could not measure local storage.'),
                            TextButton.icon(
                              key: const Key('storage-retry'),
                              onPressed: _retryUsage,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Try again'),
                            ),
                          ],
                        );
                      }
                      if (!snapshot.hasData) return const Text('Measuring local storage…');
                      return Text(
                        '${formatByteCount(snapshot.data!)} in local files',
                        key: const Key('storage-usage'),
                      );
                    },
                  ),
                  const SizedBox(height: MorphicSpace.xs),
                  Text(
                    'Approximate file lengths in the MORPHIC storage folder, not free space.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: MorphicSpace.xs),
                  SelectableText(
                    _root ?? '',
                    style: MorphicTypography.dataStyle(theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
            const SizedBox(height: MorphicSpace.md),
            _SettingsCard(
              title: 'Import limits',
              child: Text(
                'Files and clipboard text: up to $sizeMiB MiB at once. '
                'The engine defaults allow up to ${groupInteger(ImportLimits.rows)} rows '
                'and ${groupInteger(ImportLimits.columns)} columns, with an estimated '
                '$memoryMiB MiB memory budget. '
                'Some files may reach a limit sooner.',
                key: const Key('import-limits'),
              ),
            ),
            const SizedBox(height: MorphicSpace.md),
            const _SettingsCard(
              title: 'Privacy',
              child: Text(
                'MORPHIC is local-first. In this build no data leaves the device and '
                'no network permission is requested.',
              ),
            ),
            const SizedBox(height: MorphicSpace.md),
            _SettingsCard(
              title: 'About',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('MORPHIC $kAppVersion · $kPhaseLabel'),
                  const SizedBox(height: MorphicSpace.xs),
                  SelectableText(
                    BuildInfo.fromEnvironment.label,
                    key: const Key('about-build'),
                    style: MorphicTypography.dataStyle(theme.textTheme.bodySmall),
                  ),
                  const SizedBox(height: MorphicSpace.xs),
                  Text(
                    BuildInfo.fromEnvironment.explanation,
                    key: const Key('about-build-explanation'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: MorphicSpace.sm),
                  const Text('Your Data. Your Interface.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(MorphicSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: MorphicSpace.sm),
              child,
            ],
          ),
        ),
      );
}
