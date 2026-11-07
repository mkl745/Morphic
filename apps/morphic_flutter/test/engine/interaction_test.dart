/// The interaction vocabulary is a wire contract, so it is tested as one.
///
/// Two kinds of test live here. The **drift gates** read the Rust source, so renaming a command
/// or dropping a filter operator on the engine side fails the Dart build instead of producing a
/// button that silently does nothing. The rest pin the pure helpers the widgets compose with —
/// notably that they build *commands and filter nodes*, never touch a row.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphic_flutter/engine/interaction.dart';

import '../runtime/registry_drift_test.dart' show rustStringArray;

/// The four command tags Dart can emit, taken from the builders themselves rather than a
/// hand-copied list, so a new builder cannot escape the gate.
Set<String> _dartCommandTags() => {
      Commands.setGlobalFilter(const [])['kind'],
      Commands.setComponentFilter('c', null)['kind'],
      Commands.setComponentSort('c', const [])['kind'],
      Commands.setSearch('c', null)['kind'],
    }.cast<String>();

/// `SetComponentSort { .. }` → `setComponentSort`, which is what `rename_all = "camelCase"`
/// produces on an internally tagged enum.
Set<String> _rustCommandTags(String source) {
  final start = source.indexOf('pub enum Command {');
  expect(start, greaterThanOrEqualTo(0), reason: 'Command enum not found');
  final end = source.indexOf('\n}', start);
  expect(end, greaterThan(start), reason: 'Command enum is not closed');
  final body = source.substring(start, end);
  return RegExp(r'^    ([A-Z][A-Za-z0-9]*)\s*\{', multiLine: true)
      .allMatches(body)
      .map((m) {
        final name = m.group(1)!;
        return name[0].toLowerCase() + name.substring(1);
      })
      .toSet();
}

void main() {
  // `flutter test` runs with the package directory as cwd.
  final commandsFile = File('../../engine/crates/morphic-core/src/commands.rs');
  final schemaFile = File('../../engine/crates/morphic-schema/src/lib.rs');
  final modelFile = File('../../engine/crates/morphic-model/src/lib.rs');

  group('wire drift gates', () {
    test('the Rust sources are reachable', () {
      for (final f in [commandsFile, schemaFile, modelFile]) {
        expect(f.existsSync(), isTrue,
            reason: 'expected ${f.absolute.path} — a drift gate cannot run blind');
      }
    });

    test('Dart command tags match the Rust Command enum exactly', () {
      final rust = _rustCommandTags(commandsFile.readAsStringSync());
      expect(rust, isNotEmpty, reason: 'the variant regex matched nothing');
      expect(_dartCommandTags(), rust,
          reason: 'the UI vocabulary drifted from morphic_core::Command');
    });

    test('every command names its component the way serde expects', () {
      final rust = commandsFile.readAsStringSync();
      // rename_all on an enum renames variants only; fields need their own attribute.
      expect(RegExp(r'rename = "componentId"').allMatches(rust).length, 3,
          reason: 'three commands carry a component id');
      for (final cmd in [
        Commands.setComponentFilter('data_table', null),
        Commands.setComponentSort('data_table', const []),
        Commands.setSearch('data_table', null),
      ]) {
        expect(cmd.containsKey('componentId'), isTrue);
        expect(cmd.containsKey('component_id'), isFalse);
      }
    });

    test('every operator the menu offers is in the schema vocabulary', () {
      final allowed = rustStringArray(schemaFile.readAsStringSync(), 'FILTER_OPS');
      for (final kind in FieldKind.values) {
        for (final op in operatorsFor(kind)) {
          expect(allowed, contains(op.op),
              reason: '${op.op} offered for $kind is not a schema operator');
        }
      }
    });

    test('every dtype the engine can report maps to a known kind', () {
      final rust = modelFile.readAsStringSync();
      final start = rust.indexOf('pub fn as_str(');
      expect(start, greaterThanOrEqualTo(0));
      final body = rust.substring(start, rust.indexOf('\n    }', start));
      final dtypes = RegExp(r'=> "([a-z0-9]+)"')
          .allMatches(body)
          .map((m) => m.group(1)!)
          .toSet();
      expect(dtypes.length, 6, reason: 'DataType::as_str shape changed');
      for (final dtype in dtypes) {
        // `null` is the one dtype with no values to compare, so unknown is correct there.
        if (dtype == 'null') continue;
        expect(fieldKindOf(dtype), isNot(FieldKind.unknown),
            reason: '$dtype would fall back to text operators');
      }
    });

    test('sort direction and null placement use the schema spellings', () {
      final rust = schemaFile.readAsStringSync();
      expect(rust, contains('pub enum SortDir'));
      expect(rust, contains('pub enum NullsOrder'));
      const rule = SortRule(field: 'amount', dir: SortDir.desc, nulls: NullsOrder.first);
      expect(rule.toJson(), {'field': 'amount', 'dir': 'desc', 'nulls': 'first'});
    });
  });

  group('SortRule', () {
    test('defaults are ascending with nulls last', () {
      const rule = SortRule(field: 'amount');
      expect(rule.toJson(), {'field': 'amount', 'dir': 'asc', 'nulls': 'last'});
    });

    test('parses back what it writes', () {
      const rule = SortRule(field: 'ts', dir: SortDir.desc, nulls: NullsOrder.first);
      expect(SortRule.fromJson(rule.toJson()), rule);
    });

    test('an absent direction or null order falls back rather than throwing', () {
      final rule = SortRule.fromJson({'field': 'amount'});
      expect(rule.dir, SortDir.asc);
      expect(rule.nulls, NullsOrder.last);
    });
  });

  group('cycledSort', () {
    test('unsorted to ascending to descending to unsorted', () {
      var sort = cycledSort(const [], 'amount');
      expect(sort, [const SortRule(field: 'amount')]);
      sort = cycledSort(sort, 'amount');
      expect(sort, [const SortRule(field: 'amount', dir: SortDir.desc)]);
      sort = cycledSort(sort, 'amount');
      expect(sort, isEmpty);
    });

    test('sorting another column replaces the key instead of stacking', () {
      final sort = cycledSort([const SortRule(field: 'amount', dir: SortDir.desc)], 'region');
      expect(sort, [const SortRule(field: 'region')],
          reason: 'one visible indicator means one key; multi-key is a documented limit');
    });
  });

  group('ComponentInteraction.fromSpec', () {
    test('a component with no state is empty, not null', () {
      const state = ComponentInteraction();
      expect(state.isEmpty, isTrue);
      expect(ComponentInteraction.fromSpec({'id': 'c'}).isEmpty, isTrue);
    });

    test('reads persisted sort, filter and search', () {
      final state = ComponentInteraction.fromSpec({
        'state': {
          'sort': [
            {'field': 'amount', 'dir': 'desc'},
          ],
          'filter': {'op': 'eq', 'field': 'region', 'value': 'eu'},
          'search': 'apa',
        },
      });
      expect(state.sortFor('amount')?.dir, SortDir.desc);
      expect(state.filterFor('region')?['value'], 'eu');
      expect(state.search, 'apa');
      expect(state.hasFilters, isTrue);
      expect(state.isEmpty, isFalse);
    });

    test('an empty search string is treated as no search', () {
      final state = ComponentInteraction.fromSpec({
        'state': {'search': ''},
      });
      expect(state.search, isNull);
      expect(state.hasFilters, isFalse);
    });

    test('a sort rule with no field is dropped, not rendered as a blank indicator', () {
      final state = ComponentInteraction.fromSpec({
        'state': {
          'sort': [
            {'dir': 'asc'},
            {'field': 'amount'},
          ],
        },
      });
      expect(state.sort.length, 1);
      expect(state.sort.single.field, 'amount');
    });

    test('sort survives a round trip through the document (AT-07)', () {
      final spec = {
        'state': {
          'sort': [const SortRule(field: 'amount', dir: SortDir.desc).toJson()],
        },
      };
      expect(ComponentInteraction.fromSpec(spec).sortFor('amount')?.dir, SortDir.desc);
    });

    test('filterFor finds one column inside a conjunction', () {
      final state = ComponentInteraction.fromSpec({
        'state': {
          'filter': {
            'op': 'and',
            'args': [
              {'op': 'eq', 'field': 'region', 'value': 'eu'},
              {'op': 'gt', 'field': 'amount', 'value': 10},
            ],
          },
        },
      });
      expect(state.filterFor('amount')?['op'], 'gt');
      expect(state.filterFor('note'), isNull);
    });

    test('a non-map state is ignored rather than crashing the renderer', () {
      expect(ComponentInteraction.fromSpec({'state': 'nonsense'}).isEmpty, isTrue);
    });
  });

  group('Commands', () {
    test('setGlobalFilter carries the whole resulting set', () {
      final cmd = Commands.setGlobalFilter([
        {'op': 'eq', 'field': 'region', 'value': 'eu'},
      ]);
      expect(cmd['kind'], 'setGlobalFilter');
      expect((cmd['filters'] as List).length, 1);
    });

    test('clearing everything is an empty set, not a remove command', () {
      expect(Commands.setGlobalFilter(const []), {'kind': 'setGlobalFilter', 'filters': []});
    });

    test('a null filter or search means clear', () {
      expect(Commands.setComponentFilter('t', null)['filter'], isNull);
      expect(Commands.setSearch('t', null)['text'], isNull);
    });

    test('setComponentSort serialises rules to the wire shape', () {
      expect(Commands.setComponentSort('t', [const SortRule(field: 'amount')]), {
        'kind': 'setComponentSort',
        'componentId': 't',
        'sort': [
          {'field': 'amount', 'dir': 'asc', 'nulls': 'last'},
        ],
      });
    });
  });

  group('filter nodes', () {
    test('a null value and empty args are omitted, not sent as null', () {
      expect(filterNode('is_null', field: 'note'), {'op': 'is_null', 'field': 'note'});
    });

    test('a numeric bound keeps its JSON type', () {
      final node = filterNode('gte', field: 'amount', value: 10);
      expect(node['value'], isA<int>());
    });

    test('combineFilters drops nulls and unwraps a single conjunct', () {
      expect(combineFilters([null, null]), isNull);
      final one = filterNode('eq', field: 'region', value: 'eu');
      expect(combineFilters([null, one]), same(one));
      final two = combineFilters([one, filterNode('gt', field: 'amount', value: 1)]);
      expect(two?['op'], 'and');
      expect((two?['args'] as List).length, 2);
    });

    test('withFieldFilter replaces one column and keeps the others', () {
      final current = filterNode('and', args: [
        filterNode('eq', field: 'region', value: 'eu'),
        filterNode('gt', field: 'amount', value: 1),
      ]);
      final next = withFieldFilter(
          current, 'amount', filterNode('lt', field: 'amount', value: 50));
      final args = (next?['args'] as List).cast<Map<String, dynamic>>();
      expect(args.length, 2);
      expect(args.first['field'], 'region');
      expect(args.last['op'], 'lt');
    });

    test('removing one of two filters leaves a bare node, not an and of one', () {
      final current = filterNode('and', args: [
        filterNode('eq', field: 'region', value: 'eu'),
        filterNode('gt', field: 'amount', value: 1),
      ]);
      final next = withFieldFilter(current, 'amount', null);
      expect(next, {'op': 'eq', 'field': 'region', 'value': 'eu'});
    });

    test('removing the only filter clears it entirely', () {
      final current = filterNode('eq', field: 'region', value: 'eu');
      expect(withFieldFilter(current, 'region', null), isNull);
    });

    test('filtering a fresh column on an unfiltered component just sets it', () {
      final next = withFieldFilter(null, 'region', filterNode('eq', field: 'region', value: 'eu'));
      expect(next, {'op': 'eq', 'field': 'region', 'value': 'eu'});
    });
  });

  group('global filter sets', () {
    final eu = filterNode('eq', field: 'region', value: 'eu');
    final big = filterNode('gt', field: 'amount', value: 10);

    test('key order does not decide whether two filters are the same', () {
      final a = {'op': 'eq', 'field': 'region', 'value': 'eu'};
      final b = {'value': 'eu', 'field': 'region', 'op': 'eq'};
      expect(sameFilter(a, b), isTrue);
      expect(filterKey(a), filterKey(b));
    });

    test('a different bound is a different filter', () {
      expect(sameFilter(eu, filterNode('eq', field: 'region', value: 'us')), isFalse);
    });

    test('nested arguments are compared structurally, not by identity', () {
      final a = filterNode('and', args: [eu, big]);
      final b = filterNode('and', args: [
        {'value': 'eu', 'op': 'eq', 'field': 'region'},
        {'field': 'amount', 'op': 'gt', 'value': 10},
      ]);
      expect(sameFilter(a, b), isTrue);
    });

    test('argument order still matters, because the wire is a list', () {
      expect(sameFilter(filterNode('and', args: [eu, big]),
          filterNode('and', args: [big, eu])), isFalse);
    });

    test('indexOfFilter finds a structurally equal node from another map', () {
      final set = [eu, big];
      expect(indexOfFilter(set, {'field': 'amount', 'op': 'gt', 'value': 10}), 1);
      expect(indexOfFilter(set, filterNode('eq', field: 'region', value: 'us')), -1);
    });

    test('toggling appends when absent and removes when present', () {
      expect(toggledFilters(const [], eu), [eu]);
      expect(toggledFilters([eu, big], eu), [big]);
    });

    test('toggling twice returns the original set in the original order', () {
      final set = [eu, big];
      final once = toggledFilters(set, big);
      expect(toggledFilters(once, big), set);
    });

    test('toggling does not mutate the set it was given', () {
      final set = [eu];
      toggledFilters(set, big);
      expect(set, [eu]);
    });

    test('editing replaces in place rather than moving the chip to the end', () {
      final replacement = filterNode('eq', field: 'region', value: 'us');
      expect(editedFilters([eu, big], 0, replacement), [replacement, big]);
    });

    test('editing to null removes just that entry', () {
      expect(editedFilters([eu, big], 0, null), [big]);
      expect(editedFilters([eu], 0, null), isEmpty);
    });

    test('an out-of-range index is a no-op, not a crash', () {
      expect(editedFilters([eu], 5, big), [eu]);
      expect(editedFilters([eu], -1, null), [eu]);
    });

    test('numbers keep their JSON spelling, as they do on the wire', () {
      expect(sameFilter(filterNode('eq', field: 'n', value: 1),
          filterNode('eq', field: 'n', value: 1.0)), isFalse);
    });
  });

  group('type-aware operators', () {
    test('an integer offers comparisons but not substring matching', () {
      final ops = operatorsFor(FieldKind.integer).map((o) => o.op).toSet();
      expect(ops, containsAll(['eq', 'neq', 'gt', 'gte', 'lt', 'lte']));
      expect(ops, isNot(contains('contains')));
    });

    test('text offers contains but not ordering', () {
      final ops = operatorsFor(FieldKind.text).map((o) => o.op).toSet();
      expect(ops, contains('contains'));
      expect(ops, isNot(contains('gt')));
    });

    test('a boolean offers only is, plus the null tests', () {
      final ops = operatorsFor(FieldKind.boolean).map((o) => o.op).toSet();
      expect(ops, {'eq', 'is_null', 'not_null'});
    });

    test('a timestamp offers date bounds', () {
      final ops = operatorsFor(FieldKind.timestamp).map((o) => o.op).toSet();
      expect(ops, containsAll(['gte', 'lt', 'eq']));
      expect(ops, isNot(contains('contains')));
    });

    test('every type can ask for empty and non-empty, without a value', () {
      for (final kind in FieldKind.values) {
        final ops = operatorsFor(kind);
        for (final name in ['is_null', 'not_null']) {
          final op = ops.firstWhere((o) => o.op == name,
              orElse: () => throw StateError('$kind cannot test $name'));
          expect(op.needsValue, isFalse);
        }
      }
    });

    test('an unknown type falls back to text operators rather than offering nothing', () {
      expect(fieldKindOf(null), FieldKind.unknown);
      expect(fieldKindOf('decimal128'), FieldKind.unknown);
      expect(operatorsFor(FieldKind.unknown).map((o) => o.op),
          contains('contains'));
    });

    test('dtypes map to the kinds the menu distinguishes', () {
      expect(fieldKindOf('int64'), FieldKind.integer);
      expect(fieldKindOf('float64'), FieldKind.decimal);
      expect(fieldKindOf('bool'), FieldKind.boolean);
      expect(fieldKindOf('timestamp'), FieldKind.timestamp);
      expect(fieldKindOf('utf8'), FieldKind.text);
    });
  });

  group('coerceBound', () {
    test('an integer bound stays an integer', () {
      expect(coerceBound(FieldKind.integer, ' 42 '), 42);
      expect(coerceBound(FieldKind.integer, '42'), isA<int>());
    });

    test('text that cannot be an integer is not ready to apply', () {
      expect(coerceBound(FieldKind.integer, 'abc'), isNull);
      expect(coerceBound(FieldKind.integer, '1.5'), isNull);
    });

    test('a decimal accepts a fraction', () {
      expect(coerceBound(FieldKind.decimal, '1.5'), 1.5);
    });

    test('a boolean accepts the spellings a person would type', () {
      expect(coerceBound(FieldKind.boolean, 'TRUE'), isTrue);
      expect(coerceBound(FieldKind.boolean, 'no'), isFalse);
      expect(coerceBound(FieldKind.boolean, '1'), isTrue);
      expect(coerceBound(FieldKind.boolean, '0'), isFalse);
      expect(coerceBound(FieldKind.boolean, 'maybe'), isNull);
    });

    test('empty text is never a bound', () {
      for (final kind in FieldKind.values) {
        expect(coerceBound(kind, '   '), isNull);
      }
    });

    test('text and timestamp bounds are trimmed strings', () {
      expect(coerceBound(FieldKind.text, '  eu  '), 'eu');
      expect(coerceBound(FieldKind.timestamp, '2026-01-01'), '2026-01-01');
    });
  });

  group('describeFilter', () {
    test('comparisons read as the comparison, not the op name', () {
      expect(describeFilter(filterNode('eq', field: 'region', value: 'eu')), 'region = eu');
      expect(describeFilter(filterNode('gte', field: 'amount', value: 10)), 'amount ≥ 10');
      expect(describeFilter(filterNode('lt', field: 'amount', value: 10)), 'amount < 10');
      expect(describeFilter(filterNode('neq', field: 'region', value: 'eu')), 'region ≠ eu');
    });

    test('null tests say empty, which is what the cell shows', () {
      expect(describeFilter(filterNode('is_null', field: 'note')), 'note is empty');
      expect(describeFilter(filterNode('not_null', field: 'note')), 'note is not empty');
    });

    test('a conjunction reads as both chips, not as the word and', () {
      final node = filterNode('and', args: [
        filterNode('eq', field: 'region', value: 'eu'),
        filterNode('gt', field: 'amount', value: 1),
      ]);
      expect(describeFilter(node), 'region = eu · amount > 1');
    });

    test('nested logic is described rather than dropped', () {
      final node = filterNode('not', args: [filterNode('eq', field: 'region', value: 'eu')]);
      expect(describeFilter(node), 'not (region = eu)');
    });
  });
}
