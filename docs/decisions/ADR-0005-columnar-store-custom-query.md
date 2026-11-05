# ADR-0005 — Custom columnar store + query engine; Arrow/DuckDB deferred

## Context
Spec §5.3 says *evaluate* DuckDB and Arrow. MVP queries are single-table filter / sort /
group / aggregate / search with paging over ≤ ~2 M rows. Options: embed DuckDB, adopt
arrow-rs arrays, or build a small typed columnar store.

## Decision
**Build `morphic-query` + `morphic-model`**: typed column buffers (Int64/Float64/Bool/Utf8/
Timestamp + validity bitmaps), selection-vector execution, index-permutation sorts, hash
grouping, LRU result cache, time budgets. The layout is deliberately **Arrow-shaped**
(columnar, typed, bitmap nulls) so adopting `arrow-rs` later is a buffer-level refactor,
not a model rewrite. DuckDB/Arrow adoption is revisited in Phase 2/4 when joins, Parquet,
and larger-than-memory workloads arrive.

## Alternatives
- **DuckDB (duckdb-rs)** — powerful, but: large native build for 3 Android ABIs (app size,
  build time, 16 KB alignment surface), its own memory manager fighting our budgets, and a
  SQL surface we'd have to sandbox anyway (our plans are already a closed grammar). Its
  value (joins, out-of-core, Parquet) is exactly what MVP doesn't need. Revisit trigger:
  multi-source joins or >2 M-row out-of-core analytics become requirements.
- **arrow-rs now** — excellent crates, but adds API surface and compile weight before we
  need interchange; our five types + bitmaps are ~500 lines with total control over FFI
  mapping. Revisit trigger: Parquet/Arrow IPC import (P4) or zero-copy sharing needs.
- **Row-oriented Vec<Record>** — rejected: cache-hostile for aggregations, wasteful nulls.

## Consequences
- Small, auditable, benchmarkable engine; every operator unit-tested; no external native
  dependency in the data path (app-size and supply-chain win).
- We own correctness of stats/sorts — mitigated by property tests + fixture scoring.
- Honest cost: we must *not* let this grow into a general SQL engine. The plan grammar is
  closed; anything beyond it is a phase decision, not a drive-by feature.
- Migration path documented: Column buffers ↔ Arrow arrays is mechanical; the query plan
  grammar maps to DuckDB SQL or Arrow compute kernels when the time comes.
