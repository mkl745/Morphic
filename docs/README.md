# MORPHIC Documentation

Phase 0 foundation documents. Everything here is a **plan or contract** — no application code
exists yet. Implementation begins with [Phase 0 execution](roadmap/phase-0-foundation.md)
once approved.

## Reading order

| # | Document | What it answers |
|---|---|---|
| 1 | [Product brief](product/product-brief.md) | What are we building, for whom, and what is the MVP hypothesis? |
| 2 | [System overview](architecture/01-system-overview.md) | Layers, module boundaries, data flow, state ownership |
| 3 | [Dart ↔ Rust contract](architecture/02-dart-rust-contract.md) | The exact FFI surface, threading, errors, versioning |
| 4 | [UI Schema v1.0](architecture/03-ui-schema.md) | The declarative workspace format — the product's core IP |
| 5 | [Component registry](architecture/04-component-registry.md) | Trusted components, their contracts, MVP set |
| 6 | [Data pipeline](architecture/05-data-pipeline.md) | Ingestion → semantic profiling → query execution |
| 7 | [Persistence](architecture/06-persistence.md) | Storage layout, workspace format, undo, crash recovery |
| 8 | [Rendering](architecture/07-rendering.md) | Flutter-first strategy, renderer abstraction, the Vulkan gate |
| 9 | [Platform & security](architecture/08-platform-and-security.md) | Android-first / iOS-ready, privacy and threat model |
| 10 | [Decision records](decisions/README.md) | Every significant technical choice, with alternatives |
| 11 | [Repository structure](engineering/repo-structure.md) | Physical monorepo layout and why |
| 12 | [Dependency strategy](engineering/dependency-strategy.md) | Every dependency, version, justification, exit path |
| 13 | [CI/CD](engineering/ci-cd.md) | GitHub Actions pipelines, releases, supply chain |
| 14 | [Quality & performance](engineering/quality-and-performance.md) | Test strategy, fixtures, benchmarks, budgets |
| 15 | [Design system](design/design-system.md) | Visual identity, tokens, responsive rules, accessibility |
| 16 | [Phase 0 execution plan](roadmap/phase-0-foundation.md) | The scaffolding checklist and its exit criteria |
| 17 | [Phase 1 MVP plan](roadmap/phase-1-mvp-plan.md) | Milestones, tasks, dependencies, exit criteria |
| 18 | [MVP acceptance tests](roadmap/mvp-acceptance-tests.md) | Formal, measurable definition of "MVP works" |
| 19 | [Risk register](roadmap/risk-register.md) | What could hurt us and what we do about it |

## Source of truth

The [original product specification](product/morphic-spec.md) is preserved verbatim. Where a
foundation document narrows or adapts it (always allowed by spec §19/§21), the document says so
explicitly and records the decision as an ADR.

## Conventions

- **ADR** — Architecture Decision Record: context → decision → alternatives → consequences.
- **MUST / SHOULD / MAY** — RFC 2119-style requirement strength in contracts.
- **Budget (hypothesis)** — a performance target to be *validated experimentally* on real
  devices, never advertised as a measured fact (spec §16).
- Versions in the dependency strategy were verified against public sources on **2026-11-05**;
  exact pins are locked in lockfiles during Phase 0 execution.
