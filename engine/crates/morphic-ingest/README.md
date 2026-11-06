# morphic-ingest

Format detection and streaming parsers. **Boundary:** bytes in → `Table` + `ImportReport`
out. No semantics, no UI, no workspace I/O (see
[architecture/05](../../../docs/architecture/05-data-pipeline.md)).

## Status

| Format | State |
|---|---|
| CSV | **M1.1 production** — sniffing, encoding, tolerant typing, timestamps, quarantine, cancel/progress |
| JSON | **M1.2 1.2.1** — array/object/scalar shapes, depth-4 flattening, bounded-memory scan, gates, cancel/progress |
| JSONL | **M1.2 1.2.2** — one record per line, streaming, bad-line quarantine with line numbers |
| TXT | **M1.2 1.2.2** — `line_number` + verbatim `line`, blank lines preserved |
| LOG | **M1.2 1.2.2** — scored pattern library v1: iso-level, syslog, common-log, logfmt, fallback |

| Detection | **M1.2 1.2.3** — content-first sniffing across all five formats, `formatHint` override, extension as last resort |

All five formats are now reachable end to end: `ingest()` detects and dispatches,
`morphic-core::import()` takes a hint, the bridge exports `morphic_import`, and the import
screen offers a format override. The richer import UX (per-format previews, evidence panel)
is 1.2.4.

## API

```rust
// Detect the format from the content and parse it. This is what core and the bridge call.
let (table, report) = morphic_ingest::ingest(bytes)?;

// Force a format, or offer the extension as a last-resort tie-break.
let opts = morphic_ingest::IngestOptions {
    format_hint: Some(morphic_ingest::detect::Format::Jsonl),
    extension: Some("ndjson".into()),
    ..Default::default()
};
let (table, report) = morphic_ingest::ingest_with(bytes, &opts, None, &mut |p| {})?;

// Detection on its own, when you want the evidence before committing to a parse.
let d = morphic_ingest::detect::detect(bytes, None, Some("csv"));
// d.format, d.confidence (0.0–1.0), d.evidence, d.warnings

// CSV-only entry point, retained for callers that know the format.
let (table, report) = morphic_ingest::parse_csv(bytes)?;

// Full control: overrides, cancellation, real progress events.
let opts = morphic_ingest::IngestOptions { delimiter: Some(b';'), ..Default::default() };
let cancel = morphic_ingest::CancelToken::new();
let (table, report) = morphic_ingest::parse_csv_with(bytes, &opts, Some(&cancel), &mut |p| {
    // p.phase: Sniffing → Parsing → Typing → Done; p.rows_read / p.bytes_read
})?;

// Every M1.2 format has the same shape: same options, report, progress and cancel contract.
let (table, report) = morphic_ingest::json::parse_json(bytes)?;
let (table, report) = morphic_ingest::jsonl::parse_jsonl(bytes)?;
let (table, report) = morphic_ingest::text::parse_txt(bytes)?;
let (table, report) = morphic_ingest::log::parse_log(bytes)?;
let (table, report) =
    morphic_ingest::json::parse_json_with(bytes, &opts, Some(&cancel), &mut |p| {})?;
```

Until 1.2.3 lands there is **no auto-detection**: the caller picks the parser. `morphic-core`
and the bridge still call CSV only, so nothing a user can see has changed yet.

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

## M1.2 line formats (task 1.2.2)

`records.rs` holds the record-to-columns machinery shared by JSON and JSONL — flattening,
nulls, naming, typing, quarantine policy and warning text. Two copies of that policy is how
formats drift apart, so there is one, and a test asserts JSON and JSONL produce identical
columns for identical records.

### JSONL

- One JSON value per line; a line is parsed, folded into the builders and dropped, so peak
  parse memory is one line.
- **Blank lines are skipped** (they carry no record); a trailing newline is not a row.
- A bad line is quarantined without ending the parse, and the **first 20 line numbers** are
  reported so they can be found.
- Array-valued lines are quarantined; scalar lines become a `value` column.

### TXT

- `line_number` (1-based) + `line`, both still typed by the shared ladder — a file of one
  number per line arrives as `int64`, which is the ladder working, not a special case.
- **Blank lines are kept** as empty rows and reported, because dropping them would misalign
  every line number against the source file. Text is never trimmed; indentation is data.

### LOG — pattern library v1

The pattern is chosen **once** from up to 256 sampled lines and then applied to every line,
so a file cannot end up half-parsed one way and half another. The chosen pattern, its match
count and rate are always reported; below 70% a low-confidence warning is added.

| Pattern | Core columns |
|---|---|
| `iso-level` | `time`, `level`, `service`, `message` |
| `syslog` | `time`, `level`, `host`, `service`, `pid`, `message` |
| `common-log` | `time`, `host`, `ident`, `authuser`, `message`, `status`, `bytes`, `referer`, `user_agent` |
| `logfmt` | `time`, `level`, `service`, `message` (from aliases) |
| `fallback` | `time`, `level`, `message` |

- Core columns are always emitted, null when absent, so column order never depends on which
  line happened to carry a field first.
- `key=value` pairs are promoted to columns — from the whole line for logfmt, from the
  message tail otherwise — capped at **64 distinct keys**, and hitting the cap is reported.
  A tail key can never overwrite a field the structured prefix already extracted.
- Levels canonicalise to `TRACE/DEBUG/INFO/NOTICE/WARN/ERROR/FATAL` so grouping works.
  Syslog `PRI` is decoded to a severity. CLF `-` becomes null, not the string `"-"`.
- **Unmatched lines keep their entire raw text in `message`** and are counted. A log import
  never fails and never drops a line because it looked odd.

## Known debt (tracked, not hidden)

- **Log service detection is a heuristic.** `[svc]` is unambiguous; a bare token is only
  taken as a service when it starts lowercase, so `INFO Request received` keeps the whole
  phrase as the message but `INFO request received` reads `request` as a service. The
  ambiguity is reported on every iso-level import.
- **syslog and CLF timestamps stay text.** RFC3164 carries no year and CLF uses month names;
  the temporal ladder refuses both rather than guessing. A warning says so. Promoting them
  needs the locale/year inference work that M1.1 deliberately deferred.
- The log pattern library is **v1**: no multiline/stack-trace folding, no JSON-in-log
  detection, no Apache error-log or k8s/klog pattern. Unmatched lines survive as text, so
  these are gaps in extraction, not data loss.

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
