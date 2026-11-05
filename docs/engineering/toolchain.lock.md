# Toolchain Lock

Resolved toolchain versions for reproducible builds. **Filled in from the first green CI
run** — the sandbox has no local toolchains, so CI is the source of truth.

| Tool | Phase 0 setting | Resolved (from CI) |
|---|---|---|
| Flutter | `channel: stable` | _pending first green run_ |
| Dart | bundled with Flutter | _pending_ |
| Rust | `channel = stable` (rust-toolchain.toml) | _pending_ |
| Android compileSdk / targetSdk | Flutter-vended (36) | _pending_ |
| Android minSdk | Flutter-vended (24) | _pending_ |
| NDK | runner preinstalled (16 KB forced via linker flag) | _pending_ |
| Java | 17 (temurin) | 17 |
| Gradle / AGP / KGP | Flutter-vended | _pending_ |

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
