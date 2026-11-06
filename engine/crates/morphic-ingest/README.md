# morphic-ingest

Format detection and streaming parsers. **Boundary:** bytes in → `Table` + `ImportReport`
out. No semantics, no UI, no workspace I/O (see
[architecture/05](../../../docs/architecture/05-data-pipeline.md)).

## Status

| Format | State |
|---|---|
| CSV | **M1.1 production** — sniffing, encoding, tolerant typing, timestamps, quarantine, cancel/progress |
| JSON | **M1.2 1.2.1 implemented** — array/object/scalar shapes, depth-4 flattening, bounded-memory scan, gates, cancel/progress. Not yet reachable from the UI (auto-detection is 1.2.3). |
| JSONL | M1.2 1.2.2 |
| TXT / logs | M1.2 1.2.2 |

## API

```rust
// Stable convenience entry point (used by the bridge and core).
let (table, report) = morphic_ingest::parse_csv(bytes)?;

// Full control: overrides, cancellation, real progress events.
let opts = morphic_ingest::IngestOptions { delimiter: Some(b';'), ..Default::default() };
let cancel = morphic_ingest::CancelToken::new();
let (table, report) = morphic_ingest::parse_csv_with(bytes, &opts, Some(&cancel), &mut |p| {
    // p.phase: Sniffing → Parsing → Typing → Done; p.rows_read / p.bytes_read
})?;

// JSON (M1.2 1.2.1) — same report type, same options, same progress/cancel contract.
let (table, report) = morphic_ingest::json::parse_json(bytes)?;
let (table, report) =
    morphic_ingest::json::parse_json_with(bytes, &opts, Some(&cancel), &mut |p| {})?;
```

Until 1.2.3 lands there is **no auto-detection**: the caller picks `parse_csv` or
`json::parse_json`. `morphic-core` and the bridge still call CSV only, so 1.2.1 changes
nothing a user can see.

## M1.1 policy (all of it reported, none of it silent)

- **Delimiter**: sniffed from `, ; TAB |` by *consistency* of per-line counts outside quotes,
  not raw frequency (so prose commas don't win). Overridable; non-comma choice is reported.
- **Header**: sniffed from numeric/text structure. A mostly-numeric first row is data.
  Headerless files get `column_1..N`. Overridable; the decision is reported.
- **Encoding**: UTF-8/UTF-16 BOMs honoured; strict UTF-8 otherwise; **Latin-1 fallback** on
  invalid UTF-8 with a warning. Never lossy-by-replacement, never a panic.
- **Type ladder**: `bool → int64 → float64 → timestamp → utf8`, choosing the most specific
  type with `parse_ratio ≥ type_tolerance` (default **0.95**). Residual cells become **null**
  and the count is reported per column. `0/1` stay integers; `NaN`/`inf` are rejected; `Utf8`
  cells are preserved verbatim.
- **Timestamps** (`temporal.rs`, M1.1 1.1.2) normalize to **UTC milliseconds**:
  - ISO-8601 `YYYY-MM-DD` with optional `T`/space `HH:MM[:SS[.f…]]` and optional
    `Z` / `±HH:MM` / `±HHMM` / `±HH`; plus `YYYY/MM/DD`.
  - `DD/MM/YYYY` vs `MM/DD/YYYY` is resolved **only** when a row has a component > 12.
    Otherwise the column **stays text** and the ambiguity is reported — never guessed.
  - Values without an offset are **assumed UTC**, and that assumption is reported.
  - Tried *after* the numeric rungs, so `20240115` and epoch-looking integers stay `int64`
    (they are usually identifiers).
  - Calendar-validated (leap years, month lengths); leap seconds (`:60`) rejected because
    UTC millis cannot represent them; fractional seconds truncated to milliseconds.
  - No timezone database and no `chrono` dependency: the civil-date math lives in
    `morphic_model::temporal` and is round-trip tested across 1800–2200.
- **Nulls**: `"" , null, na, n/a, nil` (trimmed, case-insensitive), configurable.
- **Ragged rows**: padded/truncated to header width, counted and reported.
- **Quarantine**: unreadable records are counted, never fatal; 100 consecutive failures stop
  the read with a warning rather than spinning.
- **Bounds**: `max_rows` (2,000,000) and `max_columns` (2,048) return typed errors — a
  bounded-memory gate, never silent truncation.
- **Cancellation**: cooperative via `CancelToken`, checked before work and every 1024 rows.

## M1.2 JSON policy (task 1.2.1)

- **Shapes**: `[{…},…]` → one row per element; `{…}` → one row; `[1,2,3]` → a single `value`
  column (reported); a top-level scalar → one row. An element that is itself an array is
  **quarantined**, not guessed at.
- **Wrapper objects**: `{"data":[…],"meta":{…}}` is imported as **one row** and the report
  names the fields holding record arrays. Picking one automatically would be wrong often
  enough to be harmful; extracting a wrapper is 1.2.4's re-import-with-hint UX.
- **Bounded memory**: the document is *not* materialised as a `serde_json::Value` tree when
  the top level is an array. A depth/string/escape-aware scanner yields one element slice at
  a time, so peak parse memory is the largest element, not the file.
- **Flattening**: nested objects become dotted paths (`user.city`) to **depth 4**. Nothing is
  dropped — a deeper subtree, and any array value, is retained as **compact JSON text** with
  one warning per affected column. `{}` and `[]` are kept so the field's existence survives.
- **Nulls**: JSON `null` or an absent key **only**. The CSV null-token vocabulary is
  deliberately *not* applied, so `"null"`, `"N/A"` and `""` stay real string data. Absent keys
  are back-filled as null in both directions as the column union grows.
- **Typing**: scalars are rendered to text and passed through the *same* `build_column`
  ladder as CSV, so ISO-8601 strings from APIs become real timestamps and the two formats
  cannot drift apart on types.
- **Quarantine policy** (architecture/05 §1.3): a malformed element does not discard the rows
  already read; more than `max(1% of rows, 1000)` unreadable elements fails the import with
  diagnostics instead of importing nonsense.
- **Tolerance**: a trailing comma is accepted **and reported**; content after the closing `]`
  is ignored **and reported**. A leading/doubled comma or an unclosed array is a typed error.
- **Bounds**: `max_import_bytes` (**256 MiB**) is checked before any work;
  `max_memory_bytes` (**512 MiB**) is checked per row against retained cell bytes. Both return
  `IngestError::ResourceLimit` with an actionable message. `max_rows` / `max_columns` apply to
  the **union** of keys, not to one record.
- **Cancellation / progress**: identical contract to CSV — `Sniffing → Parsing → Typing →
  Done`, cancellation checked before work and every 4096 elements.

## Known debt (tracked, not hidden)

- **JSON column order within a record is sorted, not file order.** `serde_json`'s default
  `Map` is a `BTreeMap`, so `{"date":…,"open":…,"close":…}` yields `close, date, open`. It is
  deterministic and pinned by a test, but it is not what the file said. Preserving source
  order needs a local order-tracking deserializer (1.2.4): enabling
  `serde_json/preserve_order` workspace-wide would reorder every serialized document and
  break the schema and compiler goldens.
- **CSV does not yet enforce the `max(1%, 1000)` quarantine ceiling** that JSON now enforces;
  it only warns. Aligning them is 1.2.3 work, recorded here rather than left as a silent
  behavioural difference between formats.
- JSON array elements that are themselves arrays are quarantined rather than flattened into
  positional columns. No corpus evidence yet says that is the right call; revisit in 1.2.4.

- Statistical charset detection (`chardetng`) is **M1.2**; Latin-1 can mis-render
  windows-1252 punctuation in `0x80..0x9F`.
- Named zones (`Europe/Berlin`), DST-aware local times, and locale month names (`03-Mar-24`)
  are **not** supported; only numeric layouts with explicit offsets. Such columns stay text.
- Systematic quantile sampling in `morphic-semantic` can alias against periodic data;
  reservoir sampling is a candidate improvement (recorded, not hidden).
- Ingestion is currently **whole-file in memory** (decode → `String`). True streaming with a
  memory ceiling proportional to columns, not file size, lands with 1.1.2's column builders.
  The row/column caps above are the interim guard.

## Tests

`cargo test -p morphic-ingest` — unit tests per module plus fixture-corpus tests driven by
[`fixtures/manifest.json`](../../../fixtures/manifest.json).
`cargo bench -p morphic-ingest` — parse throughput baseline (CI uploads the criterion JSON).
