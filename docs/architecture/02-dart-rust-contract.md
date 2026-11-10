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
`SetComponentSort`, `SetSearch`, **`ChangeComponentType`**). Adding the sixth was an additive
contract change, so `API_VERSION` went from 6 to **7** (§5). No FFI entry point changed shape:
the new command travels inside the existing `morphic_apply_commands` JSON array, and a failed
batch still applies nothing.

The shipped apply result is `{revision, affected, changed, doc, typeOptions}` — the
`recompilation`/`error?` fields and undo/redo arrive with M1.5. `typeOptions` also appears on
`snapshot` and on the import outcome: a map from component id to the conversion targets the
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
truncates redo; a failed batch pushes nothing. `WorkspaceSnapshot.dirty`, explicit `save()`
and `recompilation` remain deferred to 1.5.4 / 1.5.5, and the field-override commands do not
yet trigger targeted recompilation — they persist and are undoable, which is what AT-13's
mixed run needs.

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
- Generated frb code is **committed**; CI regenerates and diffs to catch drift
  (see [CI/CD](../engineering/ci-cd.md)).

## 6. Performance rules of the boundary

1. Page size defaults: table 256 rows (max 1024); chart series ≤ 2,000 points (engine
   downsamples/buckets beyond that — LTTB or uniform bucketing, decided in M1.4).
2. No call may transfer an entire dataset. Ever. (`queryPage` hard-caps `limit`.)
3. Snapshot size is bounded by component cap (64) — kilobytes, not megabytes.
4. String columns are the expensive case; pages carry only visible columns when the table
   binding specifies a projection.
5. Budget (hypothesis): p95 round-trip for a 256-row page ≤ 16 ms on mid-range devices;
   measured in the perf harness, not assumed.
