# ADR-0001 — Monorepo: Flutter app + root Cargo workspace

## Context
Spec §19 proposes a modular monorepo and explicitly allows adapting the physical layout to
tooling. Flutter expects a self-contained app package; Cargo expects a workspace; cargokit
(the frb build integration) expects a Rust crate reachable from the Flutter package.

## Decision
One repository. **Cargo workspace root at the repo root** (`Cargo.toml`) with members
`engine/crates/*` and `apps/morphic_flutter/rust` (the bridge crate). One `Cargo.lock`, one
`target/`, shared dependency versions via `[workspace.dependencies]`. The Flutter app is a
single pub package at `apps/morphic_flutter/` (pub workspaces ready if we later extract
packages). Schemas, fixtures, docs, tools live at top level. Full tree:
[repo-structure.md](../engineering/repo-structure.md).

## Alternatives
- **Separate repos (app / engine)** — rejected: atomic cross-layer changes, one CI, one
  version story; the spec's vertical-slice workflow demands lockstep evolution early on.
- **Cargo workspace under `engine/` only, bridge crate outside it** — rejected: two lockfiles
  and duplicate builds of the same crates; cargokit path juggling.
- **Melos multi-package Dart from day one** — rejected: one app package is enough for MVP;
  extraction (e.g. design system) happens when a second consumer exists.

## Consequences
- `cargo test --workspace` tests the whole engine; `flutter test` tests the app; CI caches
  both toolchains independently.
- The bridge crate is a workspace member, so engine refactors and FFI updates land in one PR.
- Root-level `Cargo.toml` means Rust tooling works from repo root — good DX.
- Constraint: Flutter app must not contain Rust product logic (bridge is a thin facade) —
  enforced by review + the crate dependency DAG.
