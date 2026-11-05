# 01 — System Overview

Status: **Approved for Phase 0 execution** · Owner: architecture · See [ADRs](../decisions/README.md)

## 1. Architectural statement

MORPHIC is a **three-layer system with one authoritative owner of state**:

1. **Flutter application layer (Dart)** — presentation, interaction, navigation, design
   system, and the *trusted component runtime* that interprets validated UI schemas.
2. **Rust core engine** — the canonical owner of datasets, semantic profiles, workspace
   models, query execution, UI compilation, persistence, and undo history.
3. **Platform layer** — Android first (file access, storage roots, lifecycle); iOS later
   behind the same abstractions. Native graphics backends (Vulkan/Metal) are *optional
   future accelerators*, never MVP dependencies.

The layers communicate through a **coarse-grained, typed, versioned bridge**
(flutter_rust_bridge). Dart never owns core data; Rust never imports Flutter.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  FLUTTER APP (Dart)                                                      │
│                                                                          │
│  features/        home · import · workspace · settings                   │
│  component_runtime/  registry → trusted widgets (table, charts, …)       │
│  rendering/       WorkspaceRenderer interface → FlutterRenderer          │
│  design_system/   tokens · themes · motion · typography                  │
│  state/           Riverpod 3 — presentation state + engine snapshots     │
│  navigation/      go_router                                              │
├──────────────────────────────────────────────────────────────────────────┤
│  BRIDGE  (flutter_rust_bridge 2.13, cargokit build)                      │
│  control plane: typed DTOs, commands, events (streams)                   │
│  data plane:    paged typed column buffers, pre-aggregated chart series  │
├──────────────────────────────────────────────────────────────────────────┤
│  RUST ENGINE (Cargo workspace, platform-independent)                     │
│                                                                          │
│  morphic-core      facade: sessions, command bus, undo/redo, events      │
│  morphic-ingest    format/encoding detection, streaming parsers          │
│  morphic-semantic  type inference, profiling, role detection             │
│  morphic-query     columnar store, filter/sort/group/aggregate/search    │
│  morphic-schema    UI Schema v1 types, validation, migration, export     │
│  morphic-compiler  profile + intent → visualization plan → UI schema     │
│  morphic-workspace persistence, dataset store, recovery, library index   │
│  morphic-model     shared domain primitives (values, columns, profiles)  │
├──────────────────────────────────────────────────────────────────────────┤
│  PLATFORM (Android first)                                                │
│  SAF file picker → copy into app storage · app documents dir · lifecycle │
│  [future] Vulkan texture backend · [future] Metal backend                │
└──────────────────────────────────────────────────────────────────────────┘
```

## 2. The two pipelines

### 2.1 Generation pipeline (data → interface)

```
file ──▶ INGEST ──▶ TABLE (columnar) ──▶ SEMANTIC ──▶ PROFILE
                                                      │
                       user intent (default: explore) │
                                                      ▼
                                                  COMPILER
                                          (visualization planning,
                                           layout composition,
                                           explanation generation)
                                                      │
                                                      ▼
                                              UI SCHEMA DOC v1.0
                                                      │
                                             VALIDATION (5 passes)
                                                      │
                                                      ▼
                                     WORKSPACE REVISION n (Rust-owned)
                                                      │  snapshot over bridge
                                                      ▼
                                     FLUTTER COMPONENT RUNTIME
                                     (registry instantiates widgets)
```

### 2.2 Interaction pipeline (user → data → interface)

```
gesture / control ──▶ COMMAND (typed, e.g. SetFilter, SetSort, MoveComponent)
                          │ bridge
                          ▼
                    morphic-core: validate → apply → revision n+1
                          │                └──▶ undo journal
                          ├─▶ query engine (recompute affected bindings only)
                          └─▶ WorkspaceChanged{revision, affected component ids}
                          │ bridge event
                          ▼
                    Dart: fetch affected snapshots/pages → rebuild only those widgets
```

**Incremental recompilation is a contract, not an optimization** (spec §5.4): a command
declares its blast radius; the engine recomputes only affected components. Changing one
chart never rebuilds the workspace.

## 3. Module boundaries and dependency rules

Cargo enforces these at compile time (crate graph is a DAG):

| Crate | Responsibility | May depend on | Must never |
|---|---|---|---|
| `morphic-model` | Value/DataType, Column/Table, FieldSchema, Profile, Provenance, ids | std + serde | do I/O, know UI or Flutter |
| `morphic-ingest` | sniffing, decoding, streaming CSV/JSON/JSONL/TXT/log parsing → Table + ImportReport | model | infer semantics, compile UI |
| `morphic-semantic` | type inference confirmation, statistics, role hints w/ confidence | model | parse files, execute queries |
| `morphic-query` | plan validation + execution over Tables; paging; result cache | model | know UI schema or files |
| `morphic-schema` | UI Schema v1.0 types, 5-pass validation, migration, JSON-Schema export | model | execute queries, render |
| `morphic-compiler` | planning rules: profile+intent → validated WorkspaceDoc + explanations | model, semantic, schema | touch files, call AI providers directly (goes through trait) |
| `morphic-workspace` | atomic persistence, dataset store, library, undo journal, recovery | model, schema | parse source formats |
| `morphic-core` | engine facade, sessions, command bus, undo/redo, event streams, resource budgets | all above | contain business logic that belongs in a subsystem |
| `morphic-bridge` (in `apps/morphic_flutter/rust/`) | FFI surface only: DTO mapping, frb opaque handles, panic firewall | core | contain product logic |

Dart-side rules:

- `component_runtime/` widgets receive **validated bindings + data pages**, never raw files.
- `features/` never call the bridge directly; they go through Riverpod controllers that wrap
  the generated bridge API. Exactly one wrapper layer (`lib/engine/`).
- `rendering/` is the only place that knows *how* pixels are produced; components ask for
  chart painters through it (seam for future backends).
- No Dart code duplicates engine logic (no client-side filtering of authoritative data;
  ephemeral UI state only).

## 4. State ownership (the most important table in this repo)

| State | Owner | Sync mechanism |
|---|---|---|
| Datasets (columnar), profiles | Rust | immutable ids + revision; Dart fetches pages |
| Workspace doc (components, layout, bindings, filters) | Rust | revisioned snapshots + change events |
| Undo/redo history | Rust | commands journaled; Dart only sends `undo()`/`redo()` |
| Persistence | Rust | atomic writes; Dart triggers save/autosave policy |
| Scroll offsets, focus, hover, animation, panel expansion | Dart | ephemeral, never persisted to workspace doc |
| Theme, navigation, route | Dart | Riverpod / go_router |
| Field-role corrections (user overrides) | Rust (stored in workspace) | command `OverrideFieldRole` → recompile affected |

**Rule:** any state that must survive restart lives in Rust. Any state that can die with the
widget tree lives in Dart. There is no third category.

## 5. Intelligence architecture (seam now, AI later)

The compiler depends on a trait, not a provider:

```rust
trait IntelligenceProvider {           // morphic-compiler
    fn suggest_visualizations(&self, profile: &Profile, intent: &Intent)
        -> Vec<Suggestion>;            // each with confidence + rationale
}
```

- **Phase 1:** `DeterministicProvider` — transparent rules (spec §9 division of labor).
- **Phase 2:** `LocalLlmProvider` (llama.cpp / ONNX evaluation) and optional
  `CloudProvider` — both produce *suggestions and schema candidates* that pass the same
  validation as deterministic output. AI can never bypass the compiler's validation passes.
- Natural-language commands (P2) compile to the **same typed Command set** the UI uses.
  There is exactly one mutation path into workspace state.

## 6. What we deliberately do NOT build yet

Per spec §18 (no speculative infrastructure): no Vulkan/Metal crates, no plugin host, no
network stack, no account system, no empty `graphics/android_vulkan` folders. The renderer
abstraction and intelligence trait are the only forward-looking seams, and both have an
immediate Phase 1 consumer, which is what makes them non-speculative.
