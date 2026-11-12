/// Workspace-wide filter bar (M1.3 task 1.3.4).
///
/// Every chip here narrows **every** bound component, because Rust composes each page and
/// metric as global ∧ component ∧ binding. The bar therefore renders `engine.globalFilters`
/// and sends `SetGlobalFilter` with the whole resulting set — add, edit, remove and clear-all
/// are all the same command, so there is no index-based mutation whose index could go stale
/// between the tap and the apply.
library;

import 'package:flutter/material.dart';

import '../design_system/copy.dart';
import '../design_system/tokens.dart';
import '../engine/engine_controller.dart';
import '../engine/interaction.dart';
import 'components/table_filter_menu.dart';

/// The fields a workspace filter can name, with the type and frequent values that decide
/// which operators are offered. Empty in degraded mode: with no profile there is nothing
/// honest to offer, and the bar disables Add rather than inventing a field list.
List<FilterField> workspaceFilterFields(EngineController engine) => [
      for (final name in engine.fieldNames)
        FilterField(
          name,
          fieldKindOf(engine.dtypeOf(name)),
          suggestions: engine.topValuesOf(name),
        ),
    ];

/// Opens the workspace filter menu. [editing] seeds it with an existing chip; the returned
/// node is the user's choice, or null when they dismissed it, or a cleared choice when they
/// pressed Clear. Shared by the bar and by a metric card with no filter of its own.
Future<FilterChoice?> showWorkspaceFilterMenu(
  BuildContext context,
  EngineController engine, {
  Map<String, dynamic>? editing,
}) {
  final fields = workspaceFilterFields(engine);
  if (fields.isEmpty) return Future.value(null);
  final field = editing?['field'] as String? ?? fields.first.name;
  final known = fields.where((f) => f.name == field);
  final chosen = known.isEmpty ? fields.first : known.first;
  return showColumnFilterMenu(
    context,
    field: chosen.name,
    kind: chosen.kind,
    current: editing,
    suggestions: chosen.suggestions,
    fields: fields,
  );
}

class GlobalFilterBar extends StatefulWidget {
  const GlobalFilterBar({super.key, required this.engine});

  final EngineController engine;

  @override
  State<GlobalFilterBar> createState() => _GlobalFilterBarState();
}

class _GlobalFilterBarState extends State<GlobalFilterBar> {
  bool _busy = false;
  String? _error;

  List<Map<String, dynamic>> get _filters => widget.engine.globalFilters;

  Future<void> _send(List<Map<String, dynamic>> next) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final affected = await widget.engine.applyCommands([Commands.setGlobalFilter(next)]);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = affected == null ? widget.engine.error : null;
    });
  }

  Future<void> _addOrEdit({int? index}) async {
    if (_busy) return;
    final current = index == null ? null : _filters[index];
    final choice = await showWorkspaceFilterMenu(context, widget.engine, editing: current);
    if (choice == null || !mounted) return;
    final next = index == null
        ? (choice.cleared ? _filters : [..._filters, if (choice.filter != null) choice.filter!])
        : editedFilters(_filters, index, choice.cleared ? null : choice.filter);
    await _send(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filters = _filters;
    final canAdd = widget.engine.fieldNames.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: MorphicSpace.xs,
          runSpacing: MorphicSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.filter_alt_outlined, size: 16, color: theme.hintColor),
            for (var i = 0; i < filters.length; i++)
              InputChip(
                key: Key('global-filter-$i'),
                label: Text(describeFilter(filters[i])),
                tooltip: 'Tap to edit this workspace filter',
                onPressed: _busy ? null : () => _addOrEdit(index: i),
                onDeleted: _busy ? null : () => _send(editedFilters(filters, i, null)),
              ),
            Tooltip(
              message: canAdd
                  ? 'Narrow every component in this workspace'
                  : 'The engine has no field information for this workspace, '
                      'so there is nothing to filter on.',
              child: TextButton.icon(
                key: const Key('global-filter-add'),
                onPressed: _busy || !canAdd ? null : () => _addOrEdit(),
                icon: const Icon(Icons.add, size: 16),
                label: Text(filters.isEmpty ? 'Filter workspace' : 'Add filter'),
              ),
            ),
            if (filters.isNotEmpty)
              TextButton(
                key: const Key('global-filter-clear'),
                onPressed: _busy ? null : () => _send(const []),
                child: const Text('Clear all'),
              ),
          ],
        ),
        if (filters.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: MorphicSpace.xs),
            child: Text(
              'Applied to every component in this workspace.',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
            ),
          ),
        if (_error != null)
          MorphicCommandError(evidence: _error!),
      ],
    );
  }
}
