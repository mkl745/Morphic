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

### 1.2 Encoding

BOM → strict UTF-8 validation → `chardetng` detection (confidence-gated) → lossy decode with
replacement chars **only** with an explicit warning + quarantine of undecodable rows.

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
