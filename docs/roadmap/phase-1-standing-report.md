# Phase 1 standing report — 2026-11-06, updated 2026-11-10

Written after task **1.2.5** went CI-green (run **42256267974**, commit **`fccec5c`**, all six
jobs success). Every number below was read from the plan, the source tree, or a CI report —
not from memory.

**Update 2026-11-08:** **M1.4 task 1.4.1** (scene contracts + `chartData` aggregation) is done and
CI-green; see [m1.4-status.md](m1.4-status.md).

**Update:** **M1.4 task 1.4.7** (`ChangeComponentType`) is done and CI-green. All seven M1.4
task rows are now implemented; the milestone exit is still unmet. See
[m1.4-status.md](m1.4-status.md) §13.

**Update 2026-11-10:** **M1.5 tasks 1.5.1 and 1.5.2** are done and CI-green. Undo/redo with
bounded journal history, manual layout editing with persisted hints and phone focus mode have
shipped; M1.5 is in progress, not exited. See [m1.5-status.md](m1.5-status.md).

**Update 2026-11-07:** **M1.3 is code-complete** — all five tasks (plan execution, interaction
commands, the interactive table, global filters with tap-to-filter, and cross-component
consistency) are done and CI-green. Tallies below reflect them; `docs/roadmap/m1.3-status.md`
records the decisions, the measured evidence, and why the milestone's **exit is still unmet**.

---

## 1. The short answer

| Question | Answer |
|---|---|
| Tasks finished | **26 of 41** (63%) |
| Tasks not finished | **15** — 13 core + 2 stretch (◇) |
| Milestones code-complete | **4 of 7** (M1.1, M1.2, M1.3, M1.4) |
| Milestones not started | **2** (M1.6, M1.7); M1.5 has 2 of 5 core rows shipped |
| Milestone exits formally met | **0 of 7** |
| Acceptance tests fully green | **7 of 19** (AT-02, AT-03, AT-05, AT-06, AT-08, AT-10, AT-12) |
| Acceptance tests partially evidenced | **10** |
| Acceptance tests not yet started | **2** (AT-17, AT-18) |
| Evidence gaps no task row covers | **6** (see §6) |
| Remaining core effort, by the plan's own S/M/L legend | **17–31 focused days** |

**The most important finding is the last row.** The plan estimates *all of Phase 1* at 30–40
focused days. With M1.3, all seven M1.4 tasks and the first two M1.5 rows finished, the **13
unfinished core tasks sum to 17–31 days** under the plan's own legend (S ≈ ½ day, M ≈ 1–2,
L ≈ 3–5), excluding the two ◇ stretch items:

| Remaining milestone | Core tasks | Focused days |
|---|---|---|
| M1.4 Visualization + planner | 0 | 0 |
| M1.5 Lifecycle & layout | 3 | 3–6 |
| M1.6 Experience pass | 5 | 8–14 |
| M1.7 Hardening & release | 5 | 6–11 |
| **Total** | **13** | **17–31** |

The figure is recomputed from the plan's rows on every update rather than decremented by hand.
The estimate was optimistic before any work started and 26 finished tasks have not made it less
so. §7 proposes a re-baseline.

---

## 2. Milestone by milestone

| Milestone | Tasks | Done | Code status | Exit status |
|---|---|---|---|---|
| M1.1 Vertical slice | 7 | 7 | **complete** | **unmet** — needs a mid-class device; AT-02 unscored; 10 MB ≤ 3 s unmeasured |
| M1.2 Format breadth | 5 | 5 | **complete** | **unmet** — AT-04's timeline clause depends on M1.4; device evidence pending (fuzz smoke now clean) |
| M1.3 Interactivity | 5 | 5 | **complete** | **unmet** — AT-06 ✓ AT-08 ✓; AT-07 blocked only on mid-class ARM latency |
| M1.4 Visualization + planner | 7 | 7 | **code-complete** — all five painters, planner v1, the explanation sheet and `ChangeComponentType` shipped | **unmet** — AT-11 not green; all-five golden coverage false; chart p95 ≤33 ms not device-measured |
| M1.5 Lifecycle & layout | 6 | 2 | **in progress** — undo/redo (1.5.1) and manual layout (1.5.2) shipped | **unmet** — AT-13/14 device halves, AT-15…AT-17, chaos suite, reopen ≤ 500 ms |
| M1.6 Experience pass | 6 | 0 | not started | — |
| M1.7 Hardening & release | 5 | 0 | not started | — |

Phase 0 (architecture, contracts, CI, release pipeline) is complete and was verified by run
42066050532.

**"Code-complete" is not "done".** All four code-complete milestones have working, tested code
and none has met its exit criteria, because those exits demand evidence this sandbox cannot
produce: a physical mid-range phone, an overnight fuzz run, all-five golden coverage and a
device-measured interaction budget. M1.5 has two shipped rows but is not code-complete yet; its
automated AT-13/AT-14 halves are green, while the device halves are still owed. That distinction
is the difference between a demo and a milestone.

---

## 3. What actually works today

Exercised on a real device (realme C51, Android, airplane mode) and on the CI emulator:

- **Import five formats** — CSV, JSON, JSONL, TXT, logs — from the file picker **or the
  clipboard**, with automatic format detection that reports its confidence and its evidence,
  and an explicit override when the guess is wrong.
- **Nested JSON flattens** to `a.b` columns; **logs extract** time / level / service / message
  with five patterns and keep every unmatched line.
- **Malformed input is survivable**: ragged rows and bad values are quarantined with an
  accurate report; oversized or absurd input fails with a typed, actionable message; nothing
  is written unless the whole import validates.
- **Cancel mid-import** leaves no dataset behind.
- **A workspace appears** with metric cards and a paged data table (256 rows/page), with
  **search** debounced at 250 ms and executed in Rust.
- **Save and reopen** from home restores the same revision.
- **No INTERNET permission** in the shipped manifest, verified on the built APK every run.

Now user-visible: sorting, filtering, all three chart types, explanations, type switching,
undo/redo and manual layout editing. Still not user-visible: field-correction UI, library
rename/duplicate/delete, recovery UI after a forced kill, templates, and sharing into Morphic.

---

## 4. Evidence

| Task | Commit | CI run | Result |
|---|---|---|---|
| 1.2.1 JSON | `96a049d` | 42206085112 | 6/6 ✅ |
| 1.2.2 TXT / logs / JSONL | `f6008d3` | 42223638706 | 6/6 ✅ |
| 1.2.3 Detection | `ac08894` | 42234638594 | 6/6 ✅ |
| 1.2.4 Import UX + cancel | `a6dd398` | 42248008908 | 6/6 ✅ |
| 1.2.5 Clipboard + share evaluation | `fccec5c` | 42256267974 | 6/6 ✅ |
| AT-02 scoring + heuristics | `00c446e` | 42264783444 | 6/6 ✅ |
| Parser fuzz smoke | `b9269be` | 42273176017 | 6/6 ✅ |
| 1.3.1 Full plan execution | `976578a` | 42335467607 | 6/6 ✅ |
| 1.3.2 Interaction commands | `57581a0` | 42369916529 | 6/6 ✅ |
| 1.3.3 Table interactions | `97d20cb` | 42380094459 | 6/6 ✅ |
| 1.3.4 Global filters + tap-to-filter | `44221b1` | 42388218245 | 6/6 ✅ |
| 1.3.5 Cross-component consistency | `50b0f3b` | 42393527394 | 6/6 ✅ |
| AT-07 device instrument | `74c22f2` | 42399189793 | 6/6 ✅ |
| 1.4.1 Scene contracts + chartData | `cf3427c` | 42478388255 | 6/6 ✅ |
| Gradle distribution cache + retry | `2940a0a` | 42479675870 | 6/6 ✅ |
| 1.4.2 bar_chart painter + goldens | `8d3f650` | 42492997637 | 6/6 ✅ |
| 1.4.3 line_chart + frame harness | `d6f2143` | 42500967870 | 6/6 ✅ |
| 1.4.4 timeline painter | `f8cb419` | 42507161800 | 6/6 ✅ |
| Build stamp + stamp gate | `ac98dad` | 42520442345 | 6/6 ✅ |
| Timeline lane toggle declared | `6339c53` | 42656434678 | 6/6 ✅ |
| 1.4.5 planner v1 + AT-12 scorer | `a3888f5` | 42691694719 | 6/6 ✅ |
| **1.4.6 "Why this view?" sheet** | **`2705e92`** | **42744816936** | **6/6 ✅** |
| **1.4.7 `ChangeComponentType`** | **`650a18a`** | **42814799346** | **6/6 ✅** |
| **1.5.1 undo/redo + bounded journal** | **`7e59106`** | **42863981801** | **6/6 ✅** |
| **1.5.2 manual layout + focus mode** | **`6752d0d`** | **42873440886** | **6/6 ✅** |

Current totals: **676 Rust tests** across 8 engine crates + the bridge (counted as `#[test]`
functions: ingest 310, query 82, core 77, schema 42, compiler 50, semantic 27, workspace 24,
model 11, bridge 53), **466 Dart tests** plus **54 golden images**, and **20 Python cases** for
the device-evidence gate. 1.5.1 added 7 Rust tests (workspace 22 → 24, core 71 → 75, bridge
52 → 53) and 3 Dart tests (459 → 462). 1.5.2 added 4 Rust tests (schema 40 → 42, core 75 → 77)
and 4 Dart tests (462 → 466), with **no** golden images: editing mode is opt-in and the existing
54 PNGs were compared LIVE (`bootstrapped: false`). Earlier M1.3/M1.4 additions are recorded in
their own status reports.
Gates on the latest run: `PERMISSIONS_OK`, `ENGINE_FFI_OK`, `POC_OK`,
`RUNTIME_OK: range 1-256 of 600`, `PAGING_OK`. Run **42873440886** (`6752d0d`) is **6/6 ✅** with
`STAMP_OK` / About `6752d0d`; the main manifest still has no INTERNET permission.

Toolchain: rustc 1.99.1, Flutter 3.47.9 / Dart 3.13.7, AGP 9.1, SDK 36 / min 24, 16 KB pages,
three ABIs.

---

## 5. The 19 acceptance tests, honestly

| Test | Subject | State | What is missing |
|---|---|---|---|
| AT-01 | Vertical slice | partial | 10 MB → ≤ 3 s never measured; no mid-class device |
| AT-02 | Detection accuracy | **green** | 100% dtype / 100% role on 21 files — but tuned against that corpus, so it is an upper bound |
| AT-03 | JSON breadth | **green** | the 256 MiB refusal is proven with a lowered ceiling, not a real 256 MB file |
| AT-04 | Logs & TXT | partial | extraction ✓, zero dropped lines ✓, timeline painter ✓ (1.4.4). But no corpus log currently *gets* one: logfmt/server_logs have a measure so they get a severity-split line, and syslog/CLF time stays `utf8`, which the query layer cannot bucket. Needs CLF/RFC3164 parsing in ingest |
| AT-05 | Malformed safety | **green** | 3,000-case mutation smoke clean; coverage-guided fuzzing still deferred to M1.7 |
| AT-06 | Filtering | **green** | semantics, composition, atomic batches, per-column menu, global bar and chips, tap-to-filter, exact restoration on clear, and no torn frame — all asserted, in Dart and at the FFI boundary |
| AT-07 | Sorting | partial | correct, stable, nulls-last ✓; tap-to-cycle indicator read from persisted state ✓; scroll reset ✓; 36–70 ms on CI x86 for 100k×10, **not** the ≤150 ms mid-ARM figure |
| AT-08 | Search | **green** | case-insensitive, field-scoped, commutes with filter/sort (property test), debounced as-you-type UI. The test itself specifies no latency bound |
| AT-09 | Save & reopen | partial | restore ✓; filters/sort/search now persist and survive reopen (tested); ≤ 500 ms unmeasured; field-correction UI is 1.5.5 |
| AT-10 | UI schema validity | **green** | gate-enforced on every run; since 1.4.6 the explanation clause is checked across all 21 fixtures, not just one synthetic profile |
| AT-11 | Component states | partial | **5 of 5** components paintable; **54 golden images** committed and gated. They pin geometry, colour and layout — with no font asset the test font draws boxes, so wording is asserted behaviourally instead |
| AT-12 | Selection quality | **green** | **96.6% (85/88) on 21 labelled files**, target 85%; all three guarantees asserted per file; every generated chart rendered against its own fixture, 0 failures. Tuned against this corpus, so an upper bound. The 3 misses are text time axes the query layer cannot bucket — labels deliberately left asking for the chart |
| AT-13 | Undo/redo | partial | automated 10-command state-hash + restart gates green (`7e59106`, run 42863981801); device half, chaos suite and ≤ 500 ms reopen still owed |
| AT-14 | Layout adjustment | partial | automated reorder/span/height/type-switch persistence, validation and widget gates green (1.5.2, run 42873440886); device half still owed |
| AT-15 | Library lifecycle | partial | list/open ✓; rename/duplicate/delete are 1.5.3 |
| AT-16 | Missing-source resilience | partial | degraded mode ✓; re-link flow and recovery UI are 1.5.3/1.5.4 |
| AT-17 | User corrections | not started | override commands persist and undo, but the table-header UI and targeted recompilation are 1.5.5 |
| AT-18 | Responsive & a11y | not started | M1.6 |
| AT-19 | Release artifact | partial | dry-run APK only; unsigned; ~48 MB fat vs ≤ 40 MB per-ABI target |

**A plan defect worth fixing:** M1.2's exit says "AT-04 passes", but AT-04 requires that "a
timeline appears for temporal logs", and the timeline painter is task **1.4.4**. As written,
M1.2's exit cannot be reached during M1.2. Split AT-04 into *extraction* (M1.2, satisfied) and
*rendering* (M1.4) rather than either claiming a pass or blocking M1.2 on M1.4.

---

## 6. Six gaps that no task row covers

These will not be closed by working through the task list, because no task owns them:

1. **Mid-class device evidence.** The matrix requires a Pixel 6a/7a-class phone for *every*
   milestone exit. Both available devices (C51, A15) are low class. Nothing downstream can be
   signed off until this is solved. **Partly addressed:** AT-07's latency now has an instrument
   (`tools/device_perf.sh`) and a machine-checkable gate (`--require-at07`), and the gate accepts
   a low-class pass as the stronger result it is. The functional matrix still wants a mid-class
   handset, and the measurement still has to be *run* — see
   [at07-latency-measurement.md](../engineering/at07-latency-measurement.md).
2. **The nightly workflow has never executed.** GitHub only registers workflow files from the
   default branch, so the cron has never fired and `cargo-deny` / `cargo-audit` have never run.
   The fuzz smoke was moved into CI so it actually executes; the supply-chain audit cannot be,
   and waits for the merge to `main`.
3. **The 10 MB → ≤ 3 s hypothesis is unmeasured.** It is the product's central claim. The
   dataset generator and the phone harness now exist, so this is one import away rather than
   needing new tooling.
4. **Golden images exist but cannot check text.** Task 1.1.5 promised them and 1.4.2 built the
   harness: now 54 images — bar, line and timeline, each across two themes and nine states —
   committed and gated in CI on the same generate-then-compare contract as the Rust snapshots.
   But the repo ships no font asset, so Flutter's test font draws glyph boxes — the images pin
   geometry, colour and layout, not wording. A bundled font is still owed. Reviewing them does
   pay: the line-chart images exposed a lone measurement between gaps rendering as nothing at all,
   which no behavioural test had caught.
5. **The report sheet shows caveat counts, not the quarantined rows themselves.** Users can
   see *that* 12 rows were set aside but not *which* — the honest-reporting promise is half kept.
6. **Release size and signing.** ~48 MB fat APK against a ≤ 40 MB per-ABI target; signing
   secrets unconfigured; only a dry-run prerelease has been produced.

---

## 7. Recommended next moves

**M1.5 has two of five core rows shipped and CI-green.** 1.5.1 (undo/redo with bounded journal
history) and 1.5.2 (manual layout with persisted hints and phone focus) are recorded in
[m1.5-status.md](m1.5-status.md). The next coding row is either 1.5.3 (library lifecycle and
degraded re-link) or 1.5.5 (field-correction UI plus targeted recompilation); 1.5.4 also needs
the kill-mid-save chaos suite. None of those alone closes the milestone.

**The largest blocker is still one afternoon of mid-class device time.** It gates AT-01's 10 MB
≤ 3 s claim, AT-07's ≤ 150 ms sort/filter budget, AT-09's ≤ 500 ms reopen, the device halves of
AT-13/AT-14, and M1.4's chart p95 ≤ 33 ms. Both available handsets are low class; the stronger
low-class pass is useful but does not satisfy the written matrix. `tools/device_perf.sh` and the
AT-07 gate exist, but the measurement still has to be run.

**Keep the cheap checks gated.** The AT-02 scorer (21 labelled files, 90 fields), the 3,000-case
seeded fuzz smoke, the 54 LIVE goldens, schema drift and the build-stamp/permission checks all run
on every push. Held-out detection files, coverage-guided fuzzing, all-five golden coverage and a
bundled font remain owed; the nightly supply-chain audit is blocked on the merge to `main`, not
on missing code.

**Re-baseline the estimate.** The remaining **13 core tasks** are **17–31 focused days** — still a
large slice of the 30–40 the plan allowed for *all* of Phase 1, with **26 tasks** already spent.
If the calendar cannot absorb that, the honest lever is scope: the two remaining ◇ stretch items
(`.morphic` bundles, templates) are already optional, and M1.6's design sweep can be narrowed
without touching correctness.

---

## 8. Where the detail lives

- Task list and exits: [phase-1-mvp-plan.md](phase-1-mvp-plan.md)
- Acceptance definitions: [mvp-acceptance-tests.md](mvp-acceptance-tests.md)
- M1.2 task-by-task notes and CI post-mortems: [m1.2-status.md](m1.2-status.md)
- M1.5 task-by-task notes and CI post-mortems: [m1.5-status.md](m1.5-status.md)
- Device procedure and class matrix: [real-device-testing.md](../engineering/real-device-testing.md)
- Share-to-Morphic evaluation: [ADR-0015](../decisions/ADR-0015-share-to-morphic.md)
