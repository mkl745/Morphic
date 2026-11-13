/// User corrections to inferred field types/roles (M1.5 task 1.5.5, AT-17).
///
/// The engine owns the closed vocabularies and the recompilation; this file only reads what
/// Rust persisted, shows it, and sends `overrideFieldType` / `overrideFieldRole` /
/// `clearFieldOverride` commands. It never decides what a component should look like. The
/// displayed values are the **effective** ones: the inferred profile with persisted overrides
/// applied, which is exactly what the planner sees after the correction.
library;

import 'package:flutter/material.dart';

import '../design_system/copy.dart';
import '../design_system/tokens.dart';
import '../engine/engine_controller.dart';
import '../engine/interaction.dart';

/// Mirrors `morphic_schema::DATA_TYPES`. Kept as wire values, labelled for humans.
const List<String> kFieldDtypes = [
  'null',
  'bool',
  'int64',
  'float64',
  'utf8',
  'timestamp',
];

const Map<String, String> kFieldDtypeLabels = {
  'null': 'Empty',
  'bool': 'True / false',
  'int64': 'Whole number',
  'float64': 'Decimal number',
  'utf8': 'Text',
  'timestamp': 'Date & time',
};

/// Mirrors `morphic_schema::FIELD_ROLES`.
const List<String> kFieldRoles = [
  'unknown',
  'temporal',
  'measure',
  'dimension',
  'severity',
  'identifier',
  'text',
];

const Map<String, String> kFieldRoleLabels = {
  'unknown': 'Unknown',
  'temporal': 'Time axis',
  'measure': 'Measure',
  'dimension': 'Category',
  'severity': 'Severity',
  'identifier': 'Identifier',
  'text': 'Free text',
};

/// The planner's view of one field: what the data inferred, and what the user corrected.
class FieldFacts {
  const FieldFacts({
    required this.name,
    required this.inferredDtype,
    required this.inferredRole,
    required this.dtype,
    required this.role,
    required this.overridden,
  });

  final String name;
  final String inferredDtype;
  final String inferredRole;
  final String dtype;
  final String role;
  final bool overridden;
}

/// Column names in the order Rust's profile chose. An empty list means degraded mode, where
/// there is no live profile to correct.
List<String> workspaceFields(EngineController engine) {
  final fields = (engine.profile?['fields'] as List? ?? const [])
      .whereType<Map<String, dynamic>>();
  return fields
      .map((f) => f['name'] as String? ?? '')
      .where((name) => name.isNotEmpty)
      .toList();
}

FieldFacts fieldFacts(EngineController engine, String name) {
  var inferredDtype = 'utf8';
  var inferredRole = 'unknown';
  for (final f in (engine.profile?['fields'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()) {
    if (f['name'] == name) {
      inferredDtype = f['dtype'] as String? ?? inferredDtype;
      final inference = f['inference'];
      if (inference is Map) {
        inferredRole = inference['role'] as String? ?? inferredRole;
      }
      break;
    }
  }
  var dtype = inferredDtype;
  var role = inferredRole;
  var overridden = false;
  final ws = engine.doc?['workspace'];
  if (ws is Map) {
    for (final o in (ws['fieldOverrides'] as List? ?? const [])) {
      if (o is Map && o['field'] == name) {
        dtype = o['dtype'] as String? ?? dtype;
        role = o['role'] as String? ?? role;
        overridden = true;
      }
    }
  }
  return FieldFacts(
    name: name,
    inferredDtype: inferredDtype,
    inferredRole: inferredRole,
    dtype: dtype,
    role: role,
    overridden: overridden,
  );
}

/// Open the correction sheet. [field] focuses one column (the long-press on a table header);
/// null lets the user pick any field in the profile.
Future<void> showFieldCorrectionsSheet(
  BuildContext context, {
  required EngineController engine,
  String? field,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FieldCorrectionsSheet(engine: engine, field: field),
  );
}

class FieldCorrectionsSheet extends StatefulWidget {
  const FieldCorrectionsSheet({
    super.key,
    required this.engine,
    this.field,
  });

  final EngineController engine;
  final String? field;

  @override
  State<FieldCorrectionsSheet> createState() => _FieldCorrectionsSheetState();
}

class _FieldCorrectionsSheetState extends State<FieldCorrectionsSheet> {
  late String _field;
  late String _dtype;
  late String _role;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final fields = workspaceFields(widget.engine);
    final requested = widget.field;
    _field = fields.isEmpty
        ? ''
        : (requested != null && fields.contains(requested) ? requested : fields.first);
    final facts = fieldFacts(widget.engine, _field);
    _dtype = facts.dtype;
    _role = facts.role;
  }

  FieldFacts get _facts => fieldFacts(widget.engine, _field);

  Future<void> _apply() async {
    if (_busy || _field.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final facts = _facts;
    final commands = <Map<String, dynamic>>[];
    // Compare against the *effective* values, not the inference: an override record can hold
    // just a dtype or just a role, so returning one dimension to its inferred value still has
    // to send a command or the stale half of the record would survive.
    if (_dtype != facts.dtype) {
      commands.add(Commands.overrideFieldType(_field, _dtype));
    }
    if (_role != facts.role) {
      commands.add(Commands.overrideFieldRole(_field, _role));
    }
    // When both dimensions are back to the inference, remove the record entirely so the
    // document honestly records "no correction" rather than a redundant one.
    if (commands.isEmpty &&
        facts.overridden &&
        _dtype == facts.inferredDtype &&
        _role == facts.inferredRole) {
      commands.add(Commands.clearFieldOverride(_field));
    }
    if (commands.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _busy = true);
    final affected = await widget.engine.applyCommands(commands);
    if (!mounted) return;
    setState(() => _busy = false);
    if (affected == null) {
      messenger.showSnackBar(SnackBar(
        content: Text(widget.engine.error ?? 'The engine rejected the correction'),
      ));
      return;
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Field correction applied')),
    );
    Navigator.of(context).pop();
  }

  Future<void> _clear() async {
    if (_busy || _field.isEmpty || !_facts.overridden) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final affected = await widget.engine.applyCommands(
      [Commands.clearFieldOverride(_field)],
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (affected == null) {
      messenger.showSnackBar(SnackBar(
        content: Text(widget.engine.error ?? 'The engine rejected the reset'),
      ));
      return;
    }
    final inferred = _facts;
    setState(() {
      _dtype = inferred.inferredDtype;
      _role = inferred.inferredRole;
    });
    messenger.showSnackBar(
      const SnackBar(content: Text('Restored the inferred field type')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fields = workspaceFields(widget.engine);
    final facts = _facts;
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          key: const Key('field-corrections-sheet'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Correct a field', style: theme.textTheme.titleMedium),
            const SizedBox(height: MorphicSpace.sm),
            Text(
              'Morphic recompiles only the views that read this field. The imported '
              'data is not changed.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: MorphicSpace.md),
            if (fields.isEmpty) ...[
              Text('No field profile is available for this workspace.',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: MorphicSpace.sm),
              Text(
                widget.engine.degraded
                    ? MorphicCopy.noProfileDegradedDetail
                    : MorphicCopy.noProfileDetail,
                style: theme.textTheme.bodySmall,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('field-correction-close'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ),
            ] else ...[
              DropdownButton<String>(
                key: const Key('field-name-dropdown'),
                value: _field,
                isExpanded: true,
                items: [
                  for (final name in fields)
                    DropdownMenuItem<String>(value: name, child: Text(name)),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value == null) return;
                        final next = fieldFacts(widget.engine, value);
                        setState(() {
                          _field = value;
                          _dtype = next.dtype;
                          _role = next.role;
                        });
                      },
              ),
              const SizedBox(height: MorphicSpace.md),
              Text(
                'Inferred: ${kFieldDtypeLabels[facts.inferredDtype] ?? facts.inferredDtype}'
                ' · ${kFieldRoleLabels[facts.inferredRole] ?? facts.inferredRole}'
                '${facts.overridden ? "  ·  corrected" : ""}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: MorphicSpace.sm),
              Text('Treat values as', style: theme.textTheme.labelLarge),
              Wrap(
                spacing: MorphicSpace.sm,
                children: [
                  for (final dtype in kFieldDtypes)
                    ChoiceChip(
                      key: Key('field-dtype-$dtype'),
                      label: Text(kFieldDtypeLabels[dtype] ?? dtype),
                      selected: _dtype == dtype,
                      onSelected: _busy ? null : (_) => setState(() => _dtype = dtype),
                    ),
                ],
              ),
              const SizedBox(height: MorphicSpace.md),
              Text('Use the field as', style: theme.textTheme.labelLarge),
              Wrap(
                spacing: MorphicSpace.sm,
                children: [
                  for (final role in kFieldRoles)
                    ChoiceChip(
                      key: Key('field-role-$role'),
                      label: Text(kFieldRoleLabels[role] ?? role),
                      selected: _role == role,
                      onSelected: _busy ? null : (_) => setState(() => _role = role),
                    ),
                ],
              ),
              const SizedBox(height: MorphicSpace.lg),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: MorphicSpace.sm,
                  runSpacing: MorphicSpace.xs,
                  children: [
                    if (facts.overridden)
                      TextButton(
                        key: const Key('field-correction-clear'),
                        onPressed: _busy ? null : _clear,
                        child: const Text('Reset'),
                      ),
                    TextButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      key: const Key('field-correction-apply'),
                      onPressed: _busy ? null : _apply,
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
