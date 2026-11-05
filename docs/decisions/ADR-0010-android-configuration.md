# ADR-0010 — Android configuration: Flutter 3.47, SDK 36/24, NDK r28+, 16 KB pages

## Context
Verified against public sources on 2026-11-05: Flutter 3.47 is current stable (3.50 expected
Nov 2026); its Android matrix is compileSdk/targetSdk 36, minSdk 24, Java 17, AGP 9.1,
Gradle 9.3.1, KGP 2.4. Google Play requires target API 36 for new apps/updates since
2026-08-31 and 16 KB page-size compatibility for apps with native code. We ship native Rust
libraries, so alignment is a hard requirement, not a nice-to-have.

## Decision
Pin **Flutter 3.47.x** (exact patch in Phase 0, recorded in `docs/engineering/toolchain.lock.md`
and CI). Use Flutter's vended SDK variables (`flutter.compileSdkVersion` etc.) rather than
hardcoding numbers. minSdk 24. NDK **r28+** via cargokit; additionally force
`-Wl,-z,max-page-size=16384` on Rust cdylib links and **verify ELF alignment in CI**.
ABIs: arm64-v8a, armeabi-v7a, x86_64; distribute as App Bundle (per-ABI splits) + universal
APK artifact for sideloading/testing. Rust: current stable, edition 2024, pinned via
`rust-toolchain.toml`. Application id `dev.morphic.app` (placeholder, assumption A1).

## Alternatives
- **Track Flutter master/beta** — rejected: quarterly stable cadence + hotfix-only-latest
  policy means stable pins with planned quarterly upgrades are the sane path.
- **minSdk 21/23** — rejected: below Flutter's floor; no audience benefit.
- **arm64-only** — tempting for size, but excludes cheap 32-bit devices still common in
  target markets; App Bundle makes multi-ABI nearly free for users. Revisit with data.

## Consequences
- Play-compliant from the first upload; CI alignment check prevents silent regressions when
  NDK/frb/cargokit versions change.
- Flutter 3.50 upgrade is a scheduled task after it ships and stabilizes (one minor per
  quarter, dedicated upgrade PR with full test suite + goldens).
- 32-bit ABI keeps Rust compile times ~3× per release build; CI caches mitigate.
