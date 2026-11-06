/// Explicit placeholder for a component the runtime cannot draw yet (M1.1 task 1.1.5).
///
/// The compiler already emits `line_chart`, `bar_chart`, and `timeline`; their painters land
/// in M1.4. Rather than dropping them — which would make a generated workspace look emptier
/// than it is — each is labelled with what it is and when it renders. The engine's own
/// explanation is still shown, so the user can see *why* the component was chosen.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../component_registry.dart';

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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(MorphicSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(status.icon, color: theme.colorScheme.primary),
                const SizedBox(width: MorphicSpace.md),
                Expanded(
                  child: Text(ctx.title, style: theme.textTheme.titleSmall),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: MorphicSpace.sm, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(MorphicRadius.sm),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: Text(ctx.type, style: theme.textTheme.labelSmall),
                ),
              ],
            ),
            const SizedBox(height: MorphicSpace.sm),
            Text(
              status.headline,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: MorphicColors.warning),
            ),
            const SizedBox(height: MorphicSpace.xs),
            Text(status.detail, style: theme.textTheme.bodySmall),
            if (explanation != null && explanation.isNotEmpty) ...[
              const SizedBox(height: MorphicSpace.sm),
              Text('Why this was generated: $explanation',
                  style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
