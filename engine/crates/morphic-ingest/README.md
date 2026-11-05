# morphic-ingest

Format detection and streaming parsers. **Boundary:** bytes in → `Table` + `ImportReport`
out. No semantics, no UI, no workspace I/O (see
[architecture/05](../../../docs/architecture/05-data-pipeline.md)).

## Status

| Format | State |
|---|---|
| CSV | **M1.1 production** — sniffing, encoding, tolerant typing, quarantine, cancel/progress |
| JSON / JSONL | M1.2 |
| TXT / logs | M1.2 |

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
```

## M1.1 policy (all of it reported, none of it silent)

- **Delimiter**: sniffed from `, ; TAB |` by *consistency* of per-line counts outside quotes,
  not raw frequency (so prose commas don't win). Overridable; non-comma choice is reported.
- **Header**: sniffed from numeric/text structure. A mostly-numeric first row is data.
  Headerless files get `column_1..N`. Overridable; the decision is reported.
- **Encoding**: UTF-8/UTF-16 BOMs honoured; strict UTF-8 otherwise; **Latin-1 fallback** on
  invalid UTF-8 with a warning. Never lossy-by-replacement, never a panic.
- **Type ladder**: `bool → int64 → float64 → utf8`, choosing the most specific type with
  `parse_ratio ≥ type_tolerance` (default **0.95**). Residual cells become **null** and the
  count is reported per column. `0/1` stay integers; `NaN`/`inf` are rejected; `Utf8` cells
  are preserved verbatim.
- **Nulls**: `"" , null, na, n/a, nil` (trimmed, case-insensitive), configurable.
- **Ragged rows**: padded/truncated to header width, counted and reported.
- **Quarantine**: unreadable records are counted, never fatal; 100 consecutive failures stop
  the read with a warning rather than spinning.
- **Bounds**: `max_rows` (2,000,000) and `max_columns` (2,048) return typed errors — a
  bounded-memory gate, never silent truncation.
- **Cancellation**: cooperative via `CancelToken`, checked before work and every 1024 rows.

## Known debt (tracked, not hidden)

- Statistical charset detection (`chardetng`) is **M1.2**; Latin-1 can mis-render
  windows-1252 punctuation in `0x80..0x9F`.
- Timestamp normalization to UTC millis (`DataType::Timestamp`) is **M1.1 task 1.1.2**;
  temporal fields are currently a *role* over `Utf8` detected in `morphic-semantic`.
- Ingestion is currently **whole-file in memory** (decode → `String`). True streaming with a
  memory ceiling proportional to columns, not file size, lands with 1.1.2's column builders.
  The row/column caps above are the interim guard.

## Tests

`cargo test -p morphic-ingest` — unit tests per module plus fixture-corpus tests driven by
[`fixtures/manifest.json`](../../../fixtures/manifest.json).
`cargo bench -p morphic-ingest` — parse throughput baseline (CI uploads the criterion JSON).
