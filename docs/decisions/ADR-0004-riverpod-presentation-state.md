# ADR-0004 — Riverpod 3 (Notifier API) for presentation state

## Context
Spec §4.1: choose state management on complexity/maintainability, avoid unnecessary
complexity, and keep core logic out of Flutter. The app's state is mostly *server-like*
(engine snapshots + async operations) plus ephemeral UI state.

## Decision
**flutter_riverpod 3.3.x** with the modern `Notifier`/`AsyncNotifier` API (no legacy
providers). Codegen (`riverpod_generator`) used where it reduces boilerplate; manual
providers where clearer. Structure: one `EngineController` wrapping the bridge; per-feature
controllers (`ImportController`, `WorkspaceController`, `LibraryController`); component
widgets watch narrowly-scoped providers (snapshot slice + data page) so unrelated components
don't rebuild (Riverpod 3 `==`-based update semantics).

## Alternatives
- **Bloc** — solid, but more ceremony for our snapshot-driven model; event/state classes
  would duplicate the engine's command/event types.
- **Plain ChangeNotifier / InheritedWidget** — rejected: async lifecycle, caching, and
  scoped disposal are exactly what we'd hand-roll badly.
- **signals/mobx-style reactive cores** — smaller ecosystems; team longevity favors Riverpod.

## Consequences
- Testable without BuildContext; controllers mock the bridge interface cleanly.
- Auto-dispose + pausing offscreen listeners (Riverpod 3) helps battery on long workspaces.
- Discipline required: providers must not re-implement engine logic (filtering, sorting).
  Lint rule + review checklist: "if it computes over dataset rows, it belongs in Rust."
- Migration risk low: 3.x is the current stable line (3.0 shipped 2025-09).
