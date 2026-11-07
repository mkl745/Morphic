/// Per-column filter menu (M1.3 task 1.3.3).
///
/// Type-aware: a number offers comparisons, a boolean offers is/is-not, a timestamp offers
/// date bounds with a picker, and text offers contains/equals/one-of with the engine's own
/// frequent values as suggestions. Every type offers the null tests, which need no value.
///
/// The menu builds a **filter node** and hands it back. It never touches a row: applying it is
/// a command to Rust, and the rows come back from the engine.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../../engine/interaction.dart';

/// One field the workspace-wide menu can offer, with the type and suggestions that decide
/// which operators make sense for it.
class FilterField {
  const FilterField(this.name, this.kind, {this.suggestions = const []});

  final String name;
  final FieldKind kind;
  final List<String> suggestions;
}

/// What the user chose. Dismissing the sheet returns null, which is different from clearing:
/// one leaves the filter alone, the other removes it.
class FilterChoice {
  const FilterChoice.set(Map<String, dynamic> this.filter) : cleared = false;
  const FilterChoice.clear()
      : filter = null,
        cleared = true;

  final Map<String, dynamic>? filter;
  final bool cleared;
}

Future<FilterChoice?> showColumnFilterMenu(
  BuildContext context, {
  required String field,
  required FieldKind kind,
  Map<String, dynamic>? current,
  List<String> suggestions = const [],
  List<FilterField> fields = const [],
}) =>
    showModalBottomSheet<FilterChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _FilterMenu(
        field: field,
        kind: kind,
        current: current,
        suggestions: suggestions,
        fields: fields,
      ),
    );

class _FilterMenu extends StatefulWidget {
  const _FilterMenu({
    required this.field,
    required this.kind,
    required this.current,
    required this.suggestions,
    required this.fields,
  });

  final String field;
  final FieldKind kind;
  final Map<String, dynamic>? current;
  final List<String> suggestions;

  /// Non-empty only for a workspace filter, where the field is the user's choice rather than
  /// the column they tapped. A column menu never shows a field picker.
  final List<FilterField> fields;

  @override
  State<_FilterMenu> createState() => _FilterMenuState();
}

class _FilterMenuState extends State<_FilterMenu> {
  late String _field = widget.field;
  late FieldKind _kind = widget.kind;
  late List<String> _suggestions = widget.suggestions;
  late List<FilterOperator> _ops = operatorsFor(widget.kind);
  late String _op;
  late final TextEditingController _value;

  bool get _workspaceWide => widget.fields.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Editing a chip whose field the profile no longer lists (a renamed column, or degraded
    // mode) must still open. Resolve the field *before* choosing an operator, or the operator
    // would be picked from the wrong type's list.
    if (_workspaceWide && !widget.fields.any((f) => f.name == _field)) {
      final first = widget.fields.first;
      _field = first.name;
      _kind = first.kind;
      _suggestions = first.suggestions;
      _ops = operatorsFor(first.kind);
    }
    final existingOp = widget.current?['op'] as String?;
    // A filter the menu cannot express (an `or`, say) still opens, on the first operator,
    // rather than crashing on a dropdown value that is not in its items.
    _op = _ops.any((o) => o.op == existingOp) ? existingOp! : _ops.first.op;
    final v = widget.current?['value'];
    final text = v is List ? v.join(', ') : (v?.toString() ?? '');
    // A boolean choices widget always *shows* one of its two options, so the bound has to
    // start as that option. Leaving it empty would display "True" while Apply stayed disabled.
    _value = TextEditingController(
      text: text.isEmpty && _kind == FieldKind.boolean ? 'true' : text,
    );
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  FilterOperator get _selected => _ops.firstWhere((o) => o.op == _op);

  /// Changing the field changes what can be asked of it. An operator the new type cannot mean
  /// falls back to its first, rather than leaving a dropdown value that is not in its items.
  void _selectField(String name) {
    final choice = widget.fields.firstWhere((f) => f.name == name);
    setState(() {
      _field = choice.name;
      _kind = choice.kind;
      _suggestions = choice.suggestions;
      _ops = operatorsFor(choice.kind);
      if (!_ops.any((o) => o.op == _op)) _op = _ops.first.op;
      if (choice.kind == FieldKind.boolean && _value.text.trim().isEmpty) {
        _value.text = 'true';
      }
    });
  }

  bool get _canApply {
    if (!_selected.needsValue) return true;
    if (_op == 'in') return _splitValues().isNotEmpty;
    return coerceBound(_kind, _value.text) != null;
  }

  List<String> _splitValues() => _value.text
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  void _apply() {
    if (!_canApply) return;
    final Map<String, dynamic> node;
    if (!_selected.needsValue) {
      node = filterNode(_op, field: _field);
    } else if (_op == 'in') {
      node = filterNode(_op, field: _field, value: _splitValues());
    } else {
      node = filterNode(
        _op,
        field: _field,
        value: coerceBound(_kind, _value.text),
      );
    }
    Navigator.of(context).pop(FilterChoice.set(node));
  }

  Future<void> _pickDate() async {
    final now = DateTime.now().toUtc();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_value.text)?.toUtc() ?? now,
      firstDate: DateTime.utc(1970),
      lastDate: DateTime.utc(2100),
    );
    if (picked == null || !mounted) return;
    final m = picked.month.toString().padLeft(2, '0');
    final d = picked.day.toString().padLeft(2, '0');
    // A date-only bound means midnight UTC at the start of that day; the engine says so, and
    // the hint below repeats it rather than letting the user guess.
    _value.text = '${picked.year}-$m-$d';
    setState(() {});
  }

  String get _hint {
    switch (_kind) {
      case FieldKind.integer:
        return 'Whole number';
      case FieldKind.decimal:
        return 'Number';
      case FieldKind.timestamp:
        return 'YYYY-MM-DD (UTC, start of day)';
      case FieldKind.boolean:
      case FieldKind.text:
      case FieldKind.unknown:
        return _op == 'in' ? 'Values, separated by commas' : 'Value';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsValue = _selected.needsValue;
    return Padding(
      padding: EdgeInsets.only(
        left: MorphicSpace.lg,
        right: MorphicSpace.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + MorphicSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _workspaceWide ? 'Filter the whole workspace' : 'Filter $_field',
              style: theme.textTheme.titleMedium,
            ),
            if (_workspaceWide) ...[
              const SizedBox(height: MorphicSpace.md),
              DropdownButton<String>(
                key: const Key('filter-field'),
                value: _field,
                isExpanded: true,
                items: [
                  for (final f in widget.fields)
                    DropdownMenuItem<String>(value: f.name, child: Text(f.name)),
                ],
                onChanged: (v) {
                  if (v != null) _selectField(v);
                },
              ),
            ],
            const SizedBox(height: MorphicSpace.md),
            DropdownButton<String>(
              key: const Key('filter-operator'),
              value: _op,
              isExpanded: true,
              items: [
                for (final o in _ops)
                  DropdownMenuItem<String>(value: o.op, child: Text(o.label)),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _op = v);
              },
            ),
            if (needsValue) ...[
              const SizedBox(height: MorphicSpace.md),
              if (_kind == FieldKind.boolean)
                DropdownButton<String>(
                  key: const Key('filter-bool'),
                  value: _value.text.toLowerCase() == 'false' ? 'false' : 'true',
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'true', child: Text('True')),
                    DropdownMenuItem(value: 'false', child: Text('False')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _value.text = v);
                  },
                )
              else
                TextField(
                  key: const Key('filter-value'),
                  controller: _value,
                  keyboardType: _kind == FieldKind.integer ||
                          _kind == FieldKind.decimal
                      ? const TextInputType.numberWithOptions(
                          signed: true, decimal: true)
                      : TextInputType.text,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: _hint,
                    border: const OutlineInputBorder(),
                    suffixIcon: _kind == FieldKind.timestamp
                        ? IconButton(
                            key: const Key('filter-date'),
                            onPressed: _pickDate,
                            icon: const Icon(Icons.event),
                            tooltip: 'Pick a date',
                          )
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _apply(),
                ),
              if (_suggestions.isNotEmpty) ...[
                const SizedBox(height: MorphicSpace.sm),
                Text('Frequent values', style: theme.textTheme.labelSmall),
                const SizedBox(height: MorphicSpace.xs),
                Wrap(
                  spacing: MorphicSpace.xs,
                  runSpacing: MorphicSpace.xs,
                  children: [
                    for (final s in _suggestions.take(12))
                      ActionChip(
                        label: Text(s),
                        onPressed: () {
                          setState(() {
                            if (_op == 'in' && _value.text.trim().isNotEmpty) {
                              final parts = _splitValues();
                              if (!parts.contains(s)) parts.add(s);
                              _value.text = parts.join(', ');
                            } else {
                              _value.text = s;
                            }
                          });
                        },
                      ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: MorphicSpace.lg),
            Row(
              children: [
                TextButton(
                  key: const Key('filter-clear'),
                  onPressed: widget.current == null
                      ? null
                      : () => Navigator.of(context).pop(const FilterChoice.clear()),
                  child: const Text('Clear'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: MorphicSpace.sm),
                FilledButton(
                  key: const Key('filter-apply'),
                  onPressed: _canApply ? _apply : null,
                  child: const Text('Apply'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
