# Phase 1 standing report — 2026-11-06, updated 2026-11-07

Written after task **1.2.5** went CI-green (run **42256267974**, commit **`fccec5c`**, all six
jobs success). Every number below was read from the plan, the source tree, or a CI report —
not from memory.

**Update 2026-11-07:** **M1.3 is code-complete** — all five tasks (plan execution, interaction
commands, the interactive table, global filters with tap-to-filter, and cross-component
consistency) are done and CI-green. Tallies below reflect them; `docs/roadmap/m1.3-status.md`
records the decisions, the measured evidence, and why the milestone's **exit is still unmet**.

---

## 1. The short answer

| Question | Answer |
|---|---|
| Tasks finished | **17 of 41** (41%) |
| Tasks not finished | **24** — 22 core + 2 stretch (◇) |
| Milestones code-complete | **3 of 7** (M1.1, M1.2, M1.3) |
| Milestones not started | **4** (M1.4 → M1.7) |
| Milestone exits formally met | **0 of 7** |
| Acceptance tests fully green | **6 of 19** (AT-02, AT-03, AT-05, AT-06, AT-08, AT-10) |
| Acceptance tests partially evidenced | **7** |
| Acceptance tests not yet started | **6** |
| Evidence gaps no task row covers | **6** (see §6) |
| Remaining core effort, by the plan's own S/M/L legend | **31½–57 focused days** |

**The most important finding is the last row.** The plan estimates *all of Phase 1* at 30–40
focused days. With M1.3 now finished, the **22 unfinished core tasks alone sum to 31½–57 days**
under the plan's own legend (S ≈ ½ day, M ≈ 1–2, L ≈ 3–5), excluding the two ◇ stretch items:

| Remaining milestone | Core tasks | Focused days |
|---|---|---|
| M1.4 Visualization + planner | 7 | 10½–19 |
| M1.5 Lifecycle & layout | 5 | 7–13 |
| M1.6 Experience pass | 5 | 8–14 |
| M1.7 Hardening & release | 5 | 6–11 |
| **Total** | **22** | **31½–57** |

This corrects the 32–55 reported before M1.3 closed: recomputing straight from the plan's rows
puts the upper bound three days higher. The estimate was optimistic before any work started and
17 finished tasks have not made it less so. §7 proposes a re-baseline.

---

## 2. Milestone by milestone

| Milestone | Tasks | Done | Code status | Exit status |
|---|---|---|---|---|
| M1.1 Vertical slice | 7 | 7 | **complete** | **unmet** — needs a mid-class device; AT-02 unscored; 10 MB ≤ 3 s unmeasured |
| M1.2 Format breadth | 5 | 5 | **complete** | **unmet** — AT-04's timeline clause depends on M1.4; device evidence pending (fuzz smoke now clean) |
| M1.3 Interactivity | 5 | 5 | **complete** | **unmet** — AT-06 ✓ AT-08 ✓; AT-07 blocked only on mid-class ARM latency |
| M1.4 Visualization + planner | 7 | 0 | not started | — |
| M1.5 Lifecycle & layout | 6 | 0 | not started | — |
| M1.6 Experience pass | 6 | 0 | not started | — |
| M1.7 Hardening & release | 5 | 0 | not started | — |

Phase 0 (architecture, contracts, CI, release pipeline) is complete and was verified by run
42066050532.

**"Code-complete" is not "done".** Both finished milestones have working, tested code and
neither has met its exit criteria, because both exits demand evidence this sandbox cannot
produce: a physical mid-range phone, and an overnight fuzz run. That distinction is the
difference between a demo and a milestone.

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

Not yet user-visible: sorting, filtering, all three chart types, undo/redo, layout editing,
templates, and sharing into Morphic.

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
| **1.3.5 Cross-component consistency** | **`50b0f3b`** | **42393527394** | **6/6 ✅** |

Current totals: **588 Rust tests** across 8 engine crates + the bridge, **307 Dart tests**.
M1.3 added 72 Rust tests: `morphic-query` 21 → 56, `morphic-core` 35 → 52, `morphic-schema`
24 → 33, bridge 32 → 48; and 119 Dart tests, the first substantial UI test suite.
Gates on the latest run: `PERMISSIONS_OK`, `ENGINE_FFI_OK`, `POC_OK`,
`RUNTIME_OK: range 1-256 of 600`, `PAGING_OK`.

Toolchain: rustc 1.99.1, Flutter 3.47.9 / Dart 3.13.7, AGP 9.1, SDK 36 / min 24, 16 KB pages,
three ABIs.

---

## 5. The 19 acceptance tests, honestly

| Test | Subject | State | What is missing |
|---|---|---|---|
| AT-01 | Vertical slice | partial | 10 MB → ≤ 3 s never measured; no mid-class device |
| AT-02 | Detection accuracy | **green** | 100% dtype / 100% role on 21 files — but tuned against that corpus, so it is an upper bound |
| AT-03 | JSON breadth | **green** | the 256 MiB refusal is proven with a lowered ceiling, not a real 256 MB file |
| AT-04 | Logs & TXT | partial | extraction ✓; the **timeline** it requires is task 1.4.4 |
| AT-05 | Malformed safety | **green** | 3,000-case mutation smoke clean; coverage-guided fuzzing still deferred to M1.7 |
| AT-06 | Filtering | **green** | semantics, composition, atomic batches, per-column menu, global bar and chips, tap-to-filter, exact restoration on clear, and no torn frame — all asserted, in Dart and at the FFI boundary |
| AT-07 | Sorting | partial | correct, stable, nulls-last ✓; tap-to-cycle indicator read from persisted state ✓; scroll reset ✓; 36–70 ms on CI x86 for 100k×10, **not** the ≤150 ms mid-ARM figure |
| AT-08 | Search | **green** | case-insensitive, field-scoped, commutes with filter/sort (property test), debounced as-you-type UI. The test itself specifies no latency bound |
| AT-09 | Save & reopen | partial | restore ✓; filters/sort/search now persist and survive reopen (tested); ≤ 500 ms unmeasured; field overrides are M1.5 |
| AT-10 | UI schema validity | **green** | gate-enforced on every run |
| AT-11 | Component states | partial | **2 of 5** components paintable; **0 golden files** |
| AT-12 | Selection quality | not started | M1.4; needs `fixtures/expected/` |
| AT-13 | Undo/redo | not started | M1.5 |
| AT-14 | Layout adjustment | not started | M1.5 |
| AT-15 | Library lifecycle | partial | list/open ✓; rename/duplicate/delete are 1.5.3 |
| AT-16 | Missing-source resilience | partial | degraded mode ✓; re-link flow and recovery UI are 1.5.3/1.5.4 |
| AT-17 | User corrections | not started | M1.5 |
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
4. **Zero golden images.** Task 1.1.5 promised them; M1.4 and M1.6 both assume they exist.
5. **The report sheet shows caveat counts, not the quarantined rows themselves.** Users can
   see *that* 12 rows were set aside but not *which* — the honest-reporting promise is half kept.
6. **Release size and signing.** ~48 MB fat APK against a ≤ 40 MB per-ABI target; signing
   secrets unconfigured; only a dry-run prerelease has been produced.

---

## 7. Recommended next moves

**M1.3 is code-complete, and the next move is not a coding task.** Its exit is blocked on one
thing: filter+sort latency for 100k×10 on a mid-class ARM phone. The same device run also blocks
AT-01 (10 MB ≤ 3 s) and AT-09 (reopen ≤ 500 ms), and it has been listed as an unowned gap since
M1.1. Starting M1.4's charts first would put a second milestone behind the same afternoon of
device time.

**Then 1.4.1** — the visualization milestone is the next in dependency order, and it inherits a
runtime that can now filter, sort, search and stay consistent, plus the AT-02 scoring harness for
the planner work.

"No Dart-side data logic" is now enforced by tests rather than by absence: the table sends
commands and renders pages, and the interaction suite asserts that no query plan was ever
assembled in Dart.

But three cheap items should be slotted in **before** M1.3 gets deep, because each gets more
expensive later:

1. **Get one mid-class device run** (or formally re-plan the matrix with evidence). This is the
   single blocker on the most exits.
2. ~~Build the AT-02 scorer.~~ **Done** — 21 labelled files, 90 fields, scored in CI, and the
   first measurement drove six real heuristic fixes. M1.4's planner accuracy work now inherits
   the harness. Next step is held-out files, not more tuning.
3. ~~Add a fuzz target.~~ **Done** — a 3,000-case seeded mutation smoke runs on every push and
   found no panic, no invariant violation and a 16 ms worst case. Running the *nightly* is still
   blocked, but on the merge to `main`, not on missing work.

**Re-baseline the estimate.** State plainly that the remaining 22 core tasks are 31½–57 focused
days — more than the 30–40 the plan allowed for *all* of Phase 1, with 17 tasks already spent.
If the calendar cannot absorb that, the honest lever is scope: the two remaining ◇ stretch items (`.morphic` bundles, templates)
are already optional, and M1.6's design sweep can be narrowed without touching correctness.

---

## 8. Where the detail lives

- Task list and exits: [phase-1-mvp-plan.md](phase-1-mvp-plan.md)
- Acceptance definitions: [mvp-acceptance-tests.md](mvp-acceptance-tests.md)
- M1.2 task-by-task notes and CI post-mortems: [m1.2-status.md](m1.2-status.md)
- Device procedure and class matrix: [real-device-testing.md](../engineering/real-device-testing.md)
- Share-to-Morphic evaluation: [ADR-0015](../decisions/ADR-0015-share-to-morphic.md)
