# 05 — Data Pipeline: Ingestion → Semantics → Query

Status: **Design frozen for Phase 0** · Implements spec §5.1–5.3 ·
Related: [ADR-0005](../decisions/ADR-0005-columnar-store-custom-query.md)

## 1. Ingestion (`morphic-ingest`)

### 1.1 Format detection (sniffing, never trust the extension alone)

Order of evidence: BOM/encoding → content probes on first 64 KB → extension hint → fallback.

| Probe | Result |
|---|---|
| First non-ws char `{` or `[` and parses as JSON prefix | JSON (object / array-of-objects / single object) |
| ≥ 90% of sampled lines parse as JSON objects | JSONL (treated as records) |
| Delimiter consistency test (`, ; \t |`) across ≥ 20 lines, stable field count | CSV/TSV with detected delimiter + header heuristic |
| ≥ 70% of lines match a known log pattern | LOG (typed line parser) |
| otherwise | TXT (single `line` column + line number; still profiled) |

Ambiguity (e.g. CSV vs single-column TXT) resolves to the richer interpretation and is
reported in `ImportReport.warnings` with the evidence — user can re-import with `formatHint`.

**Implemented in M1.2 task 1.2.3** (`morphic-ingest::detect`). Two thresholds per probe, not
one, because *choosing* a format and being *confident* about it are different questions:

| Probe | Plausible (choose it) | Confident (no warning) |
|---|---|---|
| Delimiter agreement | ≥ 50% (`sniff::DELIMITER_PLAUSIBLE`) | ≥ 90% (`sniff::DELIMITER_AGREEMENT`) |
| Log-pattern match | ≥ 50% (`detect::LOG_PLAUSIBLE_RATE`) | ≥ 70% (`log::CONFIDENT_MATCH_RATE`) |

The lower bar is what makes "richer interpretation" real. A ragged CSV with field counts
3,2,4,3 agrees on only 50% of lines, but every line has a comma and the CSV parser is built to
recover it; demoting it to TXT would discard all of its structure. Likewise a mixed log where
60% of lines match still gains timestamp/level extraction, and the log parser keeps every
unmatched line verbatim. Below the confident bar the agreement fraction becomes the reported
confidence and a warning explains the raggedness.

Other binding details:

- **A single column is not a delimiter.** The modal count must be ≥ 1 (i.e. ≥ 2 fields), so a
  plain list of words stays TXT.
- **Modal, not minimum.** One short row must not veto an otherwise obvious delimiter; the
  agreement fraction carries the raggedness instead.
- **CSV vs LOG on the same file** (a comma-separated log export): the higher score wins and
  the runner-up is disclosed with a re-import suggestion.
- **The extension is the weakest evidence.** It decides only when no content probe was
  decisive (including an empty file), and that decision is always disclosed. When it
  disagrees with the contents, the contents win and the disagreement is reported.
- **`formatHint` short-circuits everything** at confidence 1.0. An unrecognised hint is a
  typed error (`CoreError::UnknownFormat`), never a silent fall back to sniffing.
- **The first warning is always the headline** — `Read as '<format>' (<n>% confidence):
  <evidence>.` — so the UI has one stable line to show regardless of how many caveats follow.
- Probing is bounded: ≤ 64 KB decoded, ≤ 256 lines sampled, window cut at the last newline so
  no probe sees half a record. Detection cost does not grow with file size.

### 1.2 Encoding

BOM → strict UTF-8 validation → `chardetng` detection (confidence-gated) → lossy decode with
replacement chars **only** with an explicit warning + quarantine of undecodable rows.

**Status after 1.2.3.** BOM handling (UTF-8, UTF-16LE/BE) and strict UTF-8 validation are
implemented, as are the edge cases that silently corrupt real files:

- **Invalid / mixed UTF-8** falls back to Latin-1 (a total byte→char mapping, so no byte is
  ever lost) and reports **how many** byte sequences failed and **where the first one is**.
- **Mixed CRLF + bare LF** is handled and reported.
- **Lone CR** is reported explicitly: neither `str::lines` nor the `csv` crate splits on it,
  so a CR-only file would otherwise import as one enormous row.
- **Probable UTF-16/32 without a BOM** (≥ 25% NUL bytes) is flagged rather than guessed at;
  choosing an endianness on the user's behalf would be worse than saying so.

**`chardetng` is still deferred**, and the reason is now concrete rather than aspirational:
it is not in `Cargo.lock`, and this build environment cannot reach crates.io to compute the
checksums a locked dependency requires. Latin-1 remains the smaller, architecturally
compatible substitute. The gap it leaves is narrow and stated in the warning: windows-1252
punctuation in 0x80–0x9F renders as control characters.

### 1.3 Streaming & memory discipline (spec §5.1, §18)

- CSV: `csv` crate reader, row-by-row into column builders; never `read_to_string`.
- JSON: MVP parses arrays with a bounded-memory reader; hard gate at `maxImportBytes`
  (default 256 MB, configurable) with a clear `ResourceLimit` error suggesting sampling.
  JSONL/log/TXT are fully streaming.
- Column builders grow typed `Vec`s + validity bitmaps; a **memory estimate guard** aborts
  with `ResourceLimit` before OOM (soft cap rows: 2 M default; estimate = Σ column widths).
- Cancellation token checked every 8,192 rows; progress events every 250 ms or 1 MB.
- **Partial import policy:** malformed rows are quarantined (count + first 20 line numbers
  in report). If quarantined > max(1% of rows, 1000 rows) → fail with diagnostics instead of
  silently importing garbage.
- Import staging: parse into a staging table; only on success is the dataset committed to
  the store (content-addressed). Cancelled/failed imports leave nothing behind.

### 1.4 Log line parsing (curated pattern library, v1)

Patterns (regex, ordered): ISO-8601-prefixed levels (`2026-11-05T14:01:02Z ERROR [svc] msg`),
syslog RFC3164-ish, common log format (CLF/combined), `logfmt` (`key=value` pairs), and a
generic `timestamp? level? message` fallback. Extracted fields: `time`, `level`, `service`/
`component` (when present), `message`, plus logfmt keys as columns (capped at 64 keys).
Unmatched lines keep raw text in `message` — no data is dropped.

## 2. Columnar model (`morphic-model`)

```rust
enum DataType { Null, Bool, Int64, Float64, Utf8, Timestamp }  // ms since epoch, UTC
struct Column { dtype: DataType, values: TypedBuffer, validity: Bitmap }
struct Table  { fields: Vec<FieldSchema>, columns: Vec<Column>, row_count: usize }
```

- One buffer per column; nulls are bitmap bits, not sentinel values.
- `Timestamp` normalizes to UTC ms at parse time; original text is not retained (source file
  is, in the dataset store).
- This is intentionally **Arrow-shaped but not Arrow** — see ADR-0005 for why we defer
  Arrow/DuckDB and how the migration path stays open.

## 3. Semantic profiling (`morphic-semantic`)

Two strictly separated layers (spec §5.2):

### 3.1 Facts (measured, confidence = 1.0)

Per field: null count/%, distinct count (exact ≤ 10k, then `10000+`), min/max, numeric
mean/stddev/quantiles (sampled sort for p50/p90/p99), top-K values (K=20) with counts,
string length stats, temporal range + modal granularity, parse-success rate per type probe.

### 3.2 Inferences (interpretations, confidence < 1.0, with provenance)

| Role hint | Rule sketch | Example provenance |
|---|---|---|
| `temporal` | timestamp parse ≥ 95% | "98.7% of 'time' parses as ISO-8601" |
| `measure` | numeric, not id-like | "int64, range 0–4,210, 312 distinct" |
| `dimension` | categorical, distinct ≤ min(50, 5% rows) | "'service' has 7 distinct values" |
| `severity` | values ⊆ level vocabulary (ERROR/WARN/INFO/…) | "'level' top values match severity vocabulary" |
| `identifier` | distinct ≈ rows, high cardinality strings/ints | "'request_id' 99.9% unique" |
| `text` | long strings, high cardinality | "'message' avg length 142" |

- Type inference ladder per column: bool → int64 → float64 → timestamp → utf8, threshold
  ≥ 95% parse success (remaining cells → null + anomaly note). Mixed int/float → float64.
- Every inference carries `{ confidence, evidence[] }`; the compiler surfaces them in
  explanations; the user can override (`OverrideFieldType` / `OverrideFieldRole`) which
  triggers targeted recompilation.
- **No relationship invention in MVP.** Cross-field correlation candidates are Phase 2;
  v1 may report *observed* co-occurrence facts only, clearly labeled as statistics.

## 4. Query engine (`morphic-query`)

### 4.1 Plan grammar (validated, deterministic — never AI-executed)

```
Plan { source: datasetId, filter?: FilterExpr, search?: {fields?, text},
       sort?: [{field, dir, nulls}], group_by?: [field], aggs?: [AggSpec],
       projection?: [field], page: {offset, limit} }
```

### 4.2 Execution strategy (v1, single-table)

1. Filter → selection vector (indices) evaluated column-wise; short-circuit `and/or`.
2. Search → case-insensitive substring over projected string columns (bounded by plan).
3. Sort → index permutation (`f64::total_cmp` for floats; stable sort; nulls-last default).
4. Group/aggregate → hash grouping over selection; streaming accumulators.
5. Page → materialize only the requested window into `ColumnChunk`s.

Joins, window functions, and incremental view maintenance are explicitly out of MVP.

### 4.3 Guards & caching

- Time budget checked every 64k rows (default 2 s/query → `ResourceLimit`), result caps.
- LRU result cache keyed by `(datasetRevision, planHash)`; invalidated on data/override
  change; chart aggregations cached per component binding revision.
- Budget (hypothesis): filter+sort over 100k×10 ≤ 150 ms on mid-range ARM; verified by
  criterion benches + on-device harness.

## 5. Compiler planning rules v1 (`morphic-compiler`, deterministic)

Intent `explore` (default) composes from profile facts, in priority order:

1. Severity field present → `metric_card`(errors) + `metric_card`(total) + `timeline`.
2. Temporal field present → `line_chart` (count over auto-bucket; split by severity if present).
3. Categorical dimension + measure/count → `bar_chart` (top-12 by count).
4. Always → `data_table` (projected to ≤ 8 most informative columns, full data via scroll).
5. Numeric-only datasets → summary metrics + line/scatter-ready table (scatter is P2; v1
   uses line over row order with an explanatory note).
6. Cap at 6 components for phone-first workspaces; each carries its explanation object.

Rules are data (a table of condition → component templates), unit-tested against the fixture
corpus, and scored for selection accuracy (see [quality doc](../engineering/quality-and-performance.md)).
This rule table is exactly what the Phase 2 AI provider will learn to beat — with the same
validation gate.

### 5.1 As implemented in M1.4 — deviations from the v1 intent above

The rules above are the *intent*; `RULE_TABLE` in `morphic-compiler/src/lib.rs` is the contract
that actually ships. Three deliberate differences, recorded rather than quietly absorbed
(`docs/roadmap/m1.4-status.md` §11 has the measurements):

1. **Rule 1 does not force a timeline.** A severity field earns a restricted error metric
   (`R2b`). When the file also has a bucketable time axis *and* a measure, R3 emits a
   **severity-split line chart** instead of a timeline; when it has a true Timestamp axis but
   no measure, R4 emits a timeline. R3 and R4 are exclusive — one axis, one view. The
   severity split is what makes the line chart's legend reachable from a generated document.
2. **Rule 2 buckets a measure, not a count of events.** R3's y binding is `avg <measure>`
   over the time axis; a count-over-time line is available through the binding but is not the
   default. Time axes must be `Timestamp` or a numeric `Temporal` — a `Utf8` column with a
   Temporal *role* is refused rather than handed to a query layer that cannot bucket text.
3. **Rule 5's row-order line is deferred.** Numeric-only files get the summary metrics and
   the projected table; the "line over row order with an explanatory note" was never built,
   and v1 does not emit an ordinal x-axis. Scatter remains P2. This is a real gap, not a
   rephrasing of a shipped feature.

R5 also outlived its "top-12 by count" wording: selection keeps dimensions up to 50 distinct
values, the *renderer* shows 12 bars and folds the remainder into `Other`. R6's cap is 6,
the table is never dropped from it, and `layout.hints` stays empty until M1.5 — nothing in
the Flutter runtime reads it yet.
