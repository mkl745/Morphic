# 06 — Workspace Persistence & State

Status: **Design frozen for Phase 0** · Implements spec §11 ·
Related: [ADR-0007](../decisions/ADR-0007-persistence-files-atomic.md), [ADR-0003](../decisions/ADR-0003-rust-owns-state.md)

## 1. Storage layout (app-private documents dir; root supplied by Dart)

```
<storageRoot>/morphic/
├── library.json                     # workspace index (id, title, datasetRefs, timestamps)
├── datasets/
│   └── <sha256-of-source>/
│       ├── source.<ext>             # immutable copy of the imported file
│       ├── snapshot.bin             # columnar Table + Profile cache (magic MRPHDS, ver 1)
│       └── profile.json             # human-readable profile (debugging, export later)
└── workspaces/
    └── <workspace-id>/
        ├── workspace.json           # WorkspaceDoc (UI schema) + meta + fieldOverrides
        ├── journal/                 # command journal for undo + crash recovery
        │   ├── 000001.cmds.jsonl
        │   └── …
        └── .lock                    # session lock (stale-lock detection on open)
```

Principles:

- **Workspaces reference datasets by content hash** — no dataset duplication; two workspaces
  over the same file share one store entry. Deleting a workspace never deletes a dataset
  still referenced (ref-count via library scan; GC is explicit, later).
- **Workspace definitions are small JSON** (kilobytes): portable, diffable, migratable.
  **Datasets are binary snapshots** (bincode, versioned magic) for fast reopen without
  re-parsing; `source.*` remains the recovery fallback if a snapshot is corrupt or its
  format version is unsupported (re-ingest transparently).
- SQLite is deliberately deferred (ADR-0007): a folder-per-workspace + atomic index meets
  MVP scale; the access layer is a trait so SQLite can replace it without touching callers.

## 2. Write discipline (crash safety)

Every mutation of a persisted file: **write `*.tmp` → fsync → atomic rename → fsync dir**.
`library.json` and `workspace.json` are never written in place. On startup:

1. Sweep orphaned `*.tmp` (discard — they are never authoritative).
2. Detect stale `.lock` files (process gone) → mark workspace "recovering".
3. Replay journal entries newer than the last saved snapshot → restore pre-crash revision,
   then compact.

Autosave policy (engine-owned): debounce 2 s after last command **and** immediate flush on
app lifecycle pause (Dart sends `closeSession`/`save` on `AppLifecycleState.paused`).
Explicit save compacts the journal into `workspace.json`.

## 3. Undo / redo

- Command-sourced: every applied batch is journaled `{revision, commands[], inverseSummary}`
  before the snapshot update is acknowledged.
- In-memory undo/redo stacks (cap 100 revisions) hold snapshot diffs of the *workspace doc*
  (small); data itself is immutable per dataset revision, so undo never copies tables.
- `undo()`/`redo()` are engine operations returning `ApplyResult` — Dart never reconstructs
  state itself. Journal compaction keeps the last 100 revisions on disk.
- Field overrides and layout moves are ordinary commands → undoable for free.

## 4. Workspace lifecycle operations

| Op | Semantics |
|---|---|
| create | compile initial doc (revision 1) → persist → index |
| open | load doc → migrate if needed → verify dataset refs → replay journal → session |
| rename | meta-only command (undoable) |
| duplicate | new id, same dataset refs, copy doc + reset journal |
| delete | tombstone in index → remove folder (datasets untouched) |
| missing dataset | open in **degraded mode**: layout/definitions visible, data panels show "source unavailable" + re-link flow (re-import same content restores by hash) |
| export (P1 stretch) | `.morphic` zip = workspace.json + referenced dataset snapshots + manifest |

## 5. Migration & integrity

- `workspace.json` carries `schemaVersion` + `lastMigratedFrom`; migration chain per
  [UI Schema §4](03-ui-schema.md). Migration writes a new file atomically; the pre-migration
  copy is kept as `workspace.pre-vN.json.bak` for one version (rollback safety).
- `snapshot.bin` carries format magic + version + checksum (xxhash/blake3 — picked in
  Phase 0, recorded in ADR-0007 addendum). Corrupt snapshot → transparent re-ingest from
  `source.*`; corrupt source too → degraded mode, never a crash.
- Corrupted workspace JSON → attempt journal reconstruction; else quarantine file and show
  recovery UI (spec §15 reliability tests cover all of these).

## 6. Privacy notes

All storage is app-private (Android sandbox). No raw data in logs or crash metadata.
Encryption-at-rest beyond OS sandboxing is a documented future option (spec §12 "optional
encrypted workspace storage") — the store trait leaves room for an encrypting decorator;
not built in MVP.

## 7. Implementation status (M1.1, task 1.1.6)

This document is the target contract. What the file backend actually implements today:

| Element | Status | Note |
| --- | --- | --- |
| Folder-per-workspace, `library.json` index | **Built** | Index carries `revision` + `datasetId`; missing fields default so pre-1.1.6 indexes still read |
| Atomic write: tmp → fsync → rename → **fsync dir** | **Built** | `atomic_write`; orphaned `*.tmp` swept on startup |
| Content-addressed `datasets/<sha256>/source.csv` | **Built** | §1 shows the source inside the dataset folder; a workspace references it by hash |
| Write-ahead journal + replay + compaction | **Built** | Entry is `{revision, commands, doc}`. `commands` is empty in M1.1; the full document is the payload |
| Torn trailing JSONL line tolerated | **Built** | Counted in `RecoveryReport`, dropped, never fatal |
| Corrupt JSON → rebuild, else quarantine | **Built** | Quarantine file is `workspace.corrupt.json`; typed `Corrupt` error |
| Missing source → degraded mode | **Built** | Typed `SourceUnavailable`; snapshot carries `degraded` + `notice`, data calls error |
| Recents newest-first | **Built** | `modifiedAt` desc, id tiebreak |
| Legacy in-workspace `source.csv` | **Built** | Loads via fallback, migrated on first open without a revision bump |
| `snapshot.bin` columnar cache | **Deferred** | Reopen re-ingests the source. The cache is a perf optimization for a 10 MB budget that is still unmeasured on hardware; a versioned binary format before that data exists is speculative risk |
| `.lock` session files | **Deferred** | Single-process app, sessions already mutex-serialized; a stale-lock protocol would add failure modes with no concurrent writer to guard |
| `inverseSummary` / undo journal (§3) | **M1.5** | No edit surface exists yet, so there is nothing to undo |
| Dataset garbage collection | **Not built** | Deleting a workspace deliberately keeps its dataset: another workspace may share the hash |

`RecoveryReport` (`sweptTmp`, `tornJournalLines`, `restoredFromJournal`, `quarantined`,
`migratedLegacySource`) exists so recovery can be *reported* to the user rather than performed
silently. Surfacing it in the UI is 1.1.7+ work; today it is returned and tested.
