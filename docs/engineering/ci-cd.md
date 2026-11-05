# CI/CD — GitHub Actions Design

Implements [ADR-0011](../decisions/ADR-0011-github-actions-ci.md). Workflows are **created
during Phase 0 execution** (task 0.6); this is their contract. Repo: `mkl745/Morphic`.

## 1. Pipeline overview

```
PR / push ──▶ ci.yml ──────────────────────────────────────────────▶ required checks
              ├─ rust-quality     fmt · clippy -D warnings · cargo test --workspace
              ├─ artifacts-drift  regenerate schemas + registry + frb glue → git diff --exit-code
              ├─ dart-quality     flutter analyze · flutter test (host-built bridge cdylib)
              └─ android-build    assembleDebug (3 ABIs) → 16KB alignment check → upload APK

tag v* ─────▶ release.yml ─────────────────────────────────────────▶ GitHub Release
              ├─ verify tag == pubspec version
              ├─ build signed AAB + per-ABI/universal APKs
              ├─ alignment + artifact checksums
              └─ attach to Release (keystore from encrypted secrets)

schedule ───▶ nightly.yml ─────────────────────────────────────────▶ quality trends
              ├─ emulator integration tests (API 36, API 24)
              ├─ perf harness (scripted workloads) → JSON metrics → trend artifact
              ├─ cargo-audit + cargo-deny (licenses/advisories/bans)
              ├─ parser fuzz smoke (10 min/target)
              └─ pub outdated / cargo upgrade --dry-run report
```

## 2. Job details & caching

| Job | Runner | Key steps | Caches |
|---|---|---|---|
| rust-quality | ubuntu-latest | toolchain from `rust-toolchain.toml`; `cargo fmt --check`, `clippy --workspace --all-targets -D warnings`, `cargo test --workspace` | Swatinem/rust-cache (shared key across jobs) |
| artifacts-drift | ubuntu-latest | `cargo run -p morphic-schema --bin export` → diff `schemas/`; `flutter_rust_bridge_codegen generate` → diff `lib/bridge/` + `rust/src/frb_generated.rs` | cargo + pub + codegen binary |
| dart-quality | ubuntu-latest | `cargo build -p morphic-bridge` (host cdylib for tests) → `flutter analyze` → `flutter test --coverage` | pub, cargo |
| android-build | ubuntu-latest | setup-java 17 → setup-android (SDK 36, NDK r28+) → cargokit builds via `flutter build apk --debug` → `tools/check_alignment.py` on every `.so` → upload artifact | gradle, cargo (per-ABI), pub |
| emulator (nightly) | ubuntu-latest, KVM | reactivecircus/android-emulator-runner: API 36 x86_64 + API 24 → `flutter test integration_test` | gradle, cargo, AVD snapshot |
| release | ubuntu-latest | decode keystore secret → `flutter build appbundle --release` + `apk --release` → verify alignment → checksums → gh-release | same |

Rules:
- **Concurrency**: cancel-in-progress on PR branches; never on tag builds.
- **Pinning**: Flutter version explicit; Actions pinned to commit SHAs; NDK version explicit.
- **Fail fast ordering**: rust-quality and dart-quality gate the (slower) android-build via
  `needs:` so broken logic doesn't burn NDK minutes.
- **Artifacts**: debug APK per PR (14-day retention); release artifacts permanent on the
  Release; nightly perf JSON retained 90 days for trends.

## 3. Secrets (GitHub encrypted secrets — never in repo, never in chat)

| Secret | Used by |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | release.yml (decode to temp file, shred after) |
| `ANDROID_KEYSTORE_PASSWORD` | release.yml |
| `ANDROID_KEY_ALIAS` | release.yml |
| `ANDROID_KEY_PASSWORD` | release.yml |

Until secrets exist, release.yml builds **unsigned** artifacts and labels them clearly —
the pipeline is testable before signing is set up. Keystore generation instructions live in
`docs/engineering/release-runbook.md` (written during Phase 0 execution).

## 4. Branch protection (recommended settings for `main`)

- Require PR + 1 review; require checks: rust-quality, artifacts-drift, dart-quality,
  android-build.
- Linear history; no force pushes. Arena session branches (`arena/*`) push freely and PR
  into `main`.

## 5. Versioning & release flow

- `pubspec.yaml` version is the single app version; tags `vX.Y.Z+build` must match it
  (release job verifies).
- `CHANGELOG.md` updated per release; GitHub Release notes generated from it.
- Phase 1 ships internal-testing artifacts (GitHub Releases); Play Store listing is a later
  decision (needs signing, privacy policy, content rating — runbook covers it).

## 6. What CI proves on every PR (the social contract)

1. The engine is correct (unit/property tests) and lint-clean.
2. The app is correct (widget/golden tests) and analyzer-clean.
3. Generated artifacts match their sources (no hand-edited glue, no stale schema).
4. A real Android APK builds for all ABIs with 16 KB-aligned native libs.
5. Nothing in the dependency graph violates license/advisory policy (nightly + deny in CI).
