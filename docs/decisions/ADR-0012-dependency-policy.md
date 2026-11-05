# ADR-0012 — Dependency policy: minimal, pinned, audited, license-allowlisted

## Context
A long-lived product with native code on users' phones carries supply-chain responsibility.
Spec §18 warns against speculative infrastructure; every dependency is attack surface,
build time, and upgrade debt.

## Decision
1. **Admission rule**: a dependency must (a) have an immediate MVP consumer, (b) be
   actively maintained, (c) carry an allowlisted license (MIT / Apache-2.0 / BSD / ISC /
   OFL for fonts), (d) not duplicate something we already have. Recorded with justification
   + exit path in [dependency-strategy.md](../engineering/dependency-strategy.md).
2. **Pinning**: `pubspec.lock` and `Cargo.lock` committed; toolchains pinned
   (`rust-toolchain.toml`, Flutter version in CI); Actions pinned to SHAs.
3. **Updates**: dependabot weekly (grouped minor/patch), monthly review ritual; major
   upgrades are deliberate PRs with test evidence. frb pub+cargo versions upgrade together.
4. **Audit**: `cargo-deny` (licenses, bans, advisories) + `cargo-audit` nightly;
   `dart pub outdated` report; fuzzing for parsers.
5. **No vendoring** initially; lockfiles + pinned toolchains give reproducibility. Revisit
   if a critical crate becomes unmaintained (fork policy: fork under the org, document).

## Alternatives
- **Maximal reuse (chart libs, UI kits, ORMs)** — rejected: fights the design system and
  renderer abstraction; each "convenience" lib we audited adds more surface than it saves.
- **Zero-dependency purism** — rejected: rewriting CSV/JSON/regex/FFI plumbing would be
  negligence, not craftsmanship.

## Consequences
- ~20 Dart deps and ~25 Rust crates total for MVP (see strategy doc) — small enough to
  actually review.
- License compliance is CI-enforced, not remembered.
- Adding a dependency requires editing the strategy doc in the same PR — friction by design.
