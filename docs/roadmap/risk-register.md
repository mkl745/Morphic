# Risk Register

Reviewed at every milestone exit. L = likelihood, I = impact (1–5). Trigger = the observable
signal that activates the mitigation. Owner: the agent proposes, the user decides on
scope-affecting mitigations.

| # | Risk | L | I | Mitigation (planned) | Trigger / response |
|---|---|---|---|---|---|
| R1 | **frb/cargokit/NDK toolchain friction** (build breaks on version bumps, 16 KB alignment regressions) | 3 | 4 | Pin everything; CI alignment check; drift gates; upgrade ritual; bridge crate isolates frb | CI android-build fails → freeze versions, fix forward in dedicated PR; never block engine work (host tests keep running) |
| R2 | **Vertical slice slips** (M1.1 too big) | 3 | 5 | M1.1 is deliberately narrow (CSV only, 2 components); breadth deferred; stubs labeled | M1.1 > ~2× estimate → cut line_chart from slice (already optional), ship metric+table proof first |
| R3 | **Large-file memory pressure on low-end devices** | 3 | 4 | Streaming parse, memory-estimate guard, soft row caps, paged UI, snapshot reopen | OOM/abort in soak → lower default caps with clear UX; sampling mode proposal (P1.5 decision) |
| R4 | **Chart/table jank in Flutter** | 2 | 4 | Fixed-extent slivers, repaint boundaries, immutable scenes, overlay layers, frame harness from M1.1 | p95 budgets missed → optimize per rendering playbook; native backend only via Phase 3 gate (not a panic move) |
| R5 | **Schema churn** (v1.0 design misses needs found in M1.3–1.5) | 3 | 3 | Additive-minor policy + migration harness from Phase 0; goldens catch breaks | Breaking change needed → ADR + migration + fixtures before merge; no silent format drift |
| R6 | **Planner quality below usefulness bar** (generated workspaces feel generic) | 3 | 5 | Fixture-scored selection accuracy; explanations force honest rules; UX studies at M1.6 | Accuracy < 85% or UX rejection → iterate rule table with corpus evidence; this is the core hypothesis, treat as top priority |
| R7 | **SAF/file_picker quirks across OEMs** | 3 | 3 | Copy-into-storage immediately; formatHint override; samples+clipboard paths bypass picker | Device-specific failures → `PlatformFileSource` seam allows swapping to file_selector/channel without engine changes |
| R8 | **CI minutes/cost blowup** (3-ABI NDK builds) | 2 | 2 | Debug-only PR builds, aggressive caching, needs-gating, nightly heavy jobs | Queue times/costs rise → move android-build to nightly + pre-merge label opt-in |
| R9 | **Scope creep from the vision** (canvas/AI/graphs pulled into MVP) | 4 | 4 | Scope guardrails in plan; reserved registry ids; milestone reviews check the "not in MVP" list | Any PR touching reserved areas → reject or re-plan explicitly with user |
| R10 | **Undo/journal corruption** | 2 | 4 | Atomic writes, checksums, compaction tests, chaos suite nightly | Recovery fails in chaos → journal format versioning + rebuild-from-snapshot fallback (degraded but safe) |
| R11 | **Solo-maintainer bus factor / doc drift** | 3 | 3 | ADRs, crate READMEs, contracts-as-tests, drift gates; docs updated in same PR as code | Doc/test mismatch in review → block merge |
| R12 | **Flutter quarterly upgrades break goldens/behavior** (3.50 lands during Phase 1) | 3 | 2 | Pin 3.47 through MVP; scheduled upgrade PR post-MVP with full suite | Upgrade PR red → defer; never upgrade mid-milestone |
| R13 | **App size creep** (fonts, 3 ABIs, Rust std) | 2 | 2 | Per-ABI splits, size audit at M1.7, font subsetting lever | > 40 MB per-ABI → subset fonts, LTO/strip check, revisit chrono/smallvec choices |
| R14 | **Prompt-injection surface arrives with P2 AI** | 2 | 5 | Architecture already separates data/instructions; validation gate; provenance chips; no network in MVP | P2 kickoff → threat-model review + injection test corpus before any provider ships |

## Watch items (not risks yet)

- Dart native assets / frb hooks maturation → may simplify cargokit later (ADR-0002).
- DuckDB/Arrow adoption triggers (ADR-0005) — revisit at P2 joins / P4 Parquet.
- 16 KB-only devices in the wild → ensure emulator coverage stays in nightly matrix.
