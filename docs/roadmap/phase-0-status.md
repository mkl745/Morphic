# Phase 0 — Execution Status

**Executed 2026-11-05 · Result: foundation built, CI fully green, Android APK produced, and the
Dart↔Rust PoC verified running on an Android emulator.**

This records what was actually built and verified (spec §21: no overclaiming). The
[execution plan](phase-0-foundation.md) is the checklist; this is the outcome.

## Verified in CI (GitHub Actions is the build environment)

| Check | Result |
|---|---|
| Rust `cargo fmt` + `clippy` + `cargo test --workspace` | ✅ green |
| Schema + registry artifact export & drift gate | ✅ green |
| Dart `flutter analyze` + `flutter test` (widget + contrast tests) | ✅ green |
| Android native libs (arm64-v8a, armeabi-v7a, x86_64) | ✅ built |
| **16 KB page-alignment verification** | ✅ passed |
| Android debug APK (Flutter + Rust engine) | ✅ built (CI artifact `morphic-debug-apk`) |
| **Emulator runtime smoke** (install → launch → FFI → PoC) | ✅ passed on API-30 x86_64 |

The Dart↔Rust proof of concept is real **and verified at runtime on an emulator**: the CI
smoke installs the APK, launches it, confirms the home screen shows the live Rust engine
version over FFI, then taps "Run proof of concept" and confirms the Rust-computed CSV profile
renders on-device (`POC_OK … 12 rows`). The engine's vertical slice (CSV → analyze → validated
UI schema → save → reopen) is additionally covered by Rust tests.

> CI note: the `reactivecircus/android-emulator-runner` action failed to boot silently on these
> runners, so the smoke boots the emulator manually (sdkmanager → avdmanager → emulator → adb)
> with full logging, and drives the UI via `uiautomator` + `tools/tap_poc.py`.

## What exists now

- **9 Rust crates** (`engine/crates/*` + `apps/morphic_flutter/rust` bridge): model, ingest
  (CSV), semantic, query (types), schema (UI Schema v1.0 + validation + export), compiler
  (deterministic planner), workspace (atomic store + recovery), core (facade), bridge (C ABI).
- **Flutter app**: home / proof-of-concept / workspace / settings screens, design tokens,
  `dart:ffi` bridge with a fake for tests, widget tests + a 4.5:1 contrast gate.
- **CI/CD**: `ci.yml` (5 jobs incl. emulator runtime smoke), `release.yml` (signed when secrets
  set), `nightly.yml` (audit/deny + full release tests + perf baseline), dependabot, PR template.
- **Tooling**: `tools/build_android_native.sh`, `tools/check_alignment.py`, `tools/tap_poc.py`.
- **Fixture corpus v1**: `fixtures/` (valid + malformed CSV/JSON/log) with `manifest.json`,
  loaded by ingestion tests (grows each milestone).
- **Perf skeleton**: criterion CSV-parse throughput bench (`cargo bench -p morphic-ingest`);
  the Dart frame-timing collector + on-device harness are M1.1.

## Environment-driven adaptations (documented, not silent)

The sandbox reaches only GitHub / npm / PyPI — not crates.io, pub.dev, or the Flutter CDN —
and has no local toolchains. Therefore:
1. **CI is the build/test environment**; logs/artifacts that redirect to blocked CDNs are
   surfaced back via **commit comments** (GitHub API is reachable).
2. **Bridge PoC is a hand-written C ABI** over `dart:ffi` (ADR-0002 addendum). frb + cargokit
   (needs codegen) is the first task of M1.1.
3. **Android scaffolding is generated in CI** (`flutter create` + copy); committed once stable.
4. Phase 0 Flutter uses minimal deps (Flutter + `ffi` + `path_provider`) and Navigator routes;
   go_router + Riverpod 3 land in M1.1.

## Known gaps / honest limitations (tracked, not hidden)

- Schema JSON artifacts (`schemas/morphic_ui_schema_v1.json`, `schemas/registry_v1.json`)
  are committed and drift-gated against the Rust types in CI.
- `query`/`compiler` are intentionally minimal (types + a few real rules); full operators and
  planner are M1.3/M1.4. Stubs are labeled, not presented as complete.
- The APK is a **debug** build (large, 3 ABIs). Release per-ABI size optimization is M1.7.
- Runtime smoke verifies boot + FFI + CSV-profile PoC on an emulator. Process-death/relaunch
  recovery and airplane-mode checks are exercised by Rust recovery tests now and get an
  on-device pass in M1.5. Physical-device (not just emulator) verification is recommended
  before any store submission.

## Next

**M1.1 — production integration + vertical slice**: frb + cargokit bridge, go_router,
Riverpod 3, file_picker, real CSV ingestion hardening, and the first interactive components.
See [phase-1-mvp-plan.md](phase-1-mvp-plan.md).
