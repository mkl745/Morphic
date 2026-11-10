/// The 1.4.7 "Change view" affordance (docs/architecture/04 §4).
///
/// The menu is **engine-authoritative**: `EngineController.typeOptionsFor` comes straight
/// from Rust's compatibility matrix, computed against the live dataset profile. A switch the
/// engine would refuse is never offered. In degraded mode (no profile) the list is empty and
/// this widget occupies no space at all, which also keeps the chart goldens byte-identical —
/// a scripted bridge that predates the field simply gets no button.
///
/// `data_table -> chart` asks for confirmation, because that direction invents a default
/// binding from the profile rather than carrying the old one across. The raw rows remain one
/// switch back, and the dialog says so.
library;

import 'package:flutter/material.dart';

import '../engine/engine_controller.dart';
import '../engine/interaction.dart';

/// Human names for the closed registry. Drift-gated against Rust's `ACTIVE_COMPONENTS`, so
/// a new registered type cannot reach the menu as a bare snake_case id.
const Map<String, String> componentTypeLabels = <String, String>{
  'metric_card': 'Metric card',
  'data_table': 'Data table',
  'bar_chart': 'Bar chart',
  'line_chart': 'Line chart',
  'timeline': 'Timeline',
};

const Set<String> _chartTypes = <String>{
  'bar_chart',
  'line_chart',
  'timeline',
};

String componentTypeLabel(String type) =>
    componentTypeLabels[type] ?? type;

class ChangeTypeButton extends StatefulWidget {
  const ChangeTypeButton({
    super.key,
    required this.engine,
    required this.id,
    required this.type,
  });

  final EngineController engine;
  final String id;
  final String type;

  @override
  State<ChangeTypeButton> createState() => _ChangeTypeButtonState();
}

class _ChangeTypeButtonState extends State<ChangeTypeButton> {
  bool _busy = false;

  Future<bool> _confirm(String target) async {
    if (widget.type != 'data_table' || !_chartTypes.contains(target)) {
      return true;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('change-type-confirm'),
        title: const Text('Switch to a chart?'),
        content: Text(
          'The engine will propose a default ${componentTypeLabel(target)} binding '
          'from the dataset profile, because a chart cannot show every column. '
          'You can switch back to the data table at any time.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('change-type-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('change-type-confirm-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _change(String target) async {
    if (_busy) return;
    final confirmed = await _confirm(target);
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final engine = widget.engine;
    setState(() => _busy = true);
    final affected = await engine.applyCommands(<Map<String, dynamic>>[
      Commands.changeComponentType(widget.id, target),
    ]);
    if (!mounted) return;
    setState(() => _busy = false);
    if (affected == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            engine.error ?? 'The engine refused this switch.',
            key: const Key('change-type-error'),
          ),
        ),
      );
    } else {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('View changed.', key: Key('change-type-done')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.engine.typeOptionsFor(widget.id);
    if (options.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      key: Key('change-type-${widget.id}'),
      tooltip: 'Change view',
      enabled: !_busy,
      icon: const Icon(Icons.swap_horiz),
      onSelected: _busy
          ? null
          : (String value) {
              _change(value);
            },
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        for (final option in options)
          PopupMenuItem<String>(
            key: Key('change-type-option-$option'),
            value: option,
            child: Text(componentTypeLabel(option)),
          ),
      ],
    );
  }
}
