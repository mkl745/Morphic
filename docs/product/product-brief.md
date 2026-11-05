# MORPHIC — Product Brief (distilled)

> Full vision: [morphic-spec.md](morphic-spec.md). This brief is the working summary the
> engineering plans refer to.

## One-liner

A local-first engine that turns arbitrary user data into a persistent, interactive,
*generated* workspace — the interface emerges from the information.

## The hypothesis we must prove (Phase 1)

> A user can import an unfamiliar CSV or JSON dataset and receive a **useful, interactive
> workspace without manually designing a dashboard** — in seconds, fully offline — and that
> workspace can be saved, reopened, and adjusted.

Everything in Phase 1 exists to test this hypothesis. Everything else waits.

## What MORPHIC is not

- Not a dashboard builder (no manual grid-first design flow).
- Not a chat app with charts attached (NL is a *command surface over trusted operations*, Phase 2).
- Not a code generator (AI never emits executable UI code; it emits validated schema).
- Not a cloud product (cloud AI is optional, explicit, consented; core is offline).
- Not a WebView app (Flutter presentation, Rust engine, native rendering only when measured).

## Primary users (initial wedge)

Software engineers, data analysts, and researchers working with heterogeneous files:
logs, CSV exports, JSON dumps, notes. The **log explorer** and **unknown-dataset explorer**
scenarios (spec §3 A & D) are the MVP wedge; research/knowledge workspaces follow in Phase 4.

## MVP scope (Phase 1)

**In:** CSV / JSON / TXT-basic-logs import · streaming parse · schema & type detection ·
deterministic semantic profiling · UI-schema generation with explanations · metric cards,
data tables, bar charts, line charts, timelines · filtering/sorting/search · save/reopen/
rename/duplicate · manual layout adjustment (reorder/resize/switch viz) · undo/redo ·
adaptive phone-first layouts, tablet-aware · dark/light themes · sample datasets ·
fully offline.

**Out (deferred, with seams in place):** natural-language commands (P2) · local/cloud LLMs
(P2) · relationship graphs, scatter/pie, hierarchical explorer (P2/P4) · freeform infinite
canvas (P2/P3) · JSONL-as-format, XML, Markdown, SQLite, Parquet (P4; JSONL *parsing* is
trivially included early because logs need it) · templates (P1 stretch → P4) · share-to-app
(P1 stretch) · workspace export bundle (P1 stretch) · Vulkan/Metal (P3+, benchmark-gated) ·
plugins, sharing, cloud sync (P5) · iOS release (architecture ready, release in P4).

## Success metrics (from spec §16, instrumented from day one)

1. Time: import → usable workspace.
2. % of generated workspaces accepted without major changes.
3. % of workspaces saved / reopened / reused.
4. Interactions per workspace; time-to-find-information (UX studies).
5. Schema-detection and visualization-selection accuracy (fixture-scored).
6. User correction frequency; crash-free sessions.

Initial performance targets are **hypotheses** tracked in
[quality-and-performance.md](../engineering/quality-and-performance.md), validated on a
low/mid/flagship device matrix — never advertised before measurement.

## Standing assumptions (changeable, recorded here so nobody guesses)

| # | Assumption |
|---|---|
| A1 | Android application id `dev.morphic.app` (placeholder; finalize before Play listing). |
| A2 | MVP is single-user, no accounts, no network calls at all (privacy mode is the default mode). |
| A3 | English UI only in MVP; localization seams (intl) kept clean for later. |
| A4 | Imported files are **copied** into app-private storage (content-addressed). We do not depend on persistable SAF permissions. |
| A5 | Portrait-first phone UX; landscape and tablets get adaptive layouts, not scaled-down desktop. |
| A6 | One dataset per workspace in MVP; multi-source workspaces arrive with the join engine (P4). Schema already models a list of dataset refs. |
| A7 | Deterministic compiler v1 is rule-based and explainable; it is the fallback path forever, even after AI arrives. |
