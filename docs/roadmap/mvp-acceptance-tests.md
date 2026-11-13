# MVP Acceptance Test Specification

The formal definition of "Phase 1 works" (spec §20 deliverable 10). Each test is implemented
as an `integration_test` case (automated) or a scripted manual check (device/UX), and is
referenced by the [Phase 1 plan](phase-1-mvp-plan.md). Thresholds marked **(H)** are
hypotheses validated on the device matrix — results recorded in `perf-log.md`, never assumed.

Coverage of spec §13 Phase 1 required features: 1→AT-01/03/04 · 2→AT-02 · 3/4→AT-02/05 ·
5→AT-10 · 6→AT-10/11 · 7→AT-01 · 8→AT-06/07/08 · 9→AT-09 · 10→AT-14.

---

**AT-01 — Vertical slice (the hypothesis).**
Given airplane mode and a fresh install, when the user imports `fixtures/valid/sales.csv`
(≈10 MB, 100k×10) via the file picker, then a workspace with ≥1 metric card and a data table
appears in ≤ 3 s **(H)** (low-end ≤ 6 s **(H)**), every component shows real data, and no
network permission is used. *(automated + device)*

**AT-02 — Schema detection accuracy.**
Given the labeled fixture corpus (≥20 valid files), when each is imported, then inferred
field types match labels ≥ 95% per field **(H)** and role hints (temporal/severity/
dimension/measure) ≥ 85% **(H)**; every inference carries confidence + evidence.
*(automated, fixture-scored)*

**AT-03 — JSON breadth.**
Given an array-of-objects JSON with nested objects (depth ≤ 4) and mixed types, when
imported, then nested fields appear as flattened `a.b` columns and the workspace generates
correctly; a > 256 MB file fails with a clear ResourceLimit message, never a crash.
*(automated)*

**AT-04 — Logs & TXT.**
Given ISO-prefixed app logs, syslog, logfmt, and plain TXT fixtures, when imported, then
time/level/service/message are extracted where present, a timeline appears for temporal
logs, and unmatched lines are preserved in `message` (zero dropped lines). *(automated)*

**AT-05 — Malformed input safety.**
Given the malformed corpus (truncated JSON, ragged CSV, mixed encodings, 10k columns,
empty, header-only, null bytes), when imported, then each yields either a partial import
with an accurate quarantine report or a typed actionable error — never a crash, hang, or
silent garbage; cancellation mid-import leaves no dataset behind. *(automated + fuzz)*

**AT-06 — Filtering.**
Given a generated workspace, when the user adds a global filter (e.g. `level = ERROR`) and
a component filter, then all bound components reflect the intersection within one engine
revision (no torn state), chips show active filters, and clearing restores exact prior
aggregates. *(automated)*

**AT-07 — Sorting.**
Given a 100k-row table, when sorting any column asc/desc, then order is correct and stable
(nulls last), engine latency ≤ 150 ms **(H)**, and scroll position resets to top with the
sort indicator persisted in component state. *(automated + perf)*

**AT-08 — Search.**
Given a table with search enabled, when typing a substring, then results are
case-insensitive matches across projected string columns, update as you type (debounced),
and combine correctly with active filters/sort. *(automated)*

**AT-09 — Save & reopen.**
Given a workspace with filters, sort, layout hints, and a field override, when the app is
force-killed and relaunched, then reopening from home restores the identical revision
(structure, filters, sort, overrides) in ≤ 500 ms **(H)** with data intact. *(device)*

**AT-10 — Generated UI schema validity.**
Given every corpus fixture, when compiled, then the WorkspaceDoc passes all 5 validation
passes, contains ≤ 6 components, uses only registered types, and each component has a
non-empty explanation with evidence. *(automated)*

*1.4.6 note.* The explanation clause is gated corpus-wide in
`engine/crates/morphic-core/tests/plan_accuracy.rs`: `reason` must be a real `RULE_TABLE` id,
`detail` non-blank, `evidence` non-empty and non-blank, `confidence` in `0..1`. The schema
validator deliberately still accepts `explanation: null` so v1.0 can open hand-written and
older documents; the guarantee applies to documents the compiler produces, which is what this
test says. Before 1.4.6 only one synthetic profile was checked.

**AT-11 — Component instantiation & states.**
Given workspaces exercising all five MVP components, then each renders normal, loading,
empty-after-filter, and binding-error states correctly in both themes (goldens), and
tap-to-filter / scrub / legend interactions behave per registry contract. *(widget+golden)*

**AT-12 — Visualization selection quality.**
Given the labeled corpus, then planner selections match expected component sets ≥ 85%
**(H)**; temporal data always gets a time-based view; severity data always gets an error
metric; every workspace always gets a table. *(automated, fixture-scored)*

*Scoping note, added after 1.4.5 with the reason stated.* The scorer asserts the temporal
invariant for **bucketable** time axes (`dtype == Timestamp`, or a Temporal role on a numeric
column). CLF month names, RFC3164 timestamps with no year, and unresolved day/month order stay
`Utf8` on purpose: parsing them would invent dates, and the query layer cannot bucket text.
Asking the planner for a chart on such an axis produced three cards that validated cleanly and
then failed at the first draw. The planner now declines those axes, and the scorecard prints a
named "Known gap — text time axes" shortfall. **The labels still ask for those three time views**,
so they score as misses (96.6%, not 100%) until ingest parses CLF and RFC3164. The invariant was
scoped to what can be measured, not the target lowered to what the engine happens to do; the
gap stays visible in the score, in `fixtures/expected/README.md`, and in `m1.4-status.md` §11.

**AT-13 — Undo/redo.**
Given a sequence of 10 mixed commands (filters, moves, type changes, overrides), when
undoing all and redoing all, then state hashes match the originals at every step, and
undo depth survives app restart (journal). *(automated + device)*

*1.4.7 note.* The type changes in that mixed run are now real commands:
`ChangeComponentType` is deterministic (the profile is the only input, ties break by field
name), runs on a clone, validates the whole result before committing, and either bumps one
revision or changes nothing. That makes it journal-friendly for M1.5's undo/redo stack; the
stack itself, and the "moves" and "overrides" commands in this test, are still owed.

*1.5.1 note.* The automated half of that debt is now paid: `MoveComponent`,
`OverrideFieldType` and `OverrideFieldRole` are real commands, undo/redo are engine-owned
operations with bounded journal-backed stacks, and
`engine/crates/morphic-core/src/lib.rs::at13_ten_mixed_commands_undo_and_redo_match_every_state_hash`
checks ten mixed commands (filters, sort/search, a move, two type changes, two overrides)
against state hashes at every undo and redo step, with a separate restart test for undo depth.
Run 42863981801 (`7e59106`) made that automated half **6/6 CI-green**. The M1.5 kill-mid-save
chaos suite is now CI-green as part of 1.5.4 (`641c48c`, run 43057629282), but the **device** half
of AT-13 and the ≤ 500 ms reopen measurement are still owed, so AT-13 is not yet formally green.

**AT-14 — Manual layout adjustment.**
Given a workspace on a phone, when the user reorders components, changes a span/height,
and switches a bar chart to a line chart (compatible binding), then changes persist across
reopen, are undoable, and incompatible type switches are either prevented or
validator-rejected with no state change. *(device)*

*1.5.2 note.* The automated half of AT-14 is now paid: `MoveComponent` reorders the persisted
layout, `ResizeComponent` writes closed-vocabulary `layout.hints`, the runtime offers a long-press
drag handle and a pinch-free span/height menu, and phone focus mode stays view-only. Rust tests
prove hints survive reopen and undo; Dart widget tests prove the gesture, menu command, hint
geometry and focus mode. Run 42873440886 (`6752d0d`) is **6/6 CI-green**. Incompatible type
switches were already validator-rejected in 1.4.7. The **device** half is still owed, so AT-14
is not yet formally green.

**AT-15 — Library lifecycle.**
Given ≥ 3 workspaces, when renaming, duplicating, and deleting, then the library reflects
changes immediately, duplication shares the dataset (no file duplication on disk), and
deletion never removes a dataset referenced elsewhere. *(automated)*

*1.5.3 note.* **Green** in CI run 42970337214 (`e87a7e6`). The Rust test
`rename_duplicate_and_delete_update_the_library_and_share_the_dataset` imports one workspace,
renames it, duplicates it twice into three library entries, asserts a single dataset directory
on disk, deletes the original and proves both surviving copies reopen non-degraded. Dart widget
tests prove the home menu sends rename/duplicate/delete through the bridge and reloads the list;
a cancelled dialog makes no call. AT-15 makes no device claim, so no physical-device half is owed.

**AT-16 — Missing source resilience.**
Given a workspace whose dataset snapshot is deleted/corrupted, when opened, then it opens
in degraded mode (definitions visible, clear recovery affordance); re-importing the same
content re-links by hash and restores full function. *(automated chaos)*

*1.5.3 note.* The automated half is **green** in the same run. Rust deletes the dataset file,
confirms `open_session` reports `degraded`, refuses a different file, then re-links the exact
original bytes by SHA-256 and confirms `metric_data` returns the row count again. The degraded
notice carries a **Restore source file** button, and wider screens also have an app-bar action;
compact screens keep the notice action without the duplicate, including for an empty component
list. If the document itself is absent, compact chrome retains the app-bar action as a fallback.
Dart widget tests cover these entry points, a rejected re-link and a healthy workspace. The
kill-mid-save / corrupted-index **chaos suite** is task 1.5.4.

*1.5.4 note.* **AT-16 is now green as an automated test.** `641c48c` / run **43057629282** has a
named chaos gate covering an interrupted `*.tmp` write, a torn trailing journal line, a revision
left in the journal before the document rename, an unreadable `workspace.json` quarantined for
diagnosis, a torn `library.json` rebuilt from the folders, and a legacy source migration whose
`workspace.pre-v1.json.bak` rollback copy is asserted. Startup recovery is reported to the UI
rather than performed silently. This is fault injection in CI, not a physical forced-kill run, and
makes no device claim; the nightly cron is wired but has not fired. See
[m1.5-status.md](m1.5-status.md) §6.

**AT-17 — User corrections.**
Given a misdetected field (e.g. numeric-looking ids typed as int), when the user overrides
type/role, then only affected components recompile, the override persists, and undo
restores the original inference. *(automated)*

*1.5.5 note.* **AT-17 is green as an automated test** (`dc8a38f` → `23513e0`, run
43024916235, 6/6 ✅). A long press on a table header opens a correction sheet that emits
`OverrideFieldType`, `OverrideFieldRole` or the additive v11 `ClearFieldOverride` command. Rust
applies the persisted `fieldOverrides` to the inferred profile, calls the real compiler once and
rebuilds only the bindings that read a corrected field; components that read no corrected field
stay byte-identical, layout/hints/titles/interaction state are untouched, and a corrected
average over a now-text field is repaired into a row count. Tests prove the override survives
`close_session` + reopen, that undo restores the original semantic `state_hash` (inference and
recompiled bindings together), and that clearing an override restores the inferred binding. See
[m1.5-status.md](m1.5-status.md) §5. This is an automated pass only: it makes no device claim.

*1.5.6 note.* The optional ◇ `.morphic` bundle export/import stretch row shipped CI-green at
`a8e42e4` / run **43070316539** (6/6 ✅). Rust verifies the manifest, workspace/schema identity,
dataset count, byte counts and SHA-256 source hashes before any write; Flutter exports through an
injectable path/byte-sink seam and imports through the existing picker seam. No acceptance test is
attached to this stretch row, it makes no device claim, and it does not change any AT-13…AT-18
status or the M1.5 exit. See [m1.5-status.md](m1.5-status.md) §8.

*1.6.4 note.* Four bundled sample datasets and an empty-library first-run suggestion shipped
CI-green at `354f1ad` / run **43100359669** (6/6 ✅). No acceptance test is attached to this
M1.6 task; it makes no device claim and does not change AT-18 or any milestone exit. See
[m1.6-status.md](m1.6-status.md) §2.

*1.6.5 note.* Empty/error surfaces gained shared recovery copy and actionable scoped filter
clearing. The final code tip `23d41b9` / run **43283304890** is CI-green (6/6). This improves
some AT-11 states but did not at the time supply golden coverage of all five components;
AT-11 remained partial. It did not satisfy AT-18 or change any milestone exit. See
[m1.6-status.md](m1.6-status.md) §3.

*1.6.1 note.* Readable, font-loaded goldens now include all five component families and the
key screens in both themes; `3cc9edf` / run **43367563320** passed 80 live golden tests against
82 PNGs. They do not yet cover the full AT-11 matrix: loading, empty-after-filter and
binding-error images are not established for every component in both themes. AT-11 remains partial. The new theme-pair contrast checks and existing 1.3× chart
images give AT-18 partial evidence, but do not prove the full responsive/target/contrast matrix
or the TalkBack vertical slice. No milestone exit is implied. See
[m1.6-status.md](m1.6-status.md) §§4, 6.

*1.6.2 note.* Compact focus, medium flow, expanded rail and representative portrait/landscape
1.3× images are now covered by widget tests and live goldens; `ec57a26` / run **43381823333**
passed all six jobs. Inspection details use bottom/side/rail presentation; editing filters and
field corrections still uses modal bottom sheets. Some long labels can be abbreviated, so
these examples do not prove the full no-clipping matrix. AT-18 remains **partial** pending a
complete responsive, ≥48 dp target and contrast audit plus the TalkBack vertical slice; the
emulator smoke is not physical-device evidence. See [m1.6-status.md](m1.6-status.md) §§5–6.

*1.6.3 in progress.* Table rows and sort/filter controls gained semantic labels, state and
48 dp target handling, including short viewports. Metrics and interactive line/timeline charts
expose summaries; chart keyboard adjustment, legend controls and timeline preview/activation
are exercised in host tests. The [checklist](../engineering/accessibility-checklist.md) is
unsigned: the full responsive/no-clipping/target/contrast matrix and physical-device TalkBack
vertical slice remain unverified. The emulator log for `4e92e72` exposed a pre-existing
field/value mismatch when a binding reorders source columns. The correction in `6773f4c` /
**43396617222** passed all six jobs, including 617 behavioral tests, 106 **live** golden tests
and a sample field/value assertion on two emulator pages. An additional ready-state host matrix
is being added; its results and the complete audit remain outstanding. AT-18 is **partial**;
no milestone exit is implied.

**AT-18 — Responsive & accessibility.**
Given compact/medium/expanded widths and text scale 1.3, then layouts follow the design
rules (focus mode on phones, no clipped text — goldens), all targets ≥ 48 dp, contrast
token tests pass, and TalkBack completes the vertical slice with meaningful summaries.
*(golden + manual)*

**AT-19 — Release artifact.**
Given the tagged release build, when the signed per-ABI APK is installed on low/mid/
flagship devices (incl. a 16 KB-page device/emulator), then it installs, passes the AT-01
smoke offline, and native libs pass alignment checks. *(manual + CI)*

---

## Reporting

Acceptance evidence is summarized in [phase-1-standing-report.md](phase-1-standing-report.md)
and the individual milestone status reports. The originally proposed companion
`acceptance-status.md` has not been created. MVP exit requires **all 19 green** with (H)
thresholds either met or formally re-planned with recorded evidence and user visibility.
