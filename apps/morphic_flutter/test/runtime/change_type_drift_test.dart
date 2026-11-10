/// Keeps the 1.4.7 menu and sheet labels in step with the Rust contract.
///
/// Two different authorities are involved: `ACTIVE_COMPONENTS` (the registry the menu may
/// offer) and `TYPE_CHANGE_REASON` (the explanation the engine writes after a switch). Both are
/// read from Rust source so a rename cannot leave a bare snake_case id on screen.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/runtime/change_type_button.dart';
import 'package:morphic_flutter/runtime/explanation_sheet.dart';

Set<String> rustActiveComponents(String source) {
  final start = source.indexOf('pub const ACTIVE_COMPONENTS: &[&str] = &[');
  expect(start, greaterThanOrEqualTo(0),
      reason: 'ACTIVE_COMPONENTS not found in morphic-schema');
  final open = source.indexOf('[', source.indexOf('= &[', start));
  final close = source.indexOf('];', open);
  expect(close, greaterThan(open),
      reason: 'ACTIVE_COMPONENTS array is not closed');
  return RegExp(r'"([^"]+)"')
      .allMatches(source.substring(open + 1, close))
      .map((m) => m.group(1)!)
      .toSet();
}

String rustTypeChangeReason(String source) {
  final match = RegExp(
    r'pub const TYPE_CHANGE_REASON:\s*&str\s*=\s*"([^"]+)"',
  ).firstMatch(source);
  expect(match, isNotNull,
      reason: 'TYPE_CHANGE_REASON not found in morphic-schema/type_change.rs');
  return match!.group(1)!;
}

void main() {
  // `flutter test` runs with the package directory as cwd.
  final schemaFile = File('../../engine/crates/morphic-schema/src/lib.rs');
  final typeChangeFile =
      File('../../engine/crates/morphic-schema/src/type_change.rs');

  test('both Rust sources are reachable from the test', () {
    expect(schemaFile.existsSync(), isTrue,
        reason: 'expected ${schemaFile.absolute.path}');
    expect(typeChangeFile.existsSync(), isTrue,
        reason: 'expected ${typeChangeFile.absolute.path}');
  });

  test('menu labels cover exactly the registered component types', () {
    final rust = rustActiveComponents(schemaFile.readAsStringSync());
    expect(rust, isNotEmpty);
    expect(componentTypeLabels.keys.toSet(), rust,
        reason: 'the Change view menu drifted from ACTIVE_COMPONENTS');
  });

  test('the converted-component heading covers the engine reason', () {
    final reason = rustTypeChangeReason(typeChangeFile.readAsStringSync());
    expect(typeChangeLabels.keys.toSet(), <String>{reason},
        reason: 'the sheet has no heading for a converted component');
    expect(
      ComponentExplanation.fromMap(<String, dynamic>{'reason': reason}).heading,
      typeChangeLabels[reason],
    );
  });

  test('labels explain the type rather than restating its id', () {
    for (final entry in <MapEntry<String, String>>[
      ...componentTypeLabels.entries,
      ...typeChangeLabels.entries,
    ]) {
      expect(entry.value.trim().isNotEmpty, isTrue,
          reason: '${entry.key} has an empty label');
      expect(entry.value, isNot(entry.key),
          reason: '${entry.key} would show its raw id twice');
      expect(entry.value.contains('_'), isFalse,
          reason: '${entry.key} label looks like a machine id');
    }
  });

  test('an unregistered target falls back to the raw id', () {
    expect(componentTypeLabel('pie_chart'), 'pie_chart');
  });
}
