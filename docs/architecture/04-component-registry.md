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

### 4.1 As implemented in M1.4 task 1.4.7

`morphic-schema::convert_component_type` is the authority; `component_type_options` returns
exactly the targets for which it succeeds against the live profile. The table above is the
intent, with these clarifications:

* **"temporal" means bucketable, not a Temporal *role*.** A line's `x` must be
  `Timestamp`/`Int64`/`Float64`; a timeline's `time_field` must be `Timestamp`. Pass 3
  (`validate_bindings`) accepts a `Utf8` column whose inferred role is Temporal, but
  `series_scene`/`timeline_scene` refuse to bucket it. 1.4.5 found three generated charts that
  validated and then failed at the first draw — a manual switch is a second way to build that
  same broken document, so the matrix applies the **query layer's** rule.
* `bar → line`, `line → bar`, `bar → metric`, `line → timeline`, `timeline → line`, and
  `any → data_table` are the explicit pairs. `metric → chart` and `data_table → chart` propose
  a default binding from the profile (preferring the columns the old view showed, ties by
  name). Anything else is refused with a readable reason rather than a partial edit.
* A conversion also rewrites `interactions`, `title` and `explanation` — pass 2 requires
  `binding.kind()` to equal `type`, and pass 5 rejects state the new type cannot hold. State
  that is cleared is **named in the new explanation**, which 1.4.6's sheet renders.
* The command is atomic: it runs on a clone, the whole result is checked with all five passes
  plus pass 3, and only then is it saved at one new revision. A rejected switch in a batch
  discards the batch's other commands too.

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
