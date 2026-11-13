# Phase 1 standing report — updated for 1.6.2

Written after task **1.2.5** went CI-green (run **42256267974**, commit **`fccec5c`**, all six
jobs success). Every number below was read from the plan, the source tree, or a CI report —
not from memory.

**Update 2026-11-08:** **M1.4 task 1.4.1** (scene contracts + `chartData` aggregation) is done and
CI-green; see [m1.4-status.md](m1.4-status.md).

**Update:** **M1.4 task 1.4.7** (`ChangeComponentType`) is done and CI-green. All seven M1.4
task rows are now implemented; the milestone exit is still unmet. See
[m1.4-status.md](m1.4-status.md) §13.

**Update 2026-11-10:** **M1.5 tasks 1.5.1, 1.5.2 and 1.5.3** are done and CI-green. Undo/redo
with bounded journal history, manual layout editing with persisted hints and phone focus mode,
then home-library rename/duplicate/delete and hash-verified degraded re-link have shipped; M1.5
is in progress, not exited. See [m1.5-status.md](m1.5-status.md) §4.

**Update 2026-11-11:** **M1.5 task 1.5.5** (field-correction UI and targeted recompilation) is
done and CI-green at `23513e0` / run **43024916235**, 6/6 ✅. At that point `API_VERSION` was
**11** and AT-17 was green as an automated test. M1.5 then had 4 of 5 core rows shipped; 1.5.4
was the only remaining core row and the milestone was still not exited. See
[m1.5-status.md](m1.5-status.md) §5.

**Update (1.5.4):** **M1.5 task 1.5.4** (autosave hardening, recovery UI and the kill-mid-save
chaos suite) is done and CI-green at `641c48c` / run **43057629282**, 6/6 ✅. `API_VERSION` was
**12**, all five M1.5 core rows were shipped, AT-16 was green as an automated test, and the named
chaos gate runs on every push. The nightly cron is wired but has not fired; M1.5 remains **not
exited** because AT-13/AT-14 device halves, AT-18, reopen ≤ 500 ms and the other evidence gaps
are still owed. See [m1.5-status.md](m1.5-status.md) §6.

**Update (1.5.6):** **M1.5 task 1.5.6** (`.morphic` bundle export/import) is done and CI-green at
`a8e42e4` / run **43070316539**, 6/6 ✅, after the red first implementation run, a rustfmt bot
push and a normal fix commit. `API_VERSION` was then **13**. All **six** M1.5 task rows are shipped,
including the optional stretch row; M1.5 remains **not exited** because the device halves, AT-18,
reopen ≤ 500 ms and the other evidence gaps are still owed. See [m1.5-status.md](m1.5-status.md)
§8.

**Update (1.6.4):** **M1.6 task 1.6.4** (four bundled sample datasets and an empty-library
first-run suggestion) is done and CI-green at `354f1ad` / run **43100359669**, 6/6 ✅, after two
stuck queued runs, a concurrency-group reset and a scoped analyzer fix for Flutter 3.50's
`material.dart` deprecation. `API_VERSION` stayed **13**. At that point M1.6 had **1 of 6**
rows shipped; its exit — and every other formal exit — remained unmet. See [m1.6-status.md](m1.6-status.md) §§1–2.

**Update (1.6.5):** The empty/error/edge copy sweep adds recovery guidance and scope-aware
filter clearing while keeping engine error evidence. The final code tip `23d41b9` / run
**43283304890** passed **6/6 ✅**, with 528 Dart tests and 54 live golden comparisons. M1.6 then
had two shipped rows and no formal exit. See [m1.6-status.md](m1.6-status.md) §3.

**Update (1.6.1):** The key-screen design pass adds bundled fonts, dark/light theme preference,
real-event motion, an undoable live title and readable goldens for all five component families.
The final code follow-up `3cc9edf` / run **43367563320** passed **6/6 ✅**, including 82 live
image comparisons. The bridge is now **v14**. AT-11 and AT-18 are still partial, and all formal
exits remain open; see [m1.6-status.md](m1.6-status.md) §§4, 6.

**Update (1.6.2):** Adaptive workspace flow, opt-in compact focus, responsive inspection
surfaces and 1.3× dark/light examples shipped. The unmarked live-golden verification
`ec57a26` / run **43381823333** passed **6/6 ✅**, including 581 behavioral tests and 100
live golden tests against 102 PNGs. AT-18 remains partial and all formal exits remain open;
see [m1.6-status.md](m1.6-status.md) §§5–6.

**Update (1.6.3 in progress):** Table, metric, line and timeline accessibility changes have
host semantics, target, keyboard and 1.3× image coverage. `6773f4c` / run **43396617222**
passed **6/6**, including 617 behavioral tests, 106 live golden tests and an emulator assertion
for correctly paired sample-table fields/values. A further ready-state host matrix awaits CI.
The [accessibility checklist](../engineering/accessibility-checklist.md) is unsigned: physical
TalkBack and the full responsive/target/contrast matrix are still owed. AT-18, the 1.6.3 row
and all milestone exits remain open; the task totals below are unchanged. See
[m1.6-status.md](m1.6-status.md) §7.

**Update 2026-11-07:** **M1.3 is code-complete** — all five tasks (plan execution, interaction
commands, the interactive table, global filters with tap-to-filter, and cross-component
consistency) are done and CI-green. Tallies below reflect them; `docs/roadmap/m1.3-status.md`
records the decisions, the measured evidence, and why the milestone's **exit is still unmet**.

---

## 1. The short answer

| Question | Answer |
|---|---|
| Tasks finished | **34 of 41** (83%) |
| Tasks not finished | **7** — 6 core + 1 stretch (◇) |
| Milestones core-complete | **5 of 7** (M1.1–M1.5; M1.5 is code-complete including its ◇ stretch row) |
| Milestones not started | **1** (M1.7); M1.6 has 4 of 6 rows shipped |
| Milestone exits formally met | **0 of 7** |
| Acceptance tests fully green | **10 of 19** (AT-02, AT-03, AT-05, AT-06, AT-08, AT-10, AT-12, AT-15, AT-16, AT-17) |
| Acceptance tests partially evidenced | **9** (including AT-18's representative responsive and token evidence) |
| Acceptance tests not yet started | **0** |
| Evidence gaps no task row fully covers | **6** (see §6) |
| Remaining core effort, by the plan's own S/M/L legend | **7–12 focused days** |

**The most important finding is the last row.** The plan estimates *all of Phase 1* at 30–40
focused days. With M1.3, all seven M1.4 tasks, all six M1.5 rows and 1.6.1/1.6.2/1.6.4/1.6.5
finished, the **6 unfinished core tasks sum to 7–12 days** under the plan's own legend
(S ≈ ½ day, M ≈ 1–2, L ≈ 3–5), excluding the one remaining ◇ stretch item:

| Remaining milestone | Core tasks | Focused days |
|---|---|---|
| M1.4 Visualization + planner | 0 | 0 |
| M1.5 Lifecycle & layout | 0 | 0 |
| M1.6 Experience pass (one M) | 1 | 1–2 |
| M1.7 Hardening & release (one L + two M + two S) | 5 | 6–10 |
| **Total** | **6** | **7–12** |

The figure is recomputed from the plan's rows on every update rather than decremented by hand.
The estimate was optimistic before any work started and 34 finished tasks have not made it less
so. §7 proposes a re-baseline.

---

## 2. Milestone by milestone

| Milestone | Tasks | Done | Code status | Exit status |
|---|---|---|---|---|
| M1.1 Vertical slice | 7 | 7 | **complete** | **unmet** — needs a mid-class device; 10 MB ≤ 3 s unmeasured; AT-02 is scored on a tuned corpus |
| M1.2 Format breadth | 5 | 5 | **complete** | **unmet** — AT-04's temporal-log timeline is not generated for the current corpus; device evidence pending (fuzz smoke now clean) |
| M1.3 Interactivity | 5 | 5 | **complete** | **unmet** — AT-06 ✓ AT-08 ✓; AT-07 blocked only on mid-class ARM latency |
| M1.4 Visualization + planner | 7 | 7 | **code-complete** — all five painters, planner v1, the explanation sheet and `ChangeComponentType` shipped | **unmet** — AT-11's full state matrix is incomplete and chart p95 ≤33 ms is not device-measured; all five families now have some goldens |
| M1.5 Lifecycle & layout | 6 | 6 | **code-complete** — all five core rows plus the CI-green ◇1.5.6 stretch shipped; the stretch row does not satisfy the exit | **unmet** — AT-13/14 device halves, AT-18, reopen ≤ 500 ms; AT-15/16/17 green as automated tests; named chaos suite CI-green |
| M1.6 Experience pass | 6 | 4 | **in progress** — 1.6.1 design pass, 1.6.2 responsive layouts, 1.6.4 samples and 1.6.5 copy/recovery shipped; 1.6.3 is underway and ◇1.6.6 remains | **unmet** — full acceptance suite on low/mid devices, UX validation with ≥3 external people and a no-token-violations sweep still owed |
| M1.7 Hardening & release | 5 | 0 | not started | — |

Phase 0 (architecture, contracts, CI, release pipeline) is complete and was verified by run
42066050532.

**"Core-complete" is not "done".** All five core-complete milestones have working, tested code
and none has met its exit criteria, because those exits demand evidence this sandbox cannot
produce: a physical mid-range phone, an overnight fuzz run, the full AT-11 golden state matrix
and a device-measured interaction budget. M1.5 has all five core rows shipped but is not exited;
its automated AT-13/AT-14 halves are green, AT-15/16/17 are fully green as automated tests, and
the named kill-mid-save chaos suite is CI-green, while the device halves, AT-18 and reopen ≤ 500 ms
are still owed. The optional ◇1.5.6 stretch row is shipped and CI-green, but that does not change
the exit. M1.6 has shipped 1.6.1, 1.6.2, 1.6.4 and 1.6.5 while every formal exit stays open.
That distinction is the difference between a demo and a milestone.

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

Also user-visible in the current build: sorting, filtering, all three chart types, explanations,
type switching, undo/redo, manual layout editing, library operations, degraded-source re-link,
field corrections, a recovery report, bundled samples and empty-state recovery controls. These
later paths have automated coverage; that is not a claim that they were all exercised on the
physical device above. Workspace templates and sharing into Morphic have not shipped.

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
| **1.5.3 library lifecycle + re-link** | **`e87a7e6`** | **42970337214** | **6/6 ✅** |
| **1.5.4 autosave + crash recovery** | **`641c48c`** | **43057629282** | **6/6 ✅** |
| **1.5.5 field corrections** | **`23513e0`** | **43024916235** | **6/6 ✅** |
| **1.5.6 bundle export/import** | **`a8e42e4`** | **43070316539** | **6/6 ✅** |
| **1.6.4 bundled samples** | **`354f1ad`** | **43100359669** | **6/6 ✅** |
| **1.6.5 recovery follow-up** | **`f100c66`** | **43277741494** | **6/6 ✅** (goldens regenerated) |
| **1.6.5 unsupported-view guidance** | **`05e2ed7`** | **43279681382** | **6/6 ✅** |
| **1.6.5 final code + live golden comparison** | **`23d41b9`** | **43283304890** | **6/6 ✅** |
| **1.6.1 design sweep + initial live comparison** | **`890f318`** | **43305457290** | **6/6 ✅** (78 images; recovery follow-up later) |
| **1.6.1 compact-title follow-up** | **`3748377`** | **43366494089** | **6/6 ✅** (82 images regenerated) |
| **1.6.1 empty-recovery follow-up + live images** | **`3cc9edf`** | **43367563320** | **6/6 ✅** (82 images compared live) |
| **1.6.2 responsive fixes + regenerated images** | **`915a4e9`** | **43380517761** | **6/6 ✅** (regeneration, bot `283ee8e`) |
| **1.6.2 committed-image verification** | **`ec57a26`** | **43381823333** | **6/6 ✅** (102 images compared live) |

Current source contains **703 Rust `#[test]` functions** across 8 engine crates and the bridge.
The image suite loads the bundled Inter, JetBrains Mono and Material icon fonts, and includes
bar, line, timeline, metric, table and key-screen images in both themes. The live comparison on
`ec57a26` passed 100 golden tests against 102 committed PNGs (`bootstrapped: false`), alongside
581 behavioral tests and clean analysis. The full AT-11 state matrix remains incomplete. The
generated UI schema artifact is unchanged; previous totals and per-task test additions are
recorded in the individual milestone reports.

Run **43381823333** also reports `STAMP_OK`, `PERMISSIONS_OK`, `ENGINE_FFI_OK`, `POC_OK`,
`RUNTIME_OK: range 1-256 of 600` and `PAGING_OK`, with the range changing to 257-512 of 600.
The 600-row probe correctly refuses an AT-07 performance verdict. The main manifest still has no INTERNET permission (debug
INTERNET is expected). The runtime smoke runs on an emulator, not a physical device. Toolchain:
rustc 1.100.0, Flutter 3.50.0 / Dart 3.14.0, AGP 9.1, SDK 36 / min 24, 16 KB pages and three ABIs.

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
| AT-09 | Save & reopen | partial | restore ✓; filters/sort/search and field corrections now persist and survive reopen (tested); ≤ 500 ms unmeasured |
| AT-10 | UI schema validity | **green** | gate-enforced on every run; since 1.4.6 the explanation clause is checked across all 21 fixtures, not just one synthetic profile |
| AT-11 | Component states | partial | All five component families now have readable dark/light goldens, but the complete loading, empty-after-filter and binding-error matrix is not covered for every family |
| AT-12 | Selection quality | **green** | **96.6% (85/88) on 21 labelled files**, target 85%; all three guarantees asserted per file; every generated chart rendered against its own fixture, 0 failures. Tuned against this corpus, so an upper bound. The 3 misses are text time axes the query layer cannot bucket — labels deliberately left asking for the chart |
| AT-13 | Undo/redo | partial | automated 10-command state-hash + restart gates green (`7e59106`, run 42863981801); device half and ≤ 500 ms reopen still owed (chaos suite is now CI-green in 1.5.4) |
| AT-14 | Layout adjustment | partial | automated reorder/span/height/type-switch persistence, validation and widget gates green (1.5.2, run 42873440886); device half still owed |
| AT-15 | Library lifecycle | **green** | 3 workspaces, rename/duplicate/delete, one shared dataset on disk and two healthy survivors proven in Rust + Dart on run 42970337214; no device claim |
| AT-16 | Missing-source resilience | **green** | Degraded notice offers re-link (with an additional app-bar action on wide screens); hash-verified re-link restores `metric_data`. Named CI chaos gate covers interrupted writes, torn journals, quarantine, torn-index repair and migration backup. Automated only, no device claim |
| AT-17 | User corrections | **green** | 1.5.5 (`23513e0`, run 43024916235): only affected bindings recompile, the override persists across reopen, undo restores the semantic state hash; automated only, no device claim |
| AT-18 | Responsive & a11y | partial | Responsive and new semantics/target/keyboard tests plus selected 1.3× images pass on host; the full no-clipping/≥48 dp/contrast matrix and physical-device TalkBack vertical slice remain unverified |
| AT-19 | Release artifact | partial | dry-run APK only; unsigned; ~48 MB fat vs ≤ 40 MB per-ABI target |

**A plan defect worth fixing:** M1.2's exit says "AT-04 passes", but AT-04 requires that "a
timeline appears for temporal logs", and the timeline painter is task **1.4.4**. As written,
M1.2's exit cannot be reached during M1.2. Split AT-04 into *extraction* (M1.2, satisfied) and
*rendering* (M1.4) rather than either claiming a pass or blocking M1.2 on M1.4.

---

## 6. Six evidence gaps not fully covered by the task rows

These need explicit ownership and evidence, not just a count of finished task rows:

1. **Mid-class device evidence.** The matrix requires a Pixel 6a/7a-class phone for *every*
   milestone exit. Both available devices (C51, A15) are low class. Nothing downstream can be
   signed off until this is solved. **Partly addressed:** AT-07's latency now has an instrument
   (`tools/device_perf.sh`) and a machine-checkable gate (`--require-at07`), and the gate accepts
   a low-class pass as the stronger result it is. The functional matrix still wants a mid-class
   handset, and the measurement still has to be *run* — see
   [at07-latency-measurement.md](../engineering/at07-latency-measurement.md).
2. **The nightly workflow has never executed.** GitHub only registers workflow files from the
   default branch, so the cron has never fired and `cargo-deny` / `cargo-audit` have never run.
   The fuzz smoke and the named 1.5.4 chaos suite were both put into `ci.yml` so they actually
   execute; the nightly copies are wired but have not fired, and the supply-chain audit waits for
   the merge to `main`.
3. **The 10 MB → ≤ 3 s hypothesis is unmeasured.** It is the product's central claim. The
   dataset generator and the phone harness now exist, so this is one import away rather than
   needing new tooling.
4. **The AT-11 golden state matrix is incomplete.** Task 1.6.1 bundles the real fonts and adds
   metric/table and key-screen snapshots; all five component families now have readable images
   in both themes. The required loading, empty-after-filter and binding-error states are not yet
   golden-covered for every component/theme. Earlier line-chart review exposed a lone measurement
   between gaps rendering as nothing at all, so visual review remains useful alongside behavioral
   assertions.
5. **The report sheet shows caveat counts, not the quarantined rows themselves.** Users can
   see *that* 12 rows were set aside but not *which* — the honest-reporting promise is half kept.
6. **Release size and signing.** ~48 MB fat APK against a ≤ 40 MB per-ABI target; signing
   secrets unconfigured; only a dry-run prerelease has been produced.

---

## 7. Recommended next moves

**M1.5 has all six task rows shipped and CI-green.** 1.5.1 (undo/redo with bounded journal
history), 1.5.2 (manual layout with persisted hints and phone focus), 1.5.3 (library lifecycle
and hash-verified degraded re-link), 1.5.4 (autosave hardening, recovery UI and the kill-mid-save
chaos suite), 1.5.5 (field-correction UI plus targeted recompilation) and 1.5.6 (`.morphic` bundle
export/import) are recorded in [m1.5-status.md](m1.5-status.md) §§2–8. AT-15, AT-16 and AT-17 are
green as automated tests. No M1.5 code row remains; neither the shipped ◇1.5.6 stretch row nor the
now-green chaos suite alone closes the milestone. **M1.6.1, 1.6.2, 1.6.4 and 1.6.5 have since
shipped** the key-screen design pass, responsive layouts, bundled samples and empty/error recovery
copy. They are code rows, not device or UX-validation evidence. See
[m1.6-status.md](m1.6-status.md) §§2–6.

**The largest blocker is still one afternoon of mid-class device time.** It gates AT-01's 10 MB
≤ 3 s claim, AT-07's ≤ 150 ms sort/filter budget, AT-09's ≤ 500 ms reopen, the device halves of
AT-13/AT-14, and M1.4's chart p95 ≤ 33 ms. Both available handsets are low class; the stronger
low-class pass is useful but does not satisfy the written matrix. `tools/device_perf.sh` and the
AT-07 gate exist, but the measurement still has to be run.

**Keep the cheap checks gated.** The AT-02 scorer (21 labelled files, 90 fields), the 3,000-case
seeded fuzz smoke, the named 1.5.4 chaos suite, committed image comparisons, schema drift and
the build-stamp/permission checks all run on every push. Stable Flutter is now 3.50.0/Dart 3.14.0;
`analysis_options.yaml` suppresses only the new `material.dart` deprecation info, so analyzer
findings remain fatal and `flutter analyze` is green. Held-out detection files, coverage-guided
fuzzing and the complete AT-11 image state matrix remain owed; the nightly supply-chain audit
and the nightly chaos copy are blocked on the merge to `main`, not on missing code.

**Re-baseline the estimate.** The remaining **6 core tasks** are **7–12 focused days** — still a
large slice of the 30–40 the plan allowed for *all* of Phase 1, with **34 tasks** already spent.
If the calendar cannot absorb that, the one remaining ◇ stretch item (templates) is already
optional; narrowing acceptance, accessibility or device evidence requires an explicit re-plan.

---

## 8. Where the detail lives

- Task list and exits: [phase-1-mvp-plan.md](phase-1-mvp-plan.md)
- Acceptance definitions: [mvp-acceptance-tests.md](mvp-acceptance-tests.md)
- M1.2 task-by-task notes and CI post-mortems: [m1.2-status.md](m1.2-status.md)
- M1.5 task-by-task notes and CI post-mortems: [m1.5-status.md](m1.5-status.md)
- M1.6 task-by-task notes and CI post-mortems: [m1.6-status.md](m1.6-status.md)
- Device procedure and class matrix: [real-device-testing.md](../engineering/real-device-testing.md)
- Share-to-Morphic evaluation: [ADR-0015](../decisions/ADR-0015-share-to-morphic.md)
