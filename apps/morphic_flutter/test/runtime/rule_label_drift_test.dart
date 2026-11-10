/// Keeps the human-facing rule headings in step with the planner's `RULE_TABLE`.
///
/// Same idea as `registry_drift_test.dart`: read the Rust source rather than a copy of the
/// list. A new rule that reaches a user with no heading would show a bare `R7_something`,
/// and an old heading whose rule was removed would describe a rule that never fires. Both
/// are silent UI regressions, so both fail the build here.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/runtime/explanation_sheet.dart';

Set<String> rustRuleIds(String source) {
  final start = source.indexOf('pub const RULE_TABLE: &[Rule] = &[');
  expect(start, greaterThanOrEqualTo(0),
      reason: 'RULE_TABLE not found in morphic-compiler');
  final open = source.indexOf('[', source.indexOf('= &[', start));
  final close = source.indexOf('];', open);
  expect(close, greaterThan(open), reason: 'RULE_TABLE array is not closed');
  final body = source.substring(open + 1, close);
  return RegExp(r'id:\s*"([^"]+)"')
      .allMatches(body)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  // `flutter test` runs with the package directory as cwd.
  final compilerFile = File('../../engine/crates/morphic-compiler/src/lib.rs');

  test('the Rust planner source is reachable from the test', () {
    expect(compilerFile.existsSync(), isTrue,
        reason: 'expected ${compilerFile.absolute.path} — '
            'the drift gate cannot run blind');
  });

  test('Dart headings cover exactly the rules the planner can cite', () {
    final rust = rustRuleIds(compilerFile.readAsStringSync());
    expect(rust, isNotEmpty);
    expect(ruleLabels.keys.toSet(), rust,
        reason: 'the "Why this view?" sheet drifted from RULE_TABLE');
  });

  test('headings explain the rule rather than restating its id', () {
    for (final entry in ruleLabels.entries) {
      expect(entry.value.trim().isNotEmpty, isTrue,
          reason: '${entry.key} has an empty heading');
      expect(entry.value, isNot(entry.key),
          reason: '${entry.key} would show its raw id twice');
      expect(entry.value.contains('_'), isFalse,
          reason: '${entry.key} heading looks like a machine id');
    }
  });

  test('an unknown rule falls back to the raw id, not an invented heading', () {
    final explanation = ComponentExplanation.fromMap(
        <String, dynamic>{'reason': 'R99_from_a_newer_engine'});
    expect(explanation.heading, 'R99_from_a_newer_engine');
  });
}
