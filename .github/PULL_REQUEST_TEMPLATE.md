## What & why

<!-- What does this change do, and which milestone/task does it belong to? -->

## Checklist

- [ ] Engine logic lives in Rust crates; Dart holds no authoritative data logic.
- [ ] `cargo test --workspace` and `flutter test` pass locally or in CI.
- [ ] Generated artifacts (schemas, registry) regenerated if types changed.
- [ ] Contracts/docs updated if the FFI surface or UI schema changed.
- [ ] No placeholder functionality presented as complete (spec §21).
- [ ] Scope guardrails respected (no reserved components / no MVP-deferred features).

## Evidence

<!-- Test output, screenshots, perf numbers, or demo steps. -->
