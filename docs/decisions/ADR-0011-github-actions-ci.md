# ADR-0011 — GitHub Actions: CI, drift gates, signed releases, nightly quality

## Context
The user explicitly wants GitHub Actions for builds. The repo has two toolchains (Flutter,
Rust + Android NDK) and generated artifacts (frb glue, JSON Schema, registry manifest) that
must never drift. Releases must be reproducible and signed.

## Decision
Three workflows + dependabot (full design: [ci-cd.md](../engineering/ci-cd.md)):
1. **`ci.yml`** (PR + push): Rust fmt/clippy/test (workspace, host) → schema/registry export
   drift gate → frb codegen drift gate → Dart analyze/test (host-built bridge lib) →
   Android assembleDebug (artifact upload) + 16 KB alignment check. All checks required.
2. **`release.yml`** (tag `v*`): version-from-tag check → signed AAB + APKs (keystore from
   encrypted secrets) → GitHub Release with artifacts + checksums.
3. **`nightly.yml`**: emulator integration tests (API 36 + API 24), perf harness run with
   trend storage, cargo-audit/cargo-deny, parser fuzz smoke, dependency freshness report.
Pinned toolchains (Flutter version, rust-toolchain.toml, NDK via cargokit), Actions pinned
to commit SHAs, aggressive caching (cargo, pub, gradle).

## Alternatives
- **Codemagic/Bitrise** — capable Flutter CI, but the repo lives on GitHub, Actions is free
  for public repos and sufficient; no reason to add a vendor.
- **Build Rust separately, commit .so binaries** — rejected: binary blobs in git, alignment
  and ABI drift risk; cargokit builds in-pipeline reproducibly.
- **Run codegen in CI without committing output** — rejected: non-hermetic PRs; committed
  output + drift gate gives reviewable diffs and offline builds.

## Consequences
- Every PR proves: engine tests, app tests, generated-artifact freshness, and a bootable
  Android build. "It works on my machine" cannot merge.
- Signing secrets live only in GitHub encrypted secrets (never in repo/chat); release
  reproducibility documented per tag.
- Cost: CI minutes for 3-ABI builds; mitigated by caching and debug-only PR builds
  (release builds on tags/nightly).
- Emulator tests are nightly, not per-PR (runtime cost); per-PR widget/integration-on-host
  coverage keeps the feedback loop fast.
