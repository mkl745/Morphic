/// Interaction state and the command vocabulary (M1.3 task 1.3.3).
///
/// This file is **data only**: it reads what Rust persisted and builds the commands that ask
/// Rust to change it. It never filters, sorts, or aggregates a row. The M1.3 exit's "no
/// Dart-side data logic" rule is enforced by there being no data here to compute with — the
/// table asks the engine for a page and draws what comes back.
///
/// The shapes mirror `morphic_schema::{ComponentState, SortRule}` and `morphic_core::Command`.
/// `interaction_test.dart` pins the wire names against the Rust source so the two cannot
/// drift silently.
library;

import 'dart:convert';

/// Sort direction. Wire values are `asc` / `desc`.
enum SortDir { asc, desc }

/// Where nulls go, independent of direction: `last` means last ascending *and* descending.
enum NullsOrder { first, last }

/// One sort key, as persisted in `component.state.sort`.
class SortRule {
  const SortRule({
    required this.field,
    this.dir = SortDir.asc,
    this.nulls = NullsOrder.last,
  });

  factory SortRule.fromJson(Map<String, dynamic> json) => SortRule(
        field: json['field'] as String? ?? '',
        dir: (json['dir'] as String?) == 'desc' ? SortDir.desc : SortDir.asc,
        nulls: (json['nulls'] as String?) == 'first'
            ? NullsOrder.first
            : NullsOrder.last,
      );

  final String field;
  final SortDir dir;
  final NullsOrder nulls;

  Map<String, dynamic> toJson() => {
        'field': field,
        'dir': dir == SortDir.desc ? 'desc' : 'asc',
        'nulls': nulls == NullsOrder.first ? 'first' : 'last',
      };

  @override
  bool operator ==(Object other) =>
      other is SortRule &&
      other.field == field &&
      other.dir == dir &&
      other.nulls == nulls;

  @override
  int get hashCode => Object.hash(field, dir, nulls);
}

/// What the user has done to one component, read straight from the document Rust returned.
class ComponentInteraction {
  const ComponentInteraction({this.filter, this.sort = const [], this.search});

  factory ComponentInteraction.fromSpec(Map<String, dynamic> spec) {
    final state = spec['state'];
    if (state is! Map<String, dynamic>) return const ComponentInteraction();
    final rawSort = (state['sort'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SortRule.fromJson)
        .where((r) => r.field.isNotEmpty)
        .toList();
    final search = state['search'] as String?;
    return ComponentInteraction(
      filter: state['filter'] as Map<String, dynamic>?,
      sort: rawSort,
      search: (search == null || search.isEmpty) ? null : search,
    );
  }

  final Map<String, dynamic>? filter;
  final List<SortRule> sort;
  final String? search;

  bool get isEmpty => filter == null && sort.isEmpty && search == null;
  bool get hasFilters => filter != null || search != null;

  SortRule? sortFor(String field) {
    for (final r in sort) {
      if (r.field == field) return r;
    }
    return null;
  }

  /// True when this component's own state pins [field] to a single value — what a column
  /// filter menu shows as already applied.
  Map<String, dynamic>? filterFor(String field) {
    final f = filter;
    if (f == null) return null;
    if (f['field'] == field) return f;
    if ((f['op'] as String?) == 'and') {
      for (final arg in (f['args'] as List? ?? const [])) {
        if (arg is Map<String, dynamic> && arg['field'] == field) return arg;
      }
    }
    return null;
  }
}

/// Tap-to-cycle: unsorted → ascending → descending → unsorted.
///
/// One key at a time. The engine accepts up to eight, and a shift-tap could expose that later,
/// but a phone header has room for one indicator and pretending otherwise would be a worse
/// interface than a documented limit.
List<SortRule> cycledSort(List<SortRule> current, String field) {
  final existing = current.where((r) => r.field == field).toList();
  if (existing.isEmpty) return [SortRule(field: field)];
  if (existing.first.dir == SortDir.asc) {
    return [SortRule(field: field, dir: SortDir.desc)];
  }
  return const [];
}

/// The closed command vocabulary. Mirrors `morphic_core::Command`'s serde tags exactly.
class Commands {
  const Commands._();

  static Map<String, dynamic> setGlobalFilter(List<Map<String, dynamic>> filters) => {
        'kind': 'setGlobalFilter',
        'filters': filters,
      };

  static Map<String, dynamic> setComponentFilter(
    String componentId,
    Map<String, dynamic>? filter,
  ) =>
      {
        'kind': 'setComponentFilter',
        'componentId': componentId,
        'filter': filter,
      };

  static Map<String, dynamic> setComponentSort(
    String componentId,
    List<SortRule> sort,
  ) =>
      {
        'kind': 'setComponentSort',
        'componentId': componentId,
        'sort': sort.map((r) => r.toJson()).toList(),
      };

  static Map<String, dynamic> setSearch(String componentId, String? text) => {
        'kind': 'setSearch',
        'componentId': componentId,
        'text': text,
      };
}

/// Build a flat filter node — the wire shape both `morphic_schema::FilterExpr` and
/// `morphic_query::Filter::from_json` accept.
Map<String, dynamic> filterNode(
  String op, {
  String? field,
  Object? value,
  List<Map<String, dynamic>> args = const [],
}) =>
    {
      'op': op,
      if (field != null) 'field': field,
      if (value != null) 'value': value,
      if (args.isNotEmpty) 'args': args,
    };

/// Combine conjuncts, dropping nulls. One part is returned unchanged so a single chip does
/// not grow a pointless `and` wrapper.
Map<String, dynamic>? combineFilters(List<Map<String, dynamic>?> parts) {
  final kept = parts.whereType<Map<String, dynamic>>().toList();
  if (kept.isEmpty) return null;
  if (kept.length == 1) return kept.first;
  return filterNode('and', args: kept);
}

/// Replace (or remove) the conjunct that belongs to [field], leaving other columns' filters
/// alone. This is how a per-column menu edits one chip without discarding the rest.
Map<String, dynamic>? withFieldFilter(
  Map<String, dynamic>? current,
  String field,
  Map<String, dynamic>? replacement,
) {
  final others = <Map<String, dynamic>>[];
  if (current != null) {
    if ((current['op'] as String?) == 'and') {
      for (final arg in (current['args'] as List? ?? const [])) {
        if (arg is Map<String, dynamic> && arg['field'] != field) others.add(arg);
      }
    } else if (current['field'] != field) {
      others.add(current);
    }
  }
  if (replacement != null) others.add(replacement);
  return combineFilters(others);
}

/// A canonical encoding of a filter node, for deciding whether two filters are *the same
/// filter*. Map key order must not decide whether a card looks pressed or a chip looks active,
/// and `jsonEncode` alone preserves insertion order.
///
/// Numbers keep their JSON spelling (`1` and `1.0` differ), which is the same distinction the
/// wire makes; both sides of a comparison come from the same decoded document in practice.
String filterKey(Map<String, dynamic> node) => _canonical(node);

String _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    final parts = keys.map((k) => '${jsonEncode(k)}:${_canonical(value[k])}');
    return '{${parts.join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  return jsonEncode(value);
}

/// True when two nodes would select the same rows, regardless of key order.
bool sameFilter(Map<String, dynamic> a, Map<String, dynamic> b) =>
    filterKey(a) == filterKey(b);

/// Where [node] sits in a global filter set, or -1. Structural, not identity: a card's binding
/// filter and the chip the engine echoed back are different map objects.
int indexOfFilter(List<Map<String, dynamic>> set, Map<String, dynamic> node) {
  for (var i = 0; i < set.length; i++) {
    if (sameFilter(set[i], node)) return i;
  }
  return -1;
}

/// Tap-to-toggle: applied means removed, not applied means appended. Idempotent in the sense
/// that matters — tapping twice returns the original set, in the original order.
List<Map<String, dynamic>> toggledFilters(
  List<Map<String, dynamic>> set,
  Map<String, dynamic> node,
) {
  final at = indexOfFilter(set, node);
  if (at < 0) return [...set, node];
  return [...set]..removeAt(at);
}

/// Replace one entry, or remove it when [replacement] is null. The result is the whole set,
/// because `SetGlobalFilter` replaces rather than patches — there is no index-based remove
/// command whose index could go stale between the tap and the apply.
List<Map<String, dynamic>> editedFilters(
  List<Map<String, dynamic>> set,
  int index,
  Map<String, dynamic>? replacement,
) {
  if (index < 0 || index >= set.length) return [...set];
  final next = [...set];
  if (replacement == null) {
    next.removeAt(index);
  } else {
    next[index] = replacement;
  }
  return next;
}

/// The column types the filter menu distinguishes. Mirrors `DataType::as_str()`.
enum FieldKind { text, integer, decimal, boolean, timestamp, unknown }

FieldKind fieldKindOf(String? dtype) {
  switch (dtype) {
    case 'utf8':
      return FieldKind.text;
    case 'int64':
      return FieldKind.integer;
    case 'float64':
      return FieldKind.decimal;
    case 'bool':
      return FieldKind.boolean;
    case 'timestamp':
      return FieldKind.timestamp;
    default:
      return FieldKind.unknown;
  }
}

/// One operator the menu can offer.
class FilterOperator {
  const FilterOperator(this.op, this.label, {this.needsValue = true});

  final String op;
  final String label;
  final bool needsValue;
}

/// Type-aware operator sets. A number never offers "contains"; a boolean never offers a
/// comparison it cannot mean. Every list ends with the null tests, which need no value.
List<FilterOperator> operatorsFor(FieldKind kind) {
  const nullTests = [
    FilterOperator('is_null', 'Is empty', needsValue: false),
    FilterOperator('not_null', 'Is not empty', needsValue: false),
  ];
  switch (kind) {
    case FieldKind.integer:
    case FieldKind.decimal:
      return const [
        FilterOperator('eq', 'Equals'),
        FilterOperator('neq', 'Does not equal'),
        FilterOperator('gt', 'Greater than'),
        FilterOperator('gte', 'At least'),
        FilterOperator('lt', 'Less than'),
        FilterOperator('lte', 'At most'),
        ...nullTests,
      ];
    case FieldKind.boolean:
      return const [
        FilterOperator('eq', 'Is'),
        ...nullTests,
      ];
    case FieldKind.timestamp:
      return const [
        FilterOperator('gte', 'On or after'),
        FilterOperator('lt', 'Before'),
        FilterOperator('eq', 'Exactly'),
        ...nullTests,
      ];
    case FieldKind.text:
    case FieldKind.unknown:
      return const [
        FilterOperator('contains', 'Contains'),
        FilterOperator('eq', 'Equals'),
        FilterOperator('neq', 'Does not equal'),
        FilterOperator('in', 'Is one of'),
        ...nullTests,
      ];
  }
}

/// Coerce typed text into the JSON value the engine expects.
///
/// Returns null when the text cannot mean a value of this type, which the menu treats as
/// "not ready to apply" rather than sending a bound the engine will reject.
Object? coerceBound(FieldKind kind, String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  switch (kind) {
    case FieldKind.integer:
      return int.tryParse(t);
    case FieldKind.decimal:
      return num.tryParse(t);
    case FieldKind.boolean:
      final lower = t.toLowerCase();
      if (lower == 'true' || lower == 'yes' || lower == '1') return true;
      if (lower == 'false' || lower == 'no' || lower == '0') return false;
      return null;
    case FieldKind.timestamp:
    case FieldKind.text:
    case FieldKind.unknown:
      return t;
  }
}

/// A short, honest description of an active filter, for a chip. Recursive so an `and` of two
/// column filters reads as both rather than as "and".
String describeFilter(Map<String, dynamic> node) {
  final op = node['op'] as String? ?? '';
  final field = node['field'] as String?;
  if (op == 'and' || op == 'or') {
    final args = (node['args'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(describeFilter)
        .toList();
    return args.join(op == 'and' ? ' · ' : ' or ');
  }
  if (op == 'not') {
    final args = (node['args'] as List? ?? const []).whereType<Map<String, dynamic>>();
    return args.isEmpty ? 'not' : 'not (${args.map(describeFilter).join(', ')})';
  }
  final name = field ?? 'value';
  switch (op) {
    case 'is_null':
      return '$name is empty';
    case 'not_null':
      return '$name is not empty';
    case 'contains':
      return '$name contains ${node['value']}';
    case 'eq':
      return '$name = ${node['value']}';
    case 'neq':
      return '$name ≠ ${node['value']}';
    case 'gt':
      return '$name > ${node['value']}';
    case 'gte':
      return '$name ≥ ${node['value']}';
    case 'lt':
      return '$name < ${node['value']}';
    case 'lte':
      return '$name ≤ ${node['value']}';
    case 'in':
      final values = (node['value'] as List? ?? const []).join(', ');
      return '$name in ($values)';
    default:
      return '$name $op ${node['value'] ?? ''}'.trim();
  }
}
