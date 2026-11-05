import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../../engine/bridge.dart';
import '../../engine/bridge_scope.dart';

/// Home is a lightweight gateway (spec §10.1): engine status, the import/PoC action,
/// and recent workspaces. The workspace itself is the product, not this screen.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<EngineInfo>? _engineInfo;
  Future<List<dynamic>>? _workspaces;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final scope = BridgeScope.of(context);
      _engineInfo = Future(() => scope.bridge.engineInfo());
      _workspaces = Future(() => scope.bridge.listWorkspaces(scope.storageRoot));
    }
  }

  void _reloadWorkspaces() {
    final scope = BridgeScope.of(context);
    setState(() {
      _workspaces = Future(() => scope.bridge.listWorkspaces(scope.storageRoot));
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MORPHIC'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        children: [
          Text(
            'Your Data. Your Interface.',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: MorphicColors.textSecondaryDark),
          ),
          const SizedBox(height: MorphicSpace.lg),
          _EngineStatusCard(future: _engineInfo),
          const SizedBox(height: MorphicSpace.lg),
          FilledButton.icon(
            onPressed: () async {
              await Navigator.of(context).pushNamed('/poc');
              _reloadWorkspaces();
            },
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Run proof of concept'),
          ),
          const SizedBox(height: MorphicSpace.xl),
          Text('Recent workspaces', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: MorphicSpace.sm),
          _WorkspaceList(future: _workspaces),
          const SizedBox(height: MorphicSpace.xl),
          Row(
            children: [
              Icon(Icons.lock_outline, size: 16, color: scheme.primary),
              const SizedBox(width: MorphicSpace.sm),
              Expanded(
                child: Text(
                  'All processing happens on this device.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EngineStatusCard extends StatelessWidget {
  const _EngineStatusCard({required this.future});
  final Future<EngineInfo>? future;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: FutureBuilder<EngineInfo>(
          future: future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: MorphicSpace.md),
                  Text('Starting Rust engine…'),
                ],
              );
            }
            if (snap.hasError) {
              return Row(
                children: [
                  const Icon(Icons.error_outline, color: MorphicColors.error),
                  const SizedBox(width: MorphicSpace.md),
                  Expanded(child: Text('Engine unavailable: ${snap.error}')),
                ],
              );
            }
            final info = snap.data!;
            return Row(
              children: [
                Icon(Icons.memory, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: MorphicSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Rust engine connected',
                          style: Theme.of(context).textTheme.titleSmall),
                      Text(
                        'core ${info.coreVersion} · bridge API v${info.apiVersion}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _WorkspaceList extends StatelessWidget {
  const _WorkspaceList({required this.future});
  final Future<List<dynamic>>? future;

  @override
  Widget build(BuildContext context) {
    final scope = BridgeScope.of(context);
    return FutureBuilder<List<dynamic>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(MorphicSpace.md),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (snap.hasError) {
          return Text('Could not load workspaces: ${snap.error}');
        }
        final items = snap.data ?? [];
        if (items.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(MorphicSpace.lg),
              child: Text(
                'No workspaces yet. Run the proof of concept to generate one from data.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          );
        }
        return Column(
          children: [
            for (final item in items)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.dashboard_outlined),
                  title: Text((item as Map)['title'] as String? ?? 'Workspace'),
                  subtitle: Text(item['id'] as String? ?? ''),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    final doc = scope.bridge.loadWorkspace(
                      storageRoot: scope.storageRoot,
                      workspaceId: item['id'] as String,
                    );
                    Navigator.of(context)
                        .pushNamed('/workspace', arguments: doc);
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}
