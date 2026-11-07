/// Closed-world component registry (M1.1 task 1.1.5).
///
/// The Rust validator already enforces a closed vocabulary. This registry mirrors it on the
/// render side so an unrenderable component is **labelled, never silently dropped** — a
/// missing widget must not look like missing data.
///
/// `registry_drift_test.dart` reads the Rust constants directly and fails if the two sides
/// disagree, so a new engine-side type cannot be forgotten here.
library;

import 'package:flutter/widgets.dart';

import '../engine/engine_controller.dart';
import '../engine/interaction.dart';
import 'components/data_table_view.dart';
import 'components/deferred_component.dart';
import 'components/metric_card_view.dart';

/// The five types schema v1.0 accepts. Mirrors `ACTIVE_COMPONENTS` in morphic-schema.
const Set<String> activeComponentTypes = {
  'metric_card',
  'data_table',
  'bar_chart',
  'line_chart',
  'timeline',
};

/// Reserved ids the v1 validator rejects. Mirrors `RESERVED_COMPONENTS`.
const Set<String> reservedComponentTypes = {
  'scatter_plot',
  'pie_chart',
  'relationship_graph',
  'search_panel',
  'filter_panel',
  'text_inspector',
  'detail_panel',
  'data_summary',
  'hierarchical_explorer',
};

/// Types this runtime can actually draw today. The rest get an explicit placeholder.
const Set<String> runtimeRenderableTypes = {'metric_card', 'data_table'};

/// Where a deferred type is scheduled, so the placeholder states a real plan.
const Map<String, String> deferredUntil = {
  'bar_chart': 'M1.4',
  'line_chart': 'M1.4',
  'timeline': 'M1.4',
};

/// Everything a component needs to draw itself. Components receive data *only* by asking
/// the engine — they never aggregate, sort, or page on their own.
class ComponentContext {
  const ComponentContext({required this.spec, required this.engine});

  final Map<String, dynamic> spec;
  final EngineController engine;

  String get id => spec['id'] as String? ?? '';
  String get type => spec['type'] as String? ?? '';
  String get title => spec['title'] as String? ?? type;
  Map<String, dynamic> get binding =>
      spec['binding'] as Map<String, dynamic>? ?? const {};
  Map<String, dynamic> get interactions =>
      spec['interactions'] as Map<String, dynamic>? ?? const {};
  Map<String, dynamic> get explanation =>
      spec['explanation'] as Map<String, dynamic>? ?? const {};

  bool get canSearch => interactions['search'] == true;
  bool get canSort => interactions['sort'] == true;
  bool get canFilter => interactions['filter'] == true;

  /// What the user has already applied to this component, as persisted by Rust.
  ComponentInteraction get state => ComponentInteraction.fromSpec(spec);

  /// The engine's inferred type for a field, or null when the profile is unavailable (degraded
  /// mode). The filter menu uses this to offer only operators the column can mean.
  String? dtypeOf(String field) {
    final profile = engine.profile;
    final fields = (profile?['fields'] as List? ?? const [])
        .whereType<Map<String, dynamic>>();
    for (final f in fields) {
      if (f['name'] == field) return f['dtype'] as String?;
    }
    return null;
  }

  /// Frequently occurring values, offered as choices by a text column's filter menu. Empty
  /// when the profile is unavailable; the menu then falls back to free text.
  List<String> topValuesOf(String field) {
    final profile = engine.profile;
    final fields = (profile?['fields'] as List? ?? const [])
        .whereType<Map<String, dynamic>>();
    for (final f in fields) {
      if (f['name'] != field) continue;
      return (f['topValues'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((v) => v['value']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return const [];
  }
}

typedef ComponentBuilder = Widget Function(ComponentContext ctx);

class ComponentRegistry {
  ComponentRegistry({Map<String, ComponentBuilder>? overrides})
      : _builders = {
          'metric_card': (ctx) => MetricCardView(ctx: ctx),
          'data_table': (ctx) => DataTableView(ctx: ctx),
          ...?overrides,
        };

  final Map<String, ComponentBuilder> _builders;

  /// Types with a real renderer. Used by the drift gate.
  Set<String> get renderable => _builders.keys.toSet();

  bool canRender(String type) => _builders.containsKey(type);

  /// Never returns null: an unknown or deferred type becomes a labelled placeholder.
  Widget build(ComponentContext ctx) {
    final builder = _builders[ctx.type];
    if (builder == null) return DeferredComponent(ctx: ctx);
    return builder(ctx);
  }
}
