# ADR-0009 — Deterministic intelligence first; AI behind a provider trait (Phase 2)

## Context
Spec §9/§13: MVP must not require a local LLM; deterministic engines handle parsing, stats,
filtering; AI is for interpretation, recommendations, NL. Spec §2.3/§12: no generative code,
prompt-injection awareness, provenance.

## Decision
Phase 1 ships a **`DeterministicProvider`** implementing the compiler's
`IntelligenceProvider` trait: transparent condition→template planning rules with
confidence + evidence on every inference, and human-readable explanations per component.
Phase 2 evaluates **llama.cpp** (quantized small models, e.g. 1–3B class) vs **ONNX Runtime**
for on-device inference, plus optional consented cloud providers. All providers emit
*suggestions/schema candidates* that pass the identical 5-pass validation; NL commands
compile to the same typed `Command` set as gestures. No model is downloaded or executed in
MVP; the app has no network code path.

## Alternatives
- **Local LLM in MVP** — rejected: model size/latency/quality on mid-range phones would
  dominate the schedule and blur the hypothesis test (is the *engine* good, or the model?).
- **Cloud-first AI** — rejected: violates local-first principle and privacy stance.
- **AI-generated Flutter code** — rejected permanently by spec §2.3 (security, persistence,
  versioning). The schema is the only generative surface.

## Consequences
- MVP quality is fully reproducible and fixture-scoreable (rule table is data + tests).
- The deterministic path remains the offline fallback forever; AI becomes an enhancer that
  must *beat* it on selection-accuracy metrics to ship.
- Phase 2 work is cleanly scoped: provider trait impl + model runtime + consent UX +
  injection-hardened prompting — no architectural change.
- Explanation objects exist from day one, so "Explain why this visualization is useful"
  works deterministically before any LLM exists.
