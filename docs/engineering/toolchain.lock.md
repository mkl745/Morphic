# Toolchain Lock

Resolved toolchain versions for reproducible builds. **Filled in from the first green CI
run** — the sandbox has no local toolchains, so CI is the source of truth.

Resolved from the first green CI runs (2026-11-05):

| Tool | Phase 0 setting | Resolved (from CI) |
|---|---|---|
| Flutter | `channel: stable` | **3.47.9** (rev c197ca5199, 2026-10-29) |
| Dart | bundled with Flutter | bundled with Flutter 3.47.9 |
| Rust | `channel = stable` (rust-toolchain.toml) | **1.99.1** (58cf8f9c3, 2026-10-13) |
| Android compileSdk / targetSdk | Flutter-vended (36) | 36 |
| Android minSdk | Flutter-vended (24) | 24 |
| NDK | runner preinstalled (16 KB forced via linker flag) | runner default; alignment verified |
| Java | 17 (temurin) | 17 |
| Gradle / AGP / KGP | Flutter-vended | Flutter 3.47.9 matrix |

**Hard-pin follow-up:** move `rust-toolchain.toml` to `channel = "1.99.1"` and CI to
`flutter-version: 3.47.9` (with the rust-toolchain/action alias kept consistent) so builds
are byte-reproducible. Kept on `stable` for the first green runs to avoid toolchain-alias
mismatches; the resolved versions above are the reference.

## Pinning policy

Once the first CI run is green, record the exact resolved versions here and pin them:
- `rust-toolchain.toml` → exact Rust channel.
- CI `subosito/flutter-action` → exact `flutter-version`.
- NDK → explicit version in the native build script.

This converts "stable" (moving) into a reproducible lock. Upgrades become deliberate PRs
(ADR-0012 upgrade ritual).

## Phase 0 adaptations (environment-driven)

The build sandbox reaches only GitHub / npm / PyPI — **not** crates.io, pub.dev, or the
Flutter CDN — and has no local Flutter/Rust toolchain. Consequences:
- **CI is the build/test environment.** All compilation, codegen, and packaging happen in
  GitHub Actions; artifacts (APK, schema JSON, formatted sources) are downloaded back.
- **Bridge PoC is a hand-written C ABI** over `dart:ffi` (ADR-0002 addendum); frb + cargokit
  (which need codegen) land in M1.1.
- **Android platform scaffolding is generated in CI** (`flutter create` + copy) because it
  cannot be produced locally; it is committed back once stabilized.
