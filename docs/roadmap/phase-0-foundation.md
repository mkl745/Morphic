# Phase 0 — Foundation: Execution Plan

Objective (spec §13): *a clean, modular Flutter application with a working Rust integration
and a demonstrable data-processing proof of concept* — plus the contracts and infrastructure
that make Phase 1 fast. **This document is the checklist; the architecture it implements is
already written (docs 01–08, ADRs).** Nothing here is executed until the user gives the go.

Effort key: S ≈ half a focused day · M ≈ 1–2 days · L ≈ 3–5 days (engineering estimates;
agent execution compresses calendar time but not verification).

## Tasks

| # | Task | Size | Depends on | Exit evidence |
|---|---|---|---|---|
| 0.1 | **Scaffold monorepo**: root Cargo workspace + 8 engine crates with boundary READMEs and stub lib.rs; `flutter create` app (android, ios) at `apps/morphic_flutter`; strict lints; .gitignore; toolchain pins (`rust-toolchain.toml`, Flutter version doc) | M | — | `cargo check --workspace` + `flutter analyze` clean |
| 0.2 | **Bridge PoC**: frb 2.13 integration (bridge crate + cargokit); `enginePing() -> EngineInfo{apiVersion, coreVersion}`; one real data call `profileCsvBytes(bytes) -> {rows, cols, detectedTypes}` (the spec's "demonstrable data-processing PoC"); panic firewall; committed generated code | L | 0.1 | PoC runs on Android emulator/device **and** host tests; screenshot/log evidence |
| 0.3 | **UI Schema v1.0 types** in `morphic-schema` per [doc 03](../architecture/03-ui-schema.md): full types, 5-pass validator skeleton (passes 1–2 real, 3–5 stubbed with tests marked `#[ignore]` until bindings exist), schemars export + registry manifest export, first migration test harness | L | 0.1 | `schemas/*.json` generated; validator unit tests green |
| 0.4 | **Persistence skeleton** in `morphic-workspace`: store trait + files backend, atomic write util, library.json, journal format, crash-recovery sweep; round-trip tests incl. kill-mid-write simulation | M | 0.3 | recovery tests green |
| 0.5 | **Design system foundation**: tokens, light/dark themes, typography assets (Inter/JetBrains Mono), core primitives (MorphicCard, SectionHeader, StateSurface); golden test setup | M | 0.1 | token contrast tests + first goldens green |
| 0.6 | **CI/CD**: implement `ci.yml`, `release.yml` (unsigned until secrets), `nightly.yml`, dependabot, drift gates, alignment check script, PR template, branch protection recommendation applied | L | 0.2, 0.3 | all required checks green on a PR; debug APK artifact downloadable |
| 0.7 | **Fixture corpus v1 + manifest**: ~20 valid + ~10 malformed files with expected profiles (hand-labeled); generator script for large perf fixtures | M | — | fixtures load in tests |
| 0.8 | **Perf harness skeleton**: criterion benches (placeholder parse bench real), Dart frame-timing collector + JSON emitter, `perf-log.md` started with host baseline | M | 0.2 | first bench JSON artifact in CI |
| 0.9 | **App shell**: go_router routes (home/import/workspace/settings placeholders wired to design system), Riverpod EngineController with real `engineInit`, lifecycle save hook, home screen renders real engine version via bridge | M | 0.2, 0.5 | app boots to home on emulator showing live engine info |
| 0.10 | **Docs consolidation**: toolchain.lock.md, release-runbook.md, crate READMEs, update root README status | S | all | docs match reality |

## Phase 0 exit criteria (all required)

1. `cargo test --workspace` and `flutter test` green; CI required checks enforced.
2. On a real Android device/emulator: app boots, calls Rust, displays a CSV profile computed
   in Rust (PoC), survives process death and relaunch.
3. Generated artifacts (frb glue, JSON Schema, registry manifest) drift-gated in CI.
4. Signed-release pipeline dry-runs end-to-end (unsigned mode acceptable until secrets set).
5. Perf harness produces its first baseline JSON; fixture corpus loadable.
6. No placeholder functionality presented as complete (spec §21): stubs are labeled,
   `#[ignore]`d, and tracked by the Phase 1 tasks that replace them.

## Explicitly NOT in Phase 0

Real parsers beyond the CSV PoC, real compiler rules, real components beyond primitives,
any AI, any canvas. Those are Phase 1 milestones below — Phase 0 proves the *plumbing*.
