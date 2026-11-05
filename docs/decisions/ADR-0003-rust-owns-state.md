# ADR-0003 — Rust owns canonical state; command/snapshot synchronization

## Context
Spec §11/§18 forbid competing unsynchronized workspace states in Dart and Rust, and forbid
Dart owning core workspace data. Two-way reactive sync of a rich model across FFI is a
classic source of drift bugs.

## Decision
**Single-writer, command-sourced model.** Rust owns datasets, workspace docs, undo history,
and persistence. Dart sends typed `Command` batches; the engine validates atomically,
applies, journals, bumps a revision, and emits `WorkspaceChanged{revision, affected}`. Dart
renders immutable snapshots keyed by revision and fetches data pages on demand. Ephemeral
UI state (scroll, focus, animation) stays in Dart and is never authoritative.

## Alternatives
- **Dart owns workspace, Rust is a stateless calculator** — rejected: violates spec; undo,
  persistence, and incremental recompilation would live in the wrong layer; AI commands (P2)
  would need a second mutation path.
- **Shared mutable state via FFI pointers** — rejected: ownership/lifetime hazards, no
  clear serialization boundary, impossible to journal.
- **Full event-sourcing with replay-only persistence** — partially adopted (command journal)
  but snapshots remain the primary store: replay-only complicates migration and open time.

## Consequences
- One mutation path for UI gestures today and NL/AI commands tomorrow — the security and
  undo stories collapse into one mechanism.
- Snapshot/page caching by revision is race-free; optimistic UI is limited to ephemera.
- Cost: every mutation is a round-trip. Mitigation: commands are batched, apply is fast
  (doc-sized), and data recomputation is incremental per affected component.
- Testability: engine state transitions are pure Rust unit tests; Dart tests mock the bridge.
