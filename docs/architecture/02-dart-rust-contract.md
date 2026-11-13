# 02 — Dart ↔ Rust Contract

Status: **Design frozen for Phase 0 PoC; names may refine during implementation** ·
Implements spec §4.2, §11, §21.9 · Related: [ADR-0002](../decisions/ADR-0002-bridge-flutter-rust-bridge.md), [ADR-0003](../decisions/ADR-0003-rust-owns-state.md)

## 1. Principles

1. **Coarse-grained calls.** One call = one meaningful operation (import, compile, query a
   page, apply commands). Never per-cell or per-widget calls.
2. **Two planes.** Control plane = small typed DTOs (frb-generated Dart classes). Data plane
   = paged, typed column buffers and pre-aggregated series. No JSON blobs for bulk data.
3. **Opaque handles.** Engine and session objects live in Rust (`RustAutoOpaque`); Dart holds
   handles, never mirrored mutable state.
4. **Events, not polling.** Progress, analysis stages, and workspace changes flow through a
   single `Stream<EngineEvent>`.
5. **Panic firewall.** Every bridge entry point wraps `catch_unwind`; a Rust panic becomes a
   typed `EngineError::Internal`, never a crashed app.
6. **Everything cancellable that can exceed 100 ms.** Operations return an `OperationId`
   immediately; `cancel(op)` sets a cooperative token checked by streaming loops.

## 2. API surface (v1)

Signatures are indicative Dart (as frb will generate). `Engine` and `Session` are opaque.

### 2.1 Lifecycle

```dart
Future<Engine> engineInit(EngineConfig config);      // once per app run
Future<int>    engineApiVersion();                   // bridge contract version, start at 1
Stream<EngineEvent> engineEvents(Engine engine);     // subscribe before first operation
Future<void>   engineDispose(Engine engine);
```

`EngineConfig { storageRootPath, maxImportBytes, maxRowsSoftCap, locale, logLevel }` —
storage root is supplied by Dart (`path_provider`), keeping the core platform-independent.

### 2.2 Import & datasets

```dart
Future<OperationId> importFile(Engine e, ImportRequest req);
// ImportRequest { sourcePath, displayName, formatHint?, cancelToken }
// Progress + completion via EngineEvent.importProgress / importCompleted(datasetId, report)

Future<List<DatasetInfo>> listDatasets(Engine e);
Future<DatasetProfile>    datasetProfile(Engine e, String datasetId);
Future<void>              deleteDataset(Engine e, String datasetId); // ref-counted
```

`ImportReport { datasetId, format, encoding, rowsImported, rowsQuarantined, bytes,
durationMs, warnings[], fieldCount }`.

### 2.3 Workspaces & sessions

```dart
Future<Session>           createWorkspace(Engine e, String datasetId, WorkspaceIntent? intent);
Future<Session>           openWorkspace(Engine e, String workspaceId);
Future<List<WorkspaceInfo>> listWorkspaces(Engine e);
Future<void>              closeSession(Session s);          // flushes autosave
Future<void>              renameWorkspace(Session s, String title);
Future<String>            duplicateWorkspace(Engine e, String workspaceId);
Future<void>              deleteWorkspace(Engine e, String workspaceId);
```

### 2.4 Snapshots & commands (the mutation path)

```dart
Future<WorkspaceSnapshot> snapshot(Session s);              // full, revisioned
Future<ApplyResult>       applyCommands(Session s, List<Command> commands); // atomic batch
Future<ApplyResult>       undo(Session s);
Future<ApplyResult>       redo(Session s);
Future<void>              save(Session s);                  // explicit; autosave is engine policy
```

- `WorkspaceSnapshot { revision, doc: WorkspaceDoc, undoDepth, redoDepth, dirty }` —
  `WorkspaceDoc` is the validated [UI Schema](03-ui-schema.md) document, frb-mirrored.
- `Command` is a **sealed union** (frb enum classes): `SetGlobalFilter`, `SetComponentSort`,
  `SetComponentFilter`, `SetSearch`, `MoveComponent`, `ResizeComponent`,
  `ChangeComponentType`, `SetComponentBinding`, `OverrideFieldType`, `OverrideFieldRole`,
  `AddComponent`, `RemoveComponent`, `SetTitle`, `UndoMarker`. New commands = additive
  contract change; the union is versioned with the bridge API version.
- `ApplyResult { revision, affectedComponentIds, recompilation: None|Partial|Full, error? }`.
  A failed batch applies **nothing** (validate-all-then-apply).

#### 2.4.1 As shipped through M1.4 (task 1.4.7)

The aspirational union above lists commands planned for later milestones; the shipped
`morphic_core::Command` has five variants (`SetGlobalFilter`, `SetComponentFilter`,
`SetComponentSort`, `SetSearch`, **`ChangeComponentType`**). Adding that fifth variant was an
additive contract change, so `API_VERSION` went from 6 to **7** (§5). No FFI entry point changed
shape: the new command travels inside the existing `morphic_apply_commands` JSON array, and a
failed batch still applies nothing.

The shipped apply result is `{revision, affected, changed, doc, typeOptions}` — targeted
recompilation shipped later in 1.5.5 (§2.4.5), while undo/redo landed in 1.5.1 (§2.4.2).
`typeOptions` also appears
on `snapshot` and on the import outcome: a map from component id to the conversion targets the
engine can validate against the **live** dataset profile. This keeps the UI's "Change view"
menu engine-authoritative (docs/architecture/04 §4.1) instead of making Dart a second
compiler. It is bridge payload, not part of `WorkspaceDoc`, so schema v1.0 is unchanged.

#### 2.4.2 As shipped in M1.5.1 (task 1.5.1)

`undo(Session)` / `redo(Session)` now exist as real FFI entry points
(`morphic_undo` / `morphic_redo`), and `MoveComponent`, `OverrideFieldType` and
`OverrideFieldRole` joined the command union. All are additive, so `API_VERSION` went
**7 → 8** (§5). The apply/snapshot/import payloads gained `stateHash`, `undoDepth`,
`redoDepth`, `undoLabel`, `redoLabel`, and apply/undo/redo also return `label` for the app
bar's snackbar. `stateHash` deliberately excludes `revision` and `modifiedAt`, so undoing
and redoing a state hash-match the original without those bookkeeping fields getting in the
way (AT-13).

Rust owns the bounded stacks (cap 100), the journal's `inverseSummary` and the document
restore; Dart only renders the returned document and shows the label. A new command batch
truncates redo; a failed batch pushes nothing. `WorkspaceSnapshot.dirty` is still an
*aspirational* field, not part of the shipped JSON snapshot. The explicit `save()` checkpoint
landed in 1.5.4 (§2.4.6); its response carries `dirty: false` because the checkpoint has folded
the journal, while Dart tracks a separate internal pending-checkpoint flag. Targeted
recompilation shipped in 1.5.5 (§2.4.5). The field-override commands in this 1.5.1 row did not
yet trigger it — they persisted and were undoable, which is what AT-13's mixed run needed.

#### 2.4.3 As shipped in M1.5.2 (task 1.5.2)

`ResizeComponent { componentId, span?, height? }` is the additive v9 command behind manual
layout. Omitted fields leave the other dimension unchanged; `span` is one of `1..=3` columns
and `height` is `small | medium | large`. Rust writes exactly one record per component into
`layout.hints`, validates the whole result through pass 1, and treats a no-op as no change.
Flutter's long-press drag handle emits the existing `MoveComponent`; its pinch-free menu emits
`ResizeComponent`. Phone focus mode is a view convenience only and does **not** mutate the
document. `typeOptions` and the history fields keep their v8 shapes. `API_VERSION` went
**8 → 9** (§5); no entry point changed shape.

#### 2.4.4 As shipped in M1.5.3 (task 1.5.3)

The library lifecycle is now real rather than aspirational. Four additive FFI entry points
joined the bridge: `morphic_rename_workspace(root, id, title, now)` and
`morphic_duplicate_workspace(root, sourceId, newId, title, now)` return the new `WorkspaceDoc`;
`morphic_delete_workspace(root, id)` returns `{deleted:true}`;
`morphic_relink_workspace(bytes, len, root, id)` returns `{relinked:true}`. Rust owns the
document, library index and undo seed: rename is a persisted edit with a revision bump,
duplication copies the document under a fresh id and revision but **shares** the
content-addressed dataset, deletion never removes a dataset another workspace may reference,
and re-link refuses bytes whose SHA-256 does not equal the dataset id already in the document.
All four drop any open session so the next snapshot rehydrates from disk. `API_VERSION` went
**9 → 10** (§5); no existing entry point changed shape.

#### 2.4.5 As shipped in M1.5.5 (task 1.5.5)

`ClearFieldOverride { field }` joins the v11 command union, and the two existing override
commands now do more than persist. A correction changes the **planner's view** of the profile:
`morphic_compiler::recompile::effective_profile` applies the persisted `fieldOverrides` to the
inferred `DatasetProfile`, and `recompile_for_fields` calls the real `compile` once with that
effective profile. Only components whose binding reads a corrected field are considered; a
fresh binding and explanation are copied where the corrected profile still generates that
component, otherwise the binding is repaired in place (an average over a now-text field
becomes a row count). Layout order, hints, titles, converted types, interaction state and the
override records themselves are never rewritten. Components that read no corrected field are
byte-identical, and `affected` names only the recompiled plus directly touched components.

Overrides do **not** re-parse the imported bytes: the query layer keeps the dtype it ingested,
while the planner and `validate_bindings` use the corrected view. A batch whose result is not
computable against the effective profile is rejected before any write. In degraded mode there
is no live profile, so the correction is persisted but not recompiled; a healthy reopen sees it
in the document. Flutter's entry point is a long press on a `data_table` header: it opens a sheet
that reads the inferred and effective values from Rust, emits the three commands, and shows a
small badge on corrected columns. Undo and redo restore the whole authoritative document, so
the inference and every recompiled binding return together. `API_VERSION` went **10 → 11**
(§5); no entry point changed shape.

#### 2.4.6 As shipped in M1.5.4 (task 1.5.4)

`API_VERSION` went **11 → 12** (§5). Two additive FFI entry points join the bridge:
`morphic_recovery_report(root)` returns the `RecoveryReport` captured once at `Engine::new`, and
`morphic_save_workspace(root, id)` returns
`{revision, stateHash, dirty, compacted}`. No existing entry point changed shape.

Rust startup recovery now runs *before* any session is opened. It sweeps orphaned `*.tmp`
files, replays a newer journal revision left behind by a kill between journal append and
document rename, drops a torn trailing JSONL line without failing the journal, quarantines an
unreadable `workspace.json` as `workspace.corrupt.json`, migrates a pre-1.1.6 in-workspace source
while keeping `workspace.pre-v1.json.bak`, and rebuilds a torn `library.json` from the workspace
folders. `RecoveryReport` is
`{sweptTmp, tornJournalLines, restoredFromJournal, quarantined, migratedLegacySource,
rebuiltLibraryIndex}`; a clean startup is all zeroes/false. `Engine::save` rewrites the
authoritative document, refreshes the index and folds the journal. Its `dirty` field is always
`false`: Rust has already persisted every command synchronously, so the 2 s Dart timer is a
**checkpoint debounce**, not a window in which data could be lost.

Flutter owns `AutosaveCoordinator`: it asks for a checkpoint 2 s after the last changed batch,
flushes immediately on `AppLifecycleState.paused` / `hidden` / `detached`, and flushes before
`closeWorkspace`. The app reads `recoveryReport` once at startup and shows a dialog listing only
the lines the engine actually reported — no invented damage and no silent repair. The
aspirational `WorkspaceSnapshot.dirty` above remains absent from the wire payload.

#### 2.4.7 As shipped in M1.5.6 (task 1.5.6)

`API_VERSION` went **12 → 13** (§5). Two additive FFI entry points join the bridge:
`morphic_export_bundle(root, id, now)` returns `{bundleJson, bytes, manifest}`, and
`morphic_import_bundle(bytes, len, root, newId, title, now)` returns the imported workspace
document, its source title and the verified dataset count. The CI-green tip is `a8e42e4` / run
**43070316539** (6/6 ✅). No existing entry point changed shape.

The design sketch in doc 06 called for a ZIP. The shipped `.morphic` file is instead a single
UTF-8 JSON envelope — manifest, authoritative `WorkspaceDoc`, and hex-encoded source bytes —
because the repo has no ZIP dependency and adding one for three small files would widen the
supply-chain surface without user-visible gain. Rust verifies the manifest format, the
workspace/schema identity, every declared byte count and every SHA-256 content hash *before*
writing a dataset or a workspace. Import re-seeds the document at revision 1 under a fresh id
and rehydrates the session, so a broken bundle fails at the boundary rather than on the first
data read. Flutter picks a `.morphic` file through the same injectable file-source seam used by
re-link, and writes exports into the app-private documents directory through injectable path and
byte-sink seams. Errors, cancellations and engine rejections are surfaced, never swallowed.

#### 2.4.8 Live workspace rename (task 1.6.1)

`API_VERSION` **13 → 14** adds `RenameWorkspace { title }` to the existing command array; no
FFI function signature changes. The engine trims the title, rejects an empty title atomically,
updates the library index through the normal journaled save, and records a normal undo frame.
A no-op does not change revision or history; renaming does not mark component data affected.
This path preserves the open session and its previous undo/redo history. The older *library*
rename entry point still drops a session and re-seeds history and is not used by the live title UI.

### 2.5 Data plane

```dart
Future<TablePage>   queryPage(Session s, QueryRequest req);
Future<ChartSeries> chartData(Session s, String componentId);
Future<MetricValue> metricData(Session s, String componentId);
```

- `QueryRequest { componentId?, filter?, search?, sort?, offset, limit }` — limit ≤ 1024,
  default page 256 rows. The engine resolves the component's binding server-side; Dart
  cannot smuggle arbitrary plans outside the validated plan grammar.
- `TablePage { offset, totalRows, columns: List<ColumnChunk> }` where `ColumnChunk` is a
  tagged union: `Int64s(List<int>)`, `Float64s(List<double>)`, `Bools`, `Strings`,
  `Timestamps(List<int> msUtc)`, each with a `nullBitmap: Uint8List`. Typed lists cross
  FFI as bulk buffers — **one copy per column per page**, never per cell.
- `ChartSeries` / `MetricValue` are **pre-aggregated in Rust** (bucketed counts, top-N
  categories, time buckets). Charts never receive raw tables.

**Current MVP implementation:** the shipped `queryPage` and `componentPage` return JSON
row arrays, not the aspirational typed `ColumnChunk` buffers above. Each row includes *all*
source columns in the same order as `profile.fields`; the table binding names a potentially
reordered or narrower display projection. The Flutter table maps by field name, uses the
same mapping for accessible summaries, and includes the remaining source fields in row
detail. Missing/ambiguous metadata or a mismatched row is an error, not an invented null or a
positional guess. The renderer hides stale pages while a new selection is loading and discards
responses if their read context or source order has changed. This documents the existing page
shape; it does not add a bridge field or change API v14. Typed, projected buffers remain future
work.

### 2.6 Events

```dart
sealed class EngineEvent {
  ImportProgress   { operationId, stage, bytesRead, totalBytes?, rowsSoFar }
  ImportCompleted  { operationId, datasetId, report }
  AnalysisStage    { operationId, stage }   // inspecting|structure|relationships|planning|building|ready
  WorkspaceChanged { workspaceId, revision, affectedComponentIds }
  OperationFailed  { operationId, error }
  OperationCancelled { operationId }
}
```

## 3. Threading & concurrency model

- frb dispatches Rust work on its own worker pool; **the Dart UI isolate never blocks**.
- Each `Session` is internally **single-writer**: commands and queries for a session are
  serialized by the engine (a session mutex / actor). Different sessions run in parallel.
- Long operations (import, full compile) are chunked and check cancellation every N rows /
  every stage boundary. Cancellation is cooperative and leaves no partial dataset visible
  (staging area is discarded).
- Snapshots and pages are **immutable value objects**; Dart may cache them by
  `(workspaceId, revision)` / `(componentId, revision, planHash)` without invalidation races.
- Backpressure: at most one in-flight import per engine in MVP; UI disables concurrent
  imports rather than queueing silently.

## 4. Error model

One typed error enum across the whole bridge (frb maps to a Dart sealed class):

| Variant | Meaning | UI treatment |
|---|---|---|
| `Io { path, reason }` | unreadable/missing file | actionable import error |
| `UnsupportedFormat { detected }` | no parser matched | suggest supported formats |
| `Parse { line?, column?, reason, quarantined }` | malformed content | partial-import report or fail |
| `Validation { pointer, rule }` | schema/plan/binding violation | developer-facing detail, user-facing summary |
| `ResourceLimit { limit, actual }` | size/rows/columns/time budget hit | explain limit, offer sample mode |
| `NotFound { kind, id }` | stale handle/id | recover by re-listing |
| `Cancelled` | user/system cancellation | silent |
| `Internal { message }` | bug (panic firewall caught it) | crash-free error surface + log |

Errors MUST NOT embed raw user data rows (privacy in logs); they carry positions/counts only.

## 5. Versioning & compatibility

- `engineApiVersion()` gates Dart↔Rust compatibility at startup (mismatch → clear error).
- Bridge DTOs and the UI Schema version **independently** (`schemaVersion` inside the doc).
- Additive changes (new event/command variants) bump API version minor; Dart handles unknown
  events by ignoring them (forward tolerance). Breaking changes require a migration note ADR.
- **v7 (M1.4 task 1.4.7)** adds `ChangeComponentType` to the command union and the
  `typeOptions` map to snapshot/import/apply payloads. Older clients simply see an extra field
  and one more command name; no entry point was added, removed or reshaped.
- **v8 (M1.5 task 1.5.1)** adds `MoveComponent`, `OverrideFieldType`, `OverrideFieldRole`,
  two `undo`/`redo` entry points and history metadata on snapshot/import/apply. No existing
  entry point changed shape; older clients see extra response fields and two more exports.
- **v9 (M1.5 task 1.5.2)** adds `ResizeComponent` and the persisted `layout.hints` record.
  It travels through the existing `morphic_apply_commands` array; no entry point changed shape.
- **v10 (M1.5 task 1.5.3)** adds four library-lifecycle entry points (rename, duplicate,
  delete and hash-verified source re-link). No existing entry point changed shape; older
  clients simply see four more exports.
- **v11 (M1.5 task 1.5.5)** adds `ClearFieldOverride` and targeted recompilation of the
  bindings that read a corrected field. It travels through the existing
  `morphic_apply_commands` array; no entry point changed shape.
- **v12 (M1.5 task 1.5.4)** adds the startup recovery report and the explicit autosave
  checkpoint entry points (`morphic_recovery_report`, `morphic_save_workspace`). Both are
  additive; no existing entry point changed shape.
- **v13 (M1.5 task 1.5.6)** adds `.morphic` bundle export/import
  (`morphic_export_bundle`, `morphic_import_bundle`). Both are additive; no existing entry point
  changed shape.
- **v14 (M1.6 task 1.6.1)** adds undoable `RenameWorkspace` to the command union. It uses
  `morphic_apply_commands`; no existing entry point changed shape.
- The FFI boundary is a hand-written JSON surface over `morphic_*` exports, not generated frb
  code. CI compiles and tests both sides, checks generated schema artifacts for drift, and
  builds an APK whose stamp is compared with the commit SHA (see
  [CI/CD](../engineering/ci-cd.md)).

## 6. Performance rules of the boundary

1. Page size defaults: table 256 rows (max 1024); chart series ≤ 2,000 points (engine
   downsamples/buckets beyond that — LTTB or uniform bucketing, decided in M1.4).
2. No call may transfer an entire dataset. Ever. (`queryPage` hard-caps `limit`.)
3. Snapshot size is bounded by component cap (64) — kilobytes, not megabytes.
4. String columns are the expensive case; **target:** pages should carry only visible columns
   when the table binding specifies a projection. The current JSON page still carries all source
   columns (see §2.5), so this optimization is not yet shipped.
5. Budget (hypothesis): p95 round-trip for a 256-row page ≤ 16 ms on mid-range devices;
   measured in the perf harness, not assumed.
