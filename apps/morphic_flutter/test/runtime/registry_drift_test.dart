/// Keeps the Dart registry and the Rust closed-world vocabulary in agreement.
///
/// This reads the actual Rust source rather than a copy of the list, so adding a component
/// type on the engine side without touching the runtime **fails the build**. That is the
/// whole point: an unrenderable component must be labelled, never silently forgotten.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/runtime/component_registry.dart';

/// Extracts a `pub const NAME: &[&str] = &[ "a", "b", ];` body from Rust source.
Set<String> rustStringArray(String source, String name) {
  final start = source.indexOf('pub const $name: &[&str] = &[');
  expect(start, greaterThanOrEqualTo(0), reason: '$name not found in morphic-schema');
  final open = source.indexOf('[', source.indexOf('= &[', start));
  final close = source.indexOf(']', open);
  expect(close, greaterThan(open), reason: '$name array is not closed');
  final body = source.substring(open + 1, close);
  return RegExp(r'"([^"]+)"')
      .allMatches(body)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  // `flutter test` runs with the package directory as cwd.
  final schemaFile = File('../../engine/crates/morphic-schema/src/lib.rs');

  test('the Rust schema source is reachable from the test', () {
    expect(schemaFile.existsSync(), isTrue,
        reason: 'expected ${schemaFile.absolute.path} — the drift gate cannot run blind');
  });

  test('Dart active types match ACTIVE_COMPONENTS in Rust exactly', () {
    final rust = rustStringArray(schemaFile.readAsStringSync(), 'ACTIVE_COMPONENTS');
    expect(activeComponentTypes, rust,
        reason: 'runtime vocabulary drifted from the schema validator');
  });

  test('Dart reserved types match RESERVED_COMPONENTS in Rust exactly', () {
    final rust = rustStringArray(schemaFile.readAsStringSync(), 'RESERVED_COMPONENTS');
    expect(reservedComponentTypes, rust,
        reason: 'reserved vocabulary drifted from the schema validator');
  });

  test('every active type is either rendered or explicitly deferred', () {
    final registry = ComponentRegistry();
    for (final type in activeComponentTypes) {
      final handled = registry.canRender(type) || deferredUntil.containsKey(type);
      expect(handled, isTrue,
          reason: '$type would fall through to the "unknown type" message, '
              'which would misrepresent a scheduled component as unrecognised');
    }
  });

  test('the renderable set is exactly what the registry can draw', () {
    expect(ComponentRegistry().renderable, runtimeRenderableTypes);
  });

  test('deferred types are active types, not invented ones', () {
    for (final type in deferredUntil.keys) {
      expect(activeComponentTypes.contains(type), isTrue,
          reason: '$type is deferred but is not an active schema type');
      expect(runtimeRenderableTypes.contains(type), isFalse,
          reason: '$type is both rendered and deferred');
    }
  });

  test('reserved types are never claimed as renderable', () {
    final registry = ComponentRegistry();
    for (final type in reservedComponentTypes) {
      expect(registry.canRender(type), isFalse);
      expect(deferredUntil.containsKey(type), isFalse);
    }
  });

  test('active and reserved vocabularies are disjoint', () {
    expect(activeComponentTypes.intersection(reservedComponentTypes), isEmpty);
  });

  test('the parser actually parses (guards against a vacuous gate)', () {
    const sample = 'pub const ACTIVE_COMPONENTS: &[&str] = &[\n  "a",\n  "b",\n];';
    expect(rustStringArray(sample, 'ACTIVE_COMPONENTS'), {'a', 'b'});
  });
}
