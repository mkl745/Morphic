/// "Why this view?" sheet (M1.4 task 1.4.6).
///
/// The compiler attaches an `explanation` object to *every* component it emits (doc 03 §1
/// rule 5, AT-10). Before this file, exactly one field of it was drawn anywhere: the metric
/// card's `detail`, clamped to two lines behind a tooltip. `reason`, `evidence` and
/// `confidence` crossed the FFI boundary, passed all five validator passes, and were never
/// shown to a person.
///
/// This is **workspace chrome**, not a schema component (doc 04 §2). The affordance lives in
/// the renderer and reads the document; no engine change is needed to display it.
///
/// Honesty rules, because an explanation that invents facts is worse than none:
///  * the raw rule id is shown even when a friendly heading exists — it is the auditable key;
///  * an unknown id is shown as-is, never given a guessed heading;
///  * missing evidence / confidence say so, rather than showing an empty list or 0%;
///  * a component with no explanation at all gets an explicit defect state, not a blank sheet.
library;

import 'package:flutter/material.dart';

import '../design_system/tokens.dart';

/// Human headings for the rule ids in `morphic-compiler`'s `RULE_TABLE`.
///
/// `rule_label_drift_test.dart` reads the Rust table and fails if the sets disagree, so a new
/// rule cannot reach a user with no heading. The values describe *when* the rule fires, not
/// what the product wishes it meant.
const Map<String, String> ruleLabels = <String, String>{
  'R1_records': 'Always included',
  'R2_primary_measure': 'Strongest numeric measure',
  'R2b_error_metric': 'Severity field found',
  'R3_time_series': 'Time axis with a measure',
  'R4_event_timeline': 'Time axis without a measure',
  'R5_category_breakdown': 'Low-cardinality category',
  'R6_raw_table': 'Always included',
};

/// A tolerant read of a document's `explanation` object.
///
/// Tolerant on purpose: the schema says `evidence` is a list of strings and `confidence` a
/// number in 0..1, but a saved workspace can predate this build, and doc 03 §2.1 used to
/// illustrate `evidence` as a list of objects. A malformed field must produce an honest label,
/// not a red error card over perfectly good data.
class ComponentExplanation {
  const ComponentExplanation({
    this.reason = '',
    this.detail = '',
    this.evidence = const <String>[],
    this.confidence,
  });

  factory ComponentExplanation.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const ComponentExplanation();
    final r = map['reason'];
    final d = map['detail'];
    final c = map['confidence'];
    final raw = map['evidence'];
    final items = <String>[];
    if (raw is List) {
      for (final e in raw) {
        if (e == null) continue;
        final text = e is String ? e : e.toString();
        if (text.trim().isNotEmpty) items.add(text);
      }
    }
    double? confidence;
    if (c is num) {
      final value = c.toDouble();
      if (value.isFinite && value >= 0.0 && value <= 1.0) confidence = value;
    }
    return ComponentExplanation(
      reason: r is String ? r : '',
      detail: d is String ? d : '',
      evidence: List<String>.unmodifiable(items),
      confidence: confidence,
    );
  }

  final String reason;
  final String detail;
  final List<String> evidence;
  final double? confidence;

  bool get isEmpty =>
      reason.isEmpty && detail.isEmpty && evidence.isEmpty && confidence == null;

  /// Known rules get a heading; anything else is shown raw rather than guessed at.
  String get heading =>
      ruleLabels[reason] ?? (reason.isEmpty ? 'No rule recorded' : reason);

  String? get confidencePercent {
    final c = confidence;
    return c == null ? null : '${(c * 100).round()}%';
  }
}

Future<void> showExplanationSheet(
  BuildContext context, {
  required String componentTitle,
  required Map<String, dynamic>? explanation,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => WhyThisViewSheet(
        componentTitle: componentTitle,
        explanation: ComponentExplanation.fromMap(explanation),
      ),
    );

/// The one affordance, shared by all five renderers and the structural document view.
///
/// Always present: a component whose explanation is missing should say so when asked, not
/// quietly lose the button that would have revealed the defect.
class ExplanationButton extends StatelessWidget {
  const ExplanationButton({
    super.key,
    required this.id,
    required this.title,
    required this.explanation,
  });

  final String id;
  final String title;
  final Map<String, dynamic>? explanation;

  @override
  Widget build(BuildContext context) => IconButton(
        key: Key('explain-$id'),
        tooltip: 'Why this view?',
        icon: const Icon(Icons.info_outline),
        onPressed: () => showExplanationSheet(
          context,
          componentTitle: title,
          explanation: explanation,
        ),
      );
}

class WhyThisViewSheet extends StatelessWidget {
  const WhyThisViewSheet({
    super.key,
    required this.componentTitle,
    required this.explanation,
  });

  final String componentTitle;
  final ComponentExplanation explanation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          MorphicSpace.lg,
          MorphicSpace.sm,
          MorphicSpace.lg,
          MorphicSpace.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Why this view?',
              key: const Key('why-sheet-title'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: MorphicSpace.xs),
            Text(
              componentTitle,
              key: const Key('why-sheet-component'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: MorphicSpace.lg),
            if (explanation.isEmpty)
              _noExplanation(theme)
            else ...[
              _section(theme, 'Why it was chosen'),
              const SizedBox(height: MorphicSpace.sm),
              Text(
                explanation.heading,
                key: const Key('why-sheet-heading'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: MorphicSpace.xs),
              Text(
                explanation.reason.isEmpty
                    ? 'No rule id was recorded.'
                    : 'Rule ${explanation.reason}',
                key: const Key('why-sheet-rule-id'),
                style: muted,
              ),
              if (explanation.detail.isNotEmpty) ...[
                const SizedBox(height: MorphicSpace.md),
                Text(
                  explanation.detail,
                  key: const Key('why-sheet-detail'),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: MorphicSpace.lg),
              _section(theme, 'What the planner saw'),
              const SizedBox(height: MorphicSpace.sm),
              if (explanation.evidence.isEmpty)
                Text(
                  'No evidence was recorded for this component.',
                  key: const Key('why-sheet-evidence'),
                  style: theme.textTheme.bodySmall,
                )
              else
                ...[
                  for (var i = 0; i < explanation.evidence.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: MorphicSpace.xs),
                      child: Text(
                        '• ${explanation.evidence[i]}',
                        key: Key('why-sheet-evidence-$i'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              const SizedBox(height: MorphicSpace.lg),
              _section(theme, 'Confidence'),
              const SizedBox(height: MorphicSpace.sm),
              _confidence(theme, muted),
            ],
            const SizedBox(height: MorphicSpace.lg),
            Text(
              'These words come from the engine that generated the workspace. '
              'The app does not rewrite them.',
              key: const Key('why-sheet-footer'),
              style: muted,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('why-sheet-close'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(ThemeData theme, String label) => Text(
        label,
        style: theme.textTheme.titleSmall,
      );

  /// An explained component is part of AT-10. A missing one is a document defect, and the
  /// sheet says that instead of quietly looking like a component nobody bothered with.
  Widget _noExplanation(ThemeData theme) => Text(
        'This component carries no explanation. Generated workspaces always explain '
        'themselves, so a missing explanation is a document defect worth reporting.',
        key: const Key('why-sheet-empty'),
        style: theme.textTheme.bodyMedium,
      );

  Widget _confidence(ThemeData theme, TextStyle? muted) {
    final c = explanation.confidence;
    if (c == null) {
      return Text(
        'Not reported',
        key: const Key('why-sheet-confidence'),
        style: theme.textTheme.bodyMedium,
      );
    }
    final label = '${(c * 100).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          key: const Key('why-sheet-confidence'),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: MorphicSpace.sm),
        SizedBox(
          // A Column with `crossAxisAlignment.start` gives loose width constraints; the bar
          // must explicitly span the sheet or it paints as a zero-width sliver.
          width: double.infinity,
          child: Semantics(
            label: 'Planner confidence $label',
            child: LinearProgressIndicator(
              key: const Key('why-sheet-confidence-bar'),
              value: c,
              minHeight: 6,
            ),
          ),
        ),
        const SizedBox(height: MorphicSpace.sm),
        Text(
          'How sure the planner is about the field readings behind this choice, '
          'not about whether the chart is useful.',
          style: muted,
        ),
      ],
    );
  }
}
