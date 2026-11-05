# Dependency Strategy

Policy: [ADR-0012](../decisions/ADR-0012-dependency-policy.md). Versions verified against
public sources on **2026-11-05**; exact pins land in lockfiles during Phase 0. Every entry
has a consumer and an exit path. Anything not listed here is not allowed in MVP without an
ADR update.

## 1. Toolchains (pinned)

| Tool | Pin | Notes |
|---|---|---|
| Flutter | **3.47.x** stable | Dart 3.13 bundled; evaluate 3.50 one month after release |
| Rust | stable ≥ 1.85, **edition 2024**, exact version in `rust-toolchain.toml` | reproducible CI |
| Android SDK | compile/target **36**, min **24** (Flutter-vended vars) | Play-compliant |
| NDK | **r28+** (cargokit-managed) | 16 KB page alignment; CI verifies |
| Java / AGP / Gradle / KGP | 17 / 9.1.x / 9.3.x / 2.4.x | Flutter 3.47 supported matrix |
| flutter_rust_bridge_codegen | **2.13.0** (matches runtime) | installed in CI via cargo install, cached |

## 2. Dart dependencies (app)

| Package | Version | Why (consumer) | Risk / exit path |
|---|---|---|---|
| `flutter_rust_bridge` | 2.13.0 | the bridge runtime | version-locked with cargo side; exit = rewrite bridge crate only |
| `flutter_riverpod` | ^3.3 | presentation state (ADR-0004) | mature; exit = controllers isolate it |
| `riverpod_annotation` + dev `riverpod_generator`, `build_runner` | ^3.x / current | provider codegen where useful | optional; can hand-write providers |
| `go_router` | ^18.1 | navigation/deep links | flutter.dev verified, feature-complete |
| `file_picker` | ^11.0 | SAF import (M1.2) | community but standard; exit = `file_selector` or platform channel behind `PlatformFileSource` |
| `path_provider` | ^2.1 | storage root for EngineConfig | flutter.dev verified |
| `intl` | current | number/date formatting, l10n seam | flutter.dev ecosystem |
| `share_handler` *(stretch)* | current | Share-to-Morphic (M1.6 stretch) | evaluate at task start; drop without architecture impact |
| dev: `flutter_lints` (or `very_good_analysis`), `mocktail`, `integration_test`, `golden_toolkit` *(optional)* | current | quality infra | dev-only |

**Not adopted (and why):** `fl_chart`/chart libs (ADR-0008: own painters), `freezed`
(frb generates DTOs; UI state is small), `dio`/`http` (no network in MVP), `hive`/`isar`/
`sqflite` (ADR-0007), `flutter_secure_storage` (no secrets until P2 cloud), state-management
alternatives (ADR-0004).

## 3. Rust dependencies (engine + bridge)

| Crate | Why (consumer) | Notes / exit path |
|---|---|---|
| `serde`, `serde_json` | all DTOs, schema docs, journal | foundational |
| `flutter_rust_bridge` (+ macros) | bridge crate only | engine crates never import it |
| `csv` | streaming CSV (morphic-ingest) | BurntSushi, battle-tested |
| `encoding_rs`, `chardetng` | encoding detection/decode | Firefox-proven |
| `regex` | log pattern library | bounded, compiled once |
| `chrono` | timestamp parsing/formatting (curated formats + epoch heuristics) | swap to `time` only if size pressures |
| `uuid` (v4) / `ulid` | ids (workspaces ULID, ops UUID) | tiny |
| `sha2` | dataset content addressing | RustCrypto |
| `blake3` | snapshot checksums (ADR-0007) | fast, small |
| `bincode` (2.x, serde) | dataset snapshot binary | versioned magic; exit = re-ingest from source |
| `schemars` | JSON Schema export (dev/build path) | artifact generation only |
| `jsonschema` | raw-JSON pre-validation at trust boundary (P2-ready, used in tests now) | optional at runtime in MVP |
| `thiserror` | typed engine errors | ergonomic, zero-cost |
| `tracing` (+ `tracing-subscriber` dev; Android log bridge in bridge crate) | structured metadata-only logs | no row data ever logged |
| `smallvec` | selection vectors / hot paths | optional, profile first |
| dev: `criterion`, `proptest`, `insta` (snapshot goldens), `cargo-fuzz` targets | quality infra | dev-only |

**Not adopted (deferred with triggers):** `duckdb` (joins/out-of-core → P2/P4, ADR-0005),
`arrow`/`parquet` (interchange formats → P4), `simd-json` (only if profiling shows JSON parse
is the bottleneck), `rayon` (only if single-thread profiling hits budgets), `tokio` (no
async I/O need; frb provides dispatch), llama.cpp/ONNX bindings (P2, ADR-0009), `rusqlite`
(store scale trigger, ADR-0007).

## 4. Fonts & assets

Inter (OFL) + JetBrains Mono (OFL), bundled; sample datasets are synthetic or
permissively-licensed, documented in `fixtures/manifest.json`.

## 5. GitHub Actions (pinned to SHAs)

`actions/checkout`, `subosito/flutter-action` (or flutter-actions/setup-flutter),
`dtolnay/rust-toolchain`, `Swatinem/rust-cache`, `actions/setup-java`,
`android-actions/setup-android`, `actions/upload-artifact`, `softprops/action-gh-release`,
`reactivecircus/android-emulator-runner` (nightly). Dependabot covers cargo, pub, and
actions ecosystems weekly.

## 6. Upgrade ritual (monthly)

1. Dependabot PRs (grouped) → CI green → merge.
2. Majors: dedicated PR, changelog review, full test + golden run, perf spot-check.
3. Quarterly: Flutter stable upgrade (one minor), frb pair upgrade, NDK check.
4. Every upgrade updates this doc if versions/risks changed.
