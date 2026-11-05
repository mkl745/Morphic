# ADR-0006 — UI Schema: Rust types are the source of truth; JSON Schema is exported

## Context
Spec §6 requires a formal, versioned, strictly validated UI schema; spec §2.3 forbids
generative code. The schema must serve three consumers: the Rust compiler (produces),
the Rust validator (gates), and the Dart runtime (interprets) — plus future AI providers.

## Decision
Define the schema as **Rust types in `morphic-schema`** (serde, deny-unknown-fields,
tagged unions per component binding). Export **JSON Schema draft 2020-12 via `schemars`**
to `schemas/morphic_ui_schema_v1.json` as a CI-drift-checked artifact for docs, external
tooling, and AI output pre-checks. Validation is the 5-pass pipeline in
[03-ui-schema.md](../architecture/03-ui-schema.md): structural → registry → binding →
resources → referential. The **component registry manifest** is exported from the same
types; Dart contract tests assert builder coverage. Migrations are pure functions with
golden fixtures.

## Alternatives
- **JSON Schema file as source of truth, codegen to Rust/Dart** — rejected: binding-level
  semantic checks (field exists, type-compatible aggregation) can't live in JSON Schema
  anyway; two-stage codegen adds tooling without removing the Rust validation pass.
- **Protobuf/flatbuffers schema** — efficient, but the doc must be human-diffable JSON on
  disk (persistence, debugging, future sharing); binary formats stay for dataset snapshots.
- **Free-form JSON validated ad hoc** — rejected: closed-world typing is the security model.

## Consequences
- One definition, three consumers, zero drift (CI gates both exports).
- AI integration in P2 is cheap: generate candidate JSON → jsonschema pre-check → typed
  decode → same 5 passes. Nothing AI-produced bypasses validation.
- Cost: schema evolution requires touching Rust types + regenerating artifacts + migration
  fixtures — this friction is intentional (the schema is a public contract).
- `jsonschema` crate used only at trust boundaries for raw external JSON (P2); internal
  path is typed serde (faster, better errors).
