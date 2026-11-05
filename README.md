# MORPHIC

**Your Data. Your Interface.** · One Engine. Infinite Interfaces.

MORPHIC is an AI-native, local-first **adaptive workspace engine**. Instead of forcing your
information into a predefined app, MORPHIC analyzes the data you give it — logs, CSV, JSON,
documents — and *generates* the interactive workspace that data deserves: timelines, tables,
charts, metric cards, and (later) relationship graphs and knowledge spaces.

- **Flutter** application layer (Android first, iOS architecturally supported)
- **Rust** core engine (ingestion, semantics, queries, UI compilation, persistence)
- **Generative UI, not generative code** — a validated, versioned UI schema interpreted by a
  trusted component runtime
- **Local-first** — core functionality works fully offline; cloud AI is optional and explicit

## Project status

| Phase | Scope | Status |
|---|---|---|
| **0 — Foundation** | Architecture, decisions, contracts, plans + scaffolding | 🟢 **Executed — CI green, Android APK built** ([status](docs/roadmap/phase-0-status.md)) |
| 1 — MVP | Import → analyze → generated interactive workspace → save/reopen | 🟡 Next (M1.1) |
| 2 — Intelligence | Semantics, natural-language commands, optional local AI | ⚪ Planned |
| 3 — Native engine | Rendering optimization, spatial indexing, benchmarks; Vulkan only if measured need | ⚪ Planned |
| 4 — Universal workspace | More formats, specialized workspaces, templates, iOS prep | ⚪ Planned |
| 5 — Ecosystem | Plugins, sharing, SDK | ⚪ Planned |

## Start here

📚 **[Documentation index](docs/README.md)**

- [Product brief](docs/product/product-brief.md) · [Full specification](docs/product/morphic-spec.md)
- [System architecture](docs/architecture/01-system-overview.md)
- [Technical decisions (ADRs)](docs/decisions/README.md)
- [Repository structure](docs/engineering/repo-structure.md) · [Dependency strategy](docs/engineering/dependency-strategy.md)
- [Phase 0 execution plan](docs/roadmap/phase-0-foundation.md) · [Phase 1 MVP plan](docs/roadmap/phase-1-mvp-plan.md)

## Repository layout (target)

```
apps/morphic_flutter/   Flutter app + Rust bridge crate (cargokit)
engine/crates/          Rust engine workspace (ingest, semantic, query, schema, compiler, workspace, core)
schemas/                Exported JSON Schema artifacts (generated, drift-checked in CI)
fixtures/               Curated test datasets (valid + malformed corpus)
docs/                   Architecture, decisions, plans, design system
tools/                  Developer scripts (schema export, benchmarks)
.github/workflows/      CI/CD (created during Phase 0 execution)
```

## License

TBD — to be decided before first public release.
