# 04 — Component Registry

Status: **Design frozen for Phase 0** · Implements spec §5.5 ·
Related: [UI Schema](03-ui-schema.md), [ADR-0006](../decisions/ADR-0006-ui-schema-typed-contract.md)

The registry is the **trust boundary between descriptions and pixels**. A workspace can only
contain components the registry knows. There are two registry halves that MUST agree:

- **Rust half** (`morphic-schema`): type-level contracts used by the compiler and validator.
- **Dart half** (`lib/component_runtime/`): widget builders keyed by `(type, typeVersion)`.

A generated **registry manifest** (`schemas/registry_v1.json`, exported from Rust) is the
single source of truth; a Dart contract test asserts every manifest entry has a widget
builder and every builder has a manifest entry. CI fails on drift.

## 1. Component contract (every component defines)

| Facet | Meaning |
|---|---|
| `type` / `typeVersion` | stable id + contract version (semver) |
| `binding` schema | typed data contract (fields, aggregations, options) |
| Accepted data types | per binding slot (e.g. x: temporal\|numeric) |
| `interactions` | which of filter/sort/search/select it supports |
| `state` model | persisted component state (e.g. sort column+dir) |
| Accessibility | semantic label template, focus order, min target sizes, data-table semantics |
| Performance class | `cheap` (metric), `paged` (table), `aggregated` (charts) — dictates data-plane path |
| Rendering strategy | widget composition vs CustomPainter; repaint boundaries |
| Empty/error states | required visual states: loading, empty-after-filter, binding-error |

## 2. MVP set (Phase 1) — five schema components

| Type | Perf class | Data path | Key interactions | Notes |
|---|---|---|---|---|
| `metric_card` 1.0 | cheap | `metricData` (single value) | tap → applies its filter as global filter (toggle) | compact formatting, delta optional (P2) |
| `data_table` 1.0 | paged | `queryPage` (256-row pages) | sort, per-column filter, search, row tap → detail sheet | sliver-based, fixed row extent, sticky header, horizontal scroll for wide tables |
| `bar_chart` 1.0 | aggregated | `chartData` (top-N ≤ 50) | tap bar → filter; sort toggle | CustomPainter; "Other" bucket for remainder |
| `line_chart` 1.0 | aggregated | `chartData` (≤ 2000 pts, bucketed) | scrub tooltip; legend toggle (≤ 8 series) | CustomPainter; time or numeric x |
| `timeline` 1.0 | aggregated | `chartData` (density buckets + severity lanes) | tap bucket → filter time range; lane toggle | CustomPainter; severity-aware coloring |

**Workspace chrome (not schema components in v1):** global filter bar, search field,
component header menus (change type / resize / move / remove), row detail bottom sheet,
explanation sheet ("Why this view?"). Keeping chrome out of the schema keeps v1 small; the
spec's `search_panel` / `filter_panel` / `detail_panel` become schema components in P2 when
the compiler needs to place them spatially.

## 3. Reserved ids (spec §5.5 full list — registered, not implemented)

`scatter_plot`, `pie_chart`, `relationship_graph`, `search_panel`, `filter_panel`,
`text_inspector`, `detail_panel`, `data_summary`, `hierarchical_explorer`.

Reserved ids exist in the manifest with `"status": "reserved"` so the compiler/AI can never
emit them by accident in v1 (validator rejects reserved types), and so Phase 2+ additions
are additive minor versions.

## 4. Type-change compatibility matrix (ChangeComponentType)

Manual "switch visualization" is only offered when the binding can be re-expressed:

| From → To | Allowed when |
|---|---|
| bar ↔ line | dimension is temporal/numeric (line) or categorical with ≤ 50 groups (bar) |
| bar → metric | measure kept, dimension dropped (aggregation only) |
| line → timeline | x is temporal |
| any → data_table | always (projection = bound fields) |
| data_table → chart | compiler proposes a default binding from profile; user confirms |

The engine validates the converted binding before applying; failure leaves state untouched.

## 5. Dart runtime rules

1. Builders are pure functions of `(binding, state, data, theme)` — no hidden singletons.
2. Every component wraps its painter/body in a `RepaintBoundary`; data updates replace
   immutable data objects (Riverpod `==` semantics) so unchanged components don't rebuild.
3. Every component implements the three required states (loading / empty / binding-error)
   with design-system primitives — a filtered-to-empty chart is a designed state, not a bug.
4. Accessibility is part of the contract: each component provides a semantic summary
   ("Bar chart: errors by service, top value payments, 1,204") and full data remains
   reachable via the table view.
5. Goldens: one golden per component × theme × (normal, empty, error) state, run in CI.
