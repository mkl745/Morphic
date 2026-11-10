/// Explicit placeholder for a component the runtime cannot draw yet (M1.1 task 1.1.5).
///
/// As of 1.4.4 every type schema v1.0 accepts has a painter, so this widget no longer appears for
/// a valid document. It stays because the runtime must never silently drop a component: a reserved
/// id means the document failed validation, and an unknown one may come from a newer MORPHIC.
/// Either way the component is labelled with what it is, rather than making the workspace look
/// emptier than it is.
///
/// Deliberately **compact**: a generated workspace can contain several of these above the
/// data table, and a wall of "not implemented" cards would push the actual data off screen.
/// The headline stays visible; the long explanation is behind a tap.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../component_registry.dart';
import '../explanation_sheet.dart';

class DeferredComponent extends StatelessWidget {
  const DeferredComponent({super.key, required this.ctx});

  final ComponentContext ctx;

  /// Distinguishes "scheduled later" from "reserved" from "we don't know this type".
  /// These are different situations and must not share one vague message.
  ({String headline, String detail, IconData icon}) _status() {
    final type = ctx.type;
    if (deferredUntil.containsKey(type)) {
      return (
        headline: '$type renders in ${deferredUntil[type]}',
        detail: 'The engine generated this component and its data binding is valid. '
            'The painter is not implemented yet, so no chart is drawn here.',
        icon: _iconFor(type),
      );
    }
    if (reservedComponentTypes.contains(type)) {
      return (
        headline: '$type is reserved',
        detail: 'This id is reserved for a later phase and is rejected by the v1 validator. '
            'Its presence means the document did not pass validation.',
        icon: Icons.lock_outline,
      );
    }
    return (
      headline: 'Unknown component type “$type”',
      detail: 'This runtime does not recognise the type. The document may have been '
          'produced by a newer version of MORPHIC.',
      icon: Icons.help_outline,
    );
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'bar_chart':
        return Icons.bar_chart;
      case 'line_chart':
        return Icons.show_chart;
      case 'timeline':
        return Icons.timeline;
      default:
        return Icons.widgets_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _status();
    final explanation = ctx.explanation['detail'] as String?;
    final isDeferred = deferredUntil.containsKey(ctx.type);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(status.icon, color: theme.colorScheme.primary),
        title: Text(ctx.title, style: theme.textTheme.titleSmall),
        subtitle: Text(
          status.headline,
          style: theme.textTheme.bodySmall?.copyWith(
            color: isDeferred ? MorphicColors.warning : MorphicColors.error,
          ),
        ),
        tilePadding: const EdgeInsets.symmetric(horizontal: MorphicSpace.lg),
        childrenPadding: const EdgeInsets.fromLTRB(
            MorphicSpace.lg, 0, MorphicSpace.lg, MorphicSpace.lg),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status.detail, style: theme.textTheme.bodySmall),
          if (explanation != null && explanation.isNotEmpty) ...[
            const SizedBox(height: MorphicSpace.sm),
            Text('Why this was generated: $explanation',
                style: theme.textTheme.bodySmall),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('explain-${ctx.id}'),
              icon: const Icon(Icons.info_outline, size: 18),
              label: const Text('Why this view?'),
              onPressed: () => showExplanationSheet(
                context,
                componentTitle: ctx.title,
                explanation: ctx.explanation,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
