# ADR-0007 — Persistence: folder-per-workspace, JSON docs + binary snapshots, atomic writes

## Context
Spec §11: persistent workspaces, autosave, undo, duplication, recovery after termination,
no dataset duplication, graceful handling of unavailable sources. Options: SQLite database,
embedded KV store, or structured files.

## Decision
**Structured files with atomic-rename discipline** (full design:
[06-persistence.md](../architecture/06-persistence.md)): `library.json` index;
`workspaces/<id>/workspace.json` (the UI-schema doc) + command journal;
`datasets/<sha256>/` content-addressed store (immutable source copy + bincode columnar
snapshot + profile.json). All writes are tmp→fsync→rename; startup sweeps tmp files and
replays journals. A `WorkspaceStore` trait isolates access so a SQLite backend can replace
it later without touching engine logic. Checksum: blake3 (fast, small crate) on snapshots —
pinned here as the Phase 0 choice.

## Alternatives
- **SQLite (rusqlite) now** — robust transactions and queries, but: another native library
  per ABI, and MVP access patterns (list few dozen workspaces, open by id) don't need SQL.
  Revisit trigger: workspace counts in the hundreds, full-text library search, or concurrent
  multi-session writes.
- **Re-parse source on every open (no snapshot)** — rejected: reopen latency would scale
  with file size; snapshot gives O(read) reopen with source as fallback.
- **Single monolithic app database** — rejected: per-workspace folders make corruption
  blast radius tiny, export trivial, and debugging human-readable.

## Consequences
- Crash safety without a DB engine; recovery paths are explicit and testable (reliability
  suite kills the process mid-write).
- Content addressing gives dedup + a re-link story for revoked permissions for free.
- Cost: we implement journal compaction and GC ourselves (bounded, ~300 lines, well-tested).
- bincode snapshot format is versioned (magic `MRPHDS`, v1); unsupported versions trigger
  transparent re-ingest from source, never data loss.
