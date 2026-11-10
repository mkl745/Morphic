# 03 — MORPHIC UI Schema v1.0

Status: **Design frozen; formal types land in `morphic-schema` during Phase 0** ·
Implements spec §6 · Related: [ADR-0006](../decisions/ADR-0006-ui-schema-typed-contract.md)

The UI Schema is the product's central intellectual property: a **declarative, versioned,
validated description of a workspace**. It is data — never code. The Rust compiler produces
it; the Rust validator gates it; the Flutter runtime interprets it through a closed component
registry. AI (Phase 2+) may *propose* documents, but they pass the identical validation.

## 1. Design rules

1. **Closed world.** Only registered component types and known property keys are legal.
   Unknown keys are validation errors, not silently ignored (prevents drift and injection).
2. **Typed bindings.** Every data reference is checked against the dataset profile: field
   existence, type compatibility, aggregation legality.
3. **No expressions-as-strings.** Filters are typed JSON trees with a fixed operator set.
   There is no `eval`, no scripting, no formula language in v1.0.
4. **Resource-bounded.** Component count, filter depth, page sizes, series lengths are
   capped at validation time.
5. **Explainable.** Every generated component carries a machine-readable explanation of
   *why* it exists (spec §3-D step 9).
6. **Versioned & migratable.** `schemaVersion` gates loading; migrations are pure functions
   `vN → vN+1` with golden tests.

## 2. Document structure

```jsonc
{
  "schemaVersion": "1.0",
  "workspace": {
    "id": "w_01JG…",                          // ULID, engine-assigned
    "title": "Log Intelligence",
    "createdAt": "2026-11-05T09:00:00Z",
    "modifiedAt": "2026-11-05T09:00:00Z",
    "revision": 7,                             // engine-managed, monotonically increasing
    "generator": { "kind": "deterministic", "version": "1.0.0" },
    "dataSources": [
      { "alias": "logs", "datasetId": "d_sha256_…" }
    ],
    "layout": {
      "mode": "adaptive",                      // v1: adaptive | grid. "freeform" reserved (P2/P3)
      "order": ["errors_metric", "event_timeline", "log_table"],
      "hints": [                               // manual adjustments persist here
        { "componentId": "errors_metric",  "span": 1, "height": "small" },
        { "componentId": "event_timeline", "span": 2, "height": "medium" },
        { "componentId": "log_table",      "span": 2, "height": "large" }
      ]
    },
    "globalFilters": [],                       // FilterExpr[] — apply to all bound components
    "fieldOverrides": [                        // user corrections of engine assumptions
      { "field": "level", "role": "severity" }
    ],
    "components": [ /* ComponentSpec[] */ ]
  }
}
```

`layout.hints` is an **array of records**, one per component (the object-by-id shape in an
earlier draft never matched `morphic_schema::Layout`). Since 1.5.2, `ResizeComponent` writes
`componentId`, `span` (`1..=3`) and `height` (`small | medium | large`; empty means intrinsic).
Pass 1 rejects duplicate hints, unknown component ids, oversized spans and unknown heights, so
the renderer can trust the vocabulary. Phone focus mode is view-only and is not persisted here.

### 2.1 ComponentSpec (common envelope)

```jsonc
{
  "id": "errors_metric",                      // unique within workspace, [a-z0-9_]{1,64}
  "type": "metric_card",                      // registry key
  "typeVersion": "1.0",                       // registry contract version
  "title": "Errors",                          // optional display override
  "dataSource": "logs",                       // must match a dataSources alias
  "binding": { /* type-specific, see registry */ },
  "interactions": { "filter": true, "search": false, "sort": false, "select": false },
  "state": { /* type-specific persisted state, e.g. active sort */ },
  "explanation": {
    "reason": "R2b_error_metric",              // a RULE_TABLE id, not free text
    "detail": "'level' carries severity levels, so the count of error-level records is a headline number.",
    "evidence": ["1 error-shaped level(s) observed"],  // strings, not objects
    "confidence": 0.97                        // 0..1
  }
}
```

`Explanation` is `{ reason: String, detail: String, evidence: Vec<String>, confidence: f64 }`
in `morphic-schema`. An earlier draft of this example drew `evidence` as an array of
`{field, fact, value}` objects; the shipped type is a list of human-readable strings, and the
"Why this view?" sheet (M1.4 task 1.4.6) renders those strings verbatim. `reason` is a
`RULE_TABLE` id so a reader can trace a card back to the rule that fired; it is not prose.
`confidence` is the planner's confidence in the *field readings* behind the choice, in `0..1`
— not a rating of whether the chart is useful.

### 2.2 Bindings for the MVP five

```jsonc
// metric_card
{ "aggregation": { "op": "count", "filter": { "op":"eq", "field":"level", "value":"ERROR" } },
  "format": { "decimals": 0, "compact": true } }

// data_table
{ "columns": ["time","level","service","message"],   // optional projection; default: all, capped
  "pageSize": 256,
  "features": { "search": true, "sorting": true, "filtering": true } }

// bar_chart
{ "dimension": "service",
  "measure": { "op": "count" },
  "sort": { "by": "measure", "dir": "desc" },
  "limit": 12 }                                       // top-N, remainder → "Other"

// line_chart
{ "x": "time",                                       // temporal or numeric field
  "y": [ { "op": "count" } ],                         // series: aggregation or {op:avg, field}
  "bucket": { "unit": "hour", "size": 1 },            // auto-selected from time range in v1
  "groupBy": "level" }                                // optional series split (≤ 8 groups)

// timeline
{ "timeField": "time",
  "groupBy": "level",                                 // optional lanes/coloring
  "severityField": "level",                           // optional severity coloring
  "density": "auto" }
```

### 2.3 FilterExpr — the safe expression grammar

```jsonc
{ "op": "and", "args": [
  { "op": "gt",  "field": "time",  "value": { "timestamp": "2026-11-05T14:00:00Z" } },
  { "op": "or",  "args": [
      { "op": "eq", "field": "level", "value": { "string": "ERROR" } },
      { "op": "eq", "field": "level", "value": { "string": "FATAL" } } ] }
] }
```

- Operators (closed set): `and or not eq neq gt gte lt lte in contains starts_with between
  is_null not_null`.
- Literals are **tagged** (`{string}`, `{int}`, `{float}`, `{bool}`, `{timestamp}`) so type
  checking is exact; comparisons against mismatched field types fail validation.
- Limits: depth ≤ 8, nodes ≤ 64, `in` list ≤ 256 values.
- `contains/starts_with` are string-only, case-insensitive by default, and operate on data —
  they are never interpreted as instructions (prompt-injection stance, spec §12).

### 2.4 Aggregation grammar

`{ op: count | sum | avg | min | max | distinct_count, field?, filter? }` — `count` may omit
`field`; all others require a numeric/temporal field compatible with the op. No nested
aggregations in v1.0.

## 3. Validation — five passes, in order

| Pass | Checks | Failure example |
|---|---|---|
| 1. Structural | typed serde decode; unknown keys rejected; JSON-Schema equivalent holds | `"type": "web_view"` |
| 2. Registry | type exists, `typeVersion` supported, binding matches component contract | line_chart bound to string x |
| 3. Binding | aliases exist; fields exist; types compatible; aggregation legal | sum over `message` |
| 4. Resources | ≤ 64 components; table projection ≤ 32 cols; filter depth/nodes; pageSize ≤ 1024; series ≤ 2000 pts; groupBy ≤ 8 | 65th component |
| 5. Referential | unique ids; layout order ⊆ component ids (and covers all); state keys valid for type; layout hints reference real components once | hint for deleted component |

Every failure returns `EngineError::Validation { pointer, rule }` with a JSON-pointer into
the document — this is what makes AI output debuggable in Phase 2.

## 4. Versioning & migration policy

- `schemaVersion` is `major.minor`. **Minor** = additive (new optional fields, new component
  types): old runtimes reject unknown *components* gracefully with a placeholder card, and
  loading never corrupts the doc. **Major** = breaking: requires a registered migration
  chain; documents from the future are refused with a clear message (never lossy-downgraded).
- Migrations are pure, total functions in `morphic-schema` with golden fixtures per hop.
- The persisted workspace stores the doc verbatim + a `lastMigratedFrom` audit field.
- The JSON Schema artifact (`schemas/morphic_ui_schema_v1.json`) is **generated from the
  Rust types via `schemars`** and drift-checked in CI — one source of truth.
- v1.0 gained one **additive optional** field in 1.5.1: `workspace.fieldOverrides`
  (`[{field, dtype?, role?}]`). It is omitted when empty, so documents written before the
  field existed still load byte-for-byte; the closed vocabularies are schema-validated.

## 5. What v1.0 deliberately excludes

Freeform coordinates (reserved enum value only), joins/multi-dataset bindings (list shape
already supports it), computed fields/formulas, actions beyond the closed command set,
theming inside the doc (theme is app-level), and any form of embedded code. Each exclusion
has a phase owner in the [roadmap](../roadmap/phase-1-mvp-plan.md).
