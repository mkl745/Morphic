# Phase 1 — MORPHIC MVP: Implementation Plan

Objective (spec §13): **prove the core hypothesis** — import an unfamiliar CSV/JSON file,
get a useful interactive workspace without designing anything, save it, reopen it, adjust it.
Fully offline. Flutter rendering only. Deterministic intelligence only.

Prerequisite: [Phase 0 exit criteria](phase-0-foundation.md) met.
Definition of done: [MVP acceptance tests](mvp-acceptance-tests.md) AT-01…AT-18 pass on the
device matrix, budgets validated or explicitly re-planned with evidence.

## Milestone map (strict dependency order; each ends with a demoable build)

```
M1.1 Vertical slice (CSV → workspace → save/reopen)   ← the critical proof, do FIRST
  └▶ M1.2 Format breadth (JSON, TXT/logs, robustness)
       └▶ M1.3 Interactivity (filter/sort/search everywhere)
            └▶ M1.4 Visualization completeness (5 components + planner v1)
                 └▶ M1.5 Workspace lifecycle (undo/redo, layout editing, recovery)
                      └▶ M1.6 Experience (design pass, responsive, a11y, samples)
                           └▶ M1.7 Hardening & release (perf, reliability, acceptance, signed build)
```

Sizes: S ≈ ½ day · M ≈ 1–2 days · L ≈ 3–5 days. Total ≈ 30–40 focused engineering days.
Stretch items are marked ◇ and never block a milestone exit.

---

## M1.1 — Vertical slice (the first proof of MORPHIC)

Execution status: [m1.1-status.md](m1.1-status.md).

**Goal:** one file, end to end, no breadth: `Import CSV → analyze → generate UI schema →
render interactive Flutter workspace → save → reopen` (spec §20's exact slice).

| # | Task | Size | Notes |
|---|---|---|---|
| 1.1.1 | `morphic-ingest`: real streaming CSV parser (delimiter/header sniffing, UTF-8 strict + chardetng fallback, quarantine policy, cancellation, progress events) | L | replaces PoC parser; property tests |
| 1.1.2 | `morphic-model` + `morphic-semantic`: column builders → Table; type ladder (bool/int/float/timestamp/string @95%); facts profile (nulls, distinct, min/max, top-K) | L | fixture-scored |
| 1.1.3 | `morphic-compiler` v0: rule table → WorkspaceDoc with metric_card + data_table (+ line_chart if temporal); explanations attached; validator passes 3–5 activated | L | insta goldens per fixture |
| 1.1.4 | Bridge: real `importFile`, `createWorkspace`, `snapshot`, `queryPage`, `metricData`, events; EngineController + ImportController wired | M | contract tests |
| 1.1.5 | Dart runtime v0: registry + `metric_card` + `data_table` widgets (paged sliver table, sticky header, horizontal scroll); adaptive flow layout; loading/empty/error states | L | widget + golden tests |
| 1.1.6 | `morphic-workspace`: real save/open/list with journal + recovery (from 0.4 skeleton); home shows real recents; reopen restores revision | M | kill/restore test |
| 1.1.7 | Import feature UI v0: file_picker → copy → progress (real events) → morph stages → workspace route | M | integration test (host) |

**Exit:** AT-01, AT-02, AT-09 (partial: table sort in M1.3) pass on a **physical** mid-range
device with committed evidence (`tools/device_smoke.sh`, see
[real-device-testing.md](../engineering/real-device-testing.md) — emulator runs do not count);
10 MB CSV → workspace ≤ 3 s measured on that device (or budget re-planned with data);
demo video/script.
**Demo:** airplane mode on; pick `fixtures/valid/sales.csv`; workspace appears with metric +
table; kill app; reopen from home — identical state.

## M1.2 — Format breadth & ingestion robustness

Execution status: [m1.2-status.md](m1.2-status.md).

| # | Task | Size | Notes |
|---|---|---|---|
| 1.2.1 | JSON parser: array-of-objects, single object, nested flattening (`a.b` paths, depth cap 4), bounded memory gate | L | nested fixtures |
| 1.2.2 | JSONL + TXT line datasets; log pattern library v1 (ISO-level, syslog, CLF, logfmt, fallback) with field extraction | L | log fixtures scored |
| 1.2.3 | Format sniffing consolidation + `formatHint` override UI; encoding edge cases (BOM, CRLF, latin-1, mixed) | M | malformed corpus green |
| 1.2.4 | Import UX: file facts card, quarantine report sheet, re-import with hint, cancel button; limits errors with human copy | M | |
| 1.2.5 | ◇ Clipboard import; ◇ share-to-Morphic intent (evaluate `share_handler`) | M | stretch |

**Exit:** AT-03, AT-04, AT-05 pass; malformed corpus never crashes (fuzz smoke clean);
every supported format produces a workspace or a *clear, actionable* error.

## M1.3 — Interactivity (the workspace becomes a tool)

| # | Task | Size | Notes |
|---|---|---|---|
| 1.3.1 | `morphic-query`: full plan execution (filter tree, search, stable sort w/ nulls policy, group/agg) + budgets + LRU cache | L | property tests: filter algebra, sort stability |
| 1.3.2 | Commands: SetGlobalFilter/SetComponentFilter/SetComponentSort/SetSearch; atomic batches; affected-component recomputation only | M | incremental-recompile test |
| 1.3.3 | Table interactions: column sort UI, per-column filter menu (type-aware), search field, row detail bottom sheet | L | widget tests |
| 1.3.4 | Global filter bar: chips, add/edit/remove, clear-all; metric-card tap → toggle its filter | M | |
| 1.3.5 | Cross-component consistency: one filter change updates all bound components from one engine revision (no torn state) | S | integration test |

**Exit:** AT-06, AT-07, AT-08 pass; filter+sort 100k×10 ≤ 150 ms engine-side measured;
no Dart-side data logic (review checklist).

## M1.4 — Visualization completeness & planner v1

| # | Task | Size | Notes |
|---|---|---|---|
| 1.4.1 | Scene contracts + `chartData` aggregation paths (top-N, time bucketing with auto-granularity, ≤2000 pts downsampling) | M | bench: aggregation latency |
| 1.4.2 | `bar_chart` painter + interactions (tap-to-filter, sort toggle, Other bucket) | M | goldens × themes × states |
| 1.4.3 | `line_chart` painter + scrub tooltip overlay, legend toggles (≤8 series) | L | goldens; frame-time harness |
| 1.4.4 | `timeline` painter: density buckets, severity lanes/colors, tap-bucket → time-range filter | L | log fixtures demo |
| 1.4.5 | Planner v1 final: full rule table (severity/temporal/dimension/measure logic), component cap 6, phone-aware composition; selection-accuracy scored vs `fixtures/expected/` | M | accuracy ≥ 85% on corpus (initial target) |
| 1.4.6 | "Why this view?" sheet rendering explanation objects (reason, evidence, confidence) | S | |
| 1.4.7 | `ChangeComponentType` with compatibility matrix + binding conversion | M | validator tests |

*Status, 2026-11-05:* **all seven M1.4 task rows are implemented**, ending with 1.4.7's
engine-authoritative conversion command. The exit criteria below are still not all met — see
[m1.4-status.md](m1.4-status.md) §13 for what remains.

**Exit:** AT-10, AT-11, AT-12 pass; all five components golden-covered; chart interaction
p95 ≤ 33 ms measured; every generated component explains itself.

## M1.5 — Workspace lifecycle & manual layout

| # | Task | Size | Notes |
|---|---|---|---|
| 1.5.1 | Undo/redo engine (stacks + journal compaction) + app bar controls + snackbars | M | AT-13 |
| 1.5.2 | Layout editing: drag-reorder (long-press), resize span/height via menu + pinch-free controls, focus mode on phones; hints persisted as commands | L | AT-14; widget tests |
| 1.5.3 | Rename/duplicate/delete workspaces; library management on home; degraded mode for missing datasets + re-link flow | M | AT-15, AT-16 |
| 1.5.4 | Autosave policy hardening: debounce + lifecycle flush; recovery UI after forced kill; migration backup path exercised | M | chaos tests nightly |
| 1.5.5 | Field corrections UI: override type/role from table header → targeted recompile | M | AT-17 |
| 1.5.6 | ◇ Workspace export/import `.morphic` bundle | M | stretch |

*Status, updated for 1.5.6:* **all six M1.5 task rows are done and CI-green**, including the
optional ◇1.5.6 stretch. 1.5.1 shipped undo/redo with 100-revision journal-bounded stacks,
app-bar controls and snackbars; 1.5.2 shipped long-press drag-reorder, pinch-free span/height
menus, phone focus mode and persisted `layout.hints`; 1.5.3 shipped home-library
rename/duplicate/delete and hash-verified degraded re-link; 1.5.4 shipped engine-owned startup
recovery, a 2 s checkpoint debounce plus lifecycle flush, the recovery UI, a migration rollback
copy and a named kill-mid-save chaos suite; 1.5.5 shipped a table-header field-correction sheet
backed by targeted recompilation; 1.5.6 shipped `.morphic` export/import as a self-contained
UTF-8 JSON envelope with a manifest, authoritative `WorkspaceDoc` and hash-verified hex source
bytes — not a ZIP, and with no new Cargo dependency. `API_VERSION` was **13** at the end of
M1.5 (`a8e42e4`, run 43070316539, 6/6 ✅, after the red `ee57c55` run, the `61817a2` rustfmt
bot push and the normal fix commit); 1.6.1 later raises it to **14**. AT-15, AT-16 and AT-17 are
green as automated tests; AT-13/AT-14 automated halves are green, but their device halves, AT-18,
reopen ≤ 500 ms and the other evidence gaps are still owed. The milestone exit is **unmet** — see
[m1.5-status.md](m1.5-status.md) for the CI chain and the remaining evidence. The chaos suite runs as a named gate in `ci.yml` and is also wired into
`nightly.yml`; the nightly cron itself has not fired yet because the workflow is not on `main`.

**Exit:** AT-13…AT-17 pass; kill-mid-save chaos suite green; reopen ≤ 500 ms measured.

## M1.6 — Experience pass (the product feels like MORPHIC)

| # | Task | Size | Notes |
|---|---|---|---|
| 1.6.1 | Design-system application sweep: home, import, workspace chrome, settings; dark/light parity; motion tokens (real-event morph stages, stagger ≤400 ms) | L | **done, CI-green**; goldens refreshed |
| 1.6.2 | Responsive: compact focus mode, medium two-column, expanded rail; landscape; text scale 1.3 goldens | L | **done, CI-green**; AT-18 remains partial |
| 1.6.3 | Accessibility pass: semantic summaries, focus order, targets, contrast, TalkBack on vertical slice | M | **in progress** — host coverage added; [checklist](../engineering/accessibility-checklist.md) not signed |
| 1.6.4 | Sample datasets (3–5 bundled: server logs, sales CSV, sensor JSON) + first-run suggestion | S | **done, CI-green** |
| 1.6.5 | Empty/error/edge copy sweep (every failure has human language + next action) | S | **done, CI-green** |
| 1.6.6 | ◇ Workspace templates ("keep this layout for future imports") — only if 1.5 lands early; else P4 | M | stretch |

*Status, updated for 1.6.2:* **4 of 6 M1.6 rows are implemented.** Task 1.6.4 shipped four
synthetic samples and first-run suggestions; 1.6.5 added shared recovery copy, distinct filter
scopes and retries. Task 1.6.1 applies dark/light themes, bundled fonts, real-event import
motion, the editable live workspace title and Settings details. Task 1.6.2 adds adaptive
workspace flow, opt-in compact focus, responsive inspection details and representative 1.3×
goldens. The bridge API remains **14**. Task 1.6.3 and optional ◇1.6.6 remain; these code rows
do not supply physical-device, complete accessibility or external UX evidence. See
[m1.6-status.md](m1.6-status.md) §§2–6.

**Exit:** full acceptance suite passes on low/mid devices; UX validation script run with
≥3 external people, findings logged; no screen violates token rules.

## M1.7 — Hardening, performance, release

| # | Task | Size | Notes |
|---|---|---|---|
| 1.7.1 | Device-matrix perf runs (low/mid/flagship); budgets validated or re-planned with evidence in perf-log.md | M | |
| 1.7.2 | Reliability week: fuzz overnight, chaos suite, storage-full simulation, 500-import soak, memory leak hunt | L | crash-free ≥ 99.5% dogfood |
| 1.7.3 | Size audit: per-ABI download ≤ 40 MB target; font subsetting if needed; R8/tree-shake check | S | |
| 1.7.4 | Release: version 0.1.0, CHANGELOG, signed AAB/APK via release.yml (secrets configured), GitHub Release, install-from-release smoke | M | AT-19 (release artifact installs & passes smoke) |
| 1.7.5 | Acceptance report: AT-01…AT-19 results + perf log + known limitations; Phase 2 proposal (NL commands + provider evaluation) | S | user sign-off |

**Exit = MVP DONE:** every acceptance test green, budgets evidenced, signed artifact
installable, limitations documented honestly (spec §21: no overclaiming).

---

## Scope guardrails (checked at every milestone review)

- No NL command bar, no model downloads, no network code (P2).
- No freeform canvas, no graph/scatter/pie components (P2/P4) — reserved ids stay reserved.
- No Vulkan/Metal, no platform views (P3 gate).
- No multi-dataset joins (P4) — schema shape already supports the future.
- If a task balloons: ship the smaller architecturally-compatible version and log the debt
  (spec §21), never silently expand scope.

## Working agreement per task (spec §21)

Implement → unit/property tests → run validation (`cargo test`, `flutter test`, analyzer) →
update crate README/doc if contracts changed → report limitations → demo evidence.
Every milestone ends with: green CI, a demoable build, **committed physical-device evidence**
([real-device-testing.md](../engineering/real-device-testing.md) — mandatory, emulator runs
are not sufficient), updated acceptance-test status, and a short "what we learned" note
feeding the next milestone.
