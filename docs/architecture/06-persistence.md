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

**As shipped in 1.5.1:** the journal record is `{revision, commands[], inverseSummary,
label, stateHash, doc}`; `history.json` holds the reconciled stacks; undo/redo bump the
revision but `stateHash` excludes `revision`/`modifiedAt`. A crash between the history file
and the document is repaired by matching the authoritative document's hash on reopen.

**Since 1.5.2:** `ResizeComponent` writes the closed-vocabulary `layout.hints` records into
that same `doc`, so span/height changes survive reopen and undo restores the previous hints.
Phone focus mode is view-only and deliberately leaves no journal entry.

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

*As shipped in 1.5.3:* rename is a **persisted document edit** (title, `revision + 1`,
`modifiedAt`) that rewrites `library.json` and re-seeds `history.json` — not a meta-only
undoable command. Duplicate writes a second document with a fresh id, `createdAt`,
`modifiedAt` and `revision = 1`, plus its own empty journal/history; it copies no dataset
bytes. Delete removes the workspace folder and index entry but deliberately leaves the shared
dataset. Re-link re-adds source bytes only when their SHA-256 equals the `datasetId` already
in the document; a different file is refused. All four drop the in-memory session so the next
`snapshot` rehydrates from disk. The home library menu and the degraded-mode app-bar action are
the two UI entry points.

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
| Write-ahead journal + replay + compaction | **Built** | Since 1.5.1 the entry is `{revision, commands, inverseSummary, label, stateHash, doc}`; commands carry the real batch and compaction keeps the last 100 states, not just the crash scratch pad |
| Torn trailing JSONL line tolerated | **Built** | Counted in `RecoveryReport`, dropped, never fatal |
| Corrupt JSON → rebuild, else quarantine | **Built** | Bad bytes are preserved as `workspace.corrupt.json` **even when the journal can rebuild the document**, so recovery never destroys the only evidence. With nothing to rebuild from, a typed `Corrupt` error is returned |
| Missing source → degraded mode | **Built** | Typed `SourceUnavailable`; snapshot carries `degraded` + `notice`, data calls error |
| Recents newest-first | **Built** | `modifiedAt` desc, id tiebreak |
| Legacy in-workspace `source.csv` | **Built** | Loads via fallback, migrated on first open without a revision bump |
| `history.json` undo/redo stacks | **Built (1.5.1)** | Bounded to 100 frames; reconciled on open so a crash cannot resurrect a future redo state |
| Library rename / duplicate / delete | **Built (1.5.3)** | Engine-owned document + index + history seed; duplicate shares the dataset; four additive FFI entry points (contract doc 02 §2.4.4) |
| Hash-verified degraded re-link | **Built (1.5.3)** | `relink_workspace` compares the picked bytes' SHA-256 with the document's `datasetId`, then reopens the session; different bytes are rejected |
| Persisted `fieldOverrides` | **Built (1.5.5)** | One record per field, with `dtype` and/or `role`; stored in `workspace.json`, validated against the closed vocabularies, and included in every history frame, so undo restores the original inference and the recompiled bindings together (contract doc 02 §2.4.5) |
| `snapshot.bin` columnar cache | **Deferred** | Reopen re-ingests the source. The cache is a perf optimization for a 10 MB budget that is still unmeasured on hardware; a versioned binary format before that data exists is speculative risk |
| `.lock` session files | **Deferred** | Single-process app, sessions already mutex-serialized; a stale-lock protocol would add failure modes with no concurrent writer to guard |
| `inverseSummary` / undo journal (§3) | **Built (1.5.1)** | Engine-owned stacks, app-bar controls and snackbars shipped; `history.json` is reconciled against the doc hash |
| Dataset garbage collection | **Not built** | Deleting a workspace deliberately keeps its dataset: another workspace may share the hash |

`RecoveryReport` (`sweptTmp`, `tornJournalLines`, `restoredFromJournal`, `quarantined`,
`migratedLegacySource`) exists so recovery can be *reported* to the user rather than performed
silently. Surfacing it in the UI is 1.1.7+ work; today it is returned and tested.
