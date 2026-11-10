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
The **device** half of AT-13, the M1.5 kill-mid-save chaos suite and the ≤500 ms reopen
measurement are still owed, so AT-13 is not yet formally green.

**AT-14 — Manual layout adjustment.**
Given a workspace on a phone, when the user reorders components, changes a span/height,
and switches a bar chart to a line chart (compatible binding), then changes persist across
reopen, are undoable, and incompatible type switches are either prevented or
validator-rejected with no state change. *(device)*

**AT-15 — Library lifecycle.**
Given ≥ 3 workspaces, when renaming, duplicating, and deleting, then the library reflects
changes immediately, duplication shares the dataset (no file duplication on disk), and
deletion never removes a dataset referenced elsewhere. *(automated)*

**AT-16 — Missing source resilience.**
Given a workspace whose dataset snapshot is deleted/corrupted, when opened, then it opens
in degraded mode (definitions visible, clear recovery affordance); re-importing the same
content re-links by hash and restores full function. *(automated chaos)*

**AT-17 — User corrections.**
Given a misdetected field (e.g. numeric-looking ids typed as int), when the user overrides
type/role, then only affected components recompile, the override persists, and undo
restores the original inference. *(automated)*

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

Each milestone updates a status table (pass/fail/not-yet) in this file's companion
`acceptance-status.md` (created at M1.1). MVP exit requires **all 19 green** with (H)
thresholds either met or formally re-planned with recorded evidence and user visibility.
