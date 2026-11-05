# Quality & Performance Infrastructure

Implements spec §15–16. Budgets below are **hypotheses to validate on devices**, never
marketing claims (spec §16). Reference device classes: **low** (4 GB RAM, A-series class),
**mid** (Pixel 6a/7a class — primary reference), **flagship** (current Snapdragon 8-series).

## 1. Test pyramid & ownership

| Layer | Where | What | Gate |
|---|---|---|---|
| Rust unit | each crate `src` + `tests/` | parsers, inference, query ops, validation passes, migrations, journal/recovery | every PR |
| Rust property | `proptest` in ingest/query/schema | round-trips (parse→serialize→parse), filter algebra identities, sort stability, migration totality | every PR |
| Rust snapshot | `insta` in compiler/schema | expected WorkspaceDocs per fixture; schema error messages | every PR |
| Fixture scoring | `fixtures/expected/` | profile accuracy + visualization-selection accuracy vs hand-labeled corpus | every PR |
| Dart unit | `test/` | controllers (mocked bridge), adapters, registry contract vs manifest | every PR |
| Dart widget/golden | `test/` | every component × theme × (normal/empty/error); key screens; responsive breakpoints | every PR |
| Integration (host) | `integration_test` on host lib | import→workspace→save→reopen with real engine (no mocks) | every PR |
| Integration (device) | emulator API 36 + 24 | full flows incl. SAF picker, lifecycle kill/restore, airplane mode | nightly |
| Fuzz | cargo-fuzz targets: csv/json/log sniffers | malformed input never panics/OOMs | nightly smoke |
| Reliability | scripted chaos | kill mid-import/mid-save; corrupt snapshot/journal/workspace; permission revocation | nightly + pre-release |

## 2. Fixture corpus (built in Phase 0, grown every milestone)

`fixtures/` with `manifest.json` (origin, license, expected outcomes):

- **valid/**: clean CSV (types mix), wide CSV (60 cols), long CSV (100k rows, generated),
  JSON array-of-objects, nested JSON, JSONL logs, syslog, logfmt, ISO-prefixed app logs,
  numeric-only CSV, single-column TXT, unicode/encoding cases, CRLF cases.
- **malformed/**: truncated JSON, ragged CSV, mixed encodings, 10k-column CSV, null bytes,
  zip-bomb-ish repetition (bounded), empty file, header-only.
- **expected/**: hand-labeled profiles + expected component selections per fixture —
  this is how "schema detection accuracy" and "visualization selection accuracy" become
  *numbers* instead of vibes.

## 3. Performance harness

**Rust (criterion, `benches/`):** parse throughput (MB/s) per format; profile latency;
filter/sort/aggregate latency at 10k/100k/1M rows; snapshot write/read; compile latency.
Run on CI host for trends + on-device via a debug-only bench screen before releases.

**Dart (integration_test perf mode):** scripted workloads (import 10 MB CSV → workspace;
scroll 100k-row table; scrub chart; apply 10 filters; save/reopen) collecting:
`Stopwatch` phase timings + `SchedulerBinding` frame build/raster times + memory
(`ProcessInfo.currentRss` via platform hook). Emits JSON; nightly job stores trends and
flags >15% regressions.

**Device matrix runs:** before each milestone exit, run the harness on low/mid/flagship
physical devices (or closest available emulators, labeled as such). Results appended to
`docs/engineering/perf-log.md` with device, build, date.

## 4. Budgets (hypotheses — mid-range reference unless noted)

| Metric | Budget | Validation |
|---|---|---|
| Import → usable workspace, 10 MB CSV (~100k×10) | ≤ 3 s (low-end ≤ 6 s) | harness M1.1+ |
| Reopen saved workspace (snapshot hit) | ≤ 500 ms | harness M1.5 |
| Filter+sort 100k×10 (engine) | ≤ 150 ms | criterion + device |
| Table page round-trip (256 rows) | p95 ≤ 16 ms | harness |
| Table scroll frame time | p95 ≤ 16.6 ms | frame timings |
| Chart interaction frame time | p95 ≤ 33 ms | frame timings |
| Cold start → interactive home | ≤ 1.5 s | harness |
| Memory delta, 100k×10 loaded | ≤ 150 MB | RSS hook |
| Release download size (per-ABI split) | ≤ 40 MB | bundle analysis |
| Crash-free sessions (internal dogfood) | ≥ 99.5% | opt-in local counters first |

Budgets are revised only with recorded evidence in `perf-log.md` (never silently loosened).

## 5. UX validation (spec §15)

Milestone-exit script: 5 tasks (import unfamiliar file, find a specific record, correct a
wrong field type, rearrange layout, save+reopen) run with 3–5 people outside the build;
success/time-to-completion recorded in `docs/engineering/ux-log.md`. The MVP acceptance
tests ([spec](../roadmap/mvp-acceptance-tests.md)) are the floor; UX studies are the truth.

## 6. Accessibility gates

Every component: semantic summary, ≥48 dp targets, contrast ≥ 4.5:1 (token-enforced),
text-scale 1.0–1.3 without clipping (golden at 1.3), focus traversal order tested, and
screen-reader pass on the vertical slice before M1.7 exit.
