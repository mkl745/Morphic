/// Commands for clearing a single component's persisted narrowing state.
///
/// The engine validates each command against the component's declared interactions. Only
/// send commands for active, supported interactions; sending a redundant filter command to
/// a search-only table (or a search command to a filter-only chart) rejects the whole batch.
library;

import '../engine/interaction.dart';
import 'component_registry.dart';

/// Clears only this component's filter and search, leaving workspace filters and sort alone.
List<Map<String, dynamic>> clearViewNarrowingCommands(ComponentContext ctx) {
  final state = ctx.state;
  return [
    if (ctx.canFilter && state.filter != null)
      Commands.setComponentFilter(ctx.id, null),
    if (ctx.canSearch && state.search != null)
      Commands.setSearch(ctx.id, null),
  ];
}
