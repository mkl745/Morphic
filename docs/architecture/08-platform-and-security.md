# 08 — Platform Strategy & Security/Privacy Architecture

Status: **Design frozen for Phase 0** · Implements spec §4.4, §12 ·
Related: [ADR-0010](../decisions/ADR-0010-android-configuration.md)

## 1. Android-first configuration (verified 2026-11-05)

| Setting | Value | Rationale |
|---|---|---|
| Flutter | **3.47.x stable** (pin; evaluate 3.50 after its Nov 2026 release settles) | current stable; Dart 3.13; Impeller default |
| compileSdk / targetSdk | **36** (Flutter 3.47 defaults) | Play requires API 36 for new apps/updates since 2026-08-31 |
| minSdk | **24** (Flutter floor) | covers essentially all active devices; no reason to go lower |
| Java / AGP / Gradle / KGP | 17 / 9.1.x / 9.3.x / 2.4.x (Flutter 3.47 matrix) | stay on Flutter's supported matrix, don't fight it |
| NDK | r28+ via cargokit | **16 KB page-size alignment** required by Play for native code |
| ABIs | arm64-v8a, armeabi-v7a, x86_64 | devices + emulator; App Bundle splits per-ABI download size |
| Rust | current stable, **edition 2024**, pinned in `rust-toolchain.toml` | reproducible CI |

16 KB pages: we additionally pass `-Wl,-z,max-page-size=16384` for Rust cdylibs and verify
alignment in CI (`zipalign -c -P 16` / ELF program-header check) so a toolchain regression
can never silently ship a non-compliant `.so`.

## 2. File access & permissions (MVP)

- Import via **SAF file picker** (`file_picker`): per-file grant, then we **copy into
  app-private storage** immediately. No persistable URI permissions, no
  `READ_EXTERNAL_STORAGE`, no `MANAGE_EXTERNAL_STORAGE`. Permission revocation cannot break
  saved workspaces because we never depend on the original location (spec §11 requirement).
- **Share-to-Morphic** (`ACTION_SEND` intent filter): P1 stretch; same copy-then-ingest path.
- Clipboard import + bundled sample datasets: no permissions at all.
- Storage root: `path_provider` application documents dir → passed to `EngineConfig`.
  The Rust core only ever sees an opaque root path (platform-independent).

## 3. iOS-ready rules (enforced by review, not by building iOS now)

1. No Android types anywhere in `engine/` (no JNI, no android paths). Platform facts enter
   only through `EngineConfig` and Dart-side adapters.
2. frb/cargokit already support iOS targets; the bridge crate stays iOS-compilable
   (CI adds an iOS build job when the iOS phase starts — macOS runners cost money now).
3. File picking, storage roots, lifecycle hooks live behind Dart interfaces
   (`PlatformFileSource`, `StorageRoot`, `LifecycleBridge`) with Android implementations.
4. Metal is a Phase 3+ question behind the same renderer gate as Vulkan.

## 4. Threat model (MVP-relevant subset)

| Threat | Vector | Control |
|---|---|---|
| Malicious file → memory safety | parser edge cases | Rust parsers, bounded buffers, size/row/column caps, quarantine policy, fuzz targets in CI (nightly) |
| Malicious file → UI injection | crafted field names/values | schema is closed-world; data is never interpreted as schema/commands; strings rendered as text only |
| Malicious file → AI injection (P2) | instructions inside documents | data/instruction separation: imported content enters prompts as *quoted data*; AI output passes the same 5-pass validation; no tool execution from content |
| Resource exhaustion | huge/deep files, pathological queries | import caps, filter depth/node caps, query time budgets, component caps, page caps |
| Data exfiltration | any network call | **MVP has zero network permission usage** (no INTERNET permission in release manifest); cloud AI (P2) requires explicit consent UI + per-operation disclosure |
| Workspace tampering | corrupted files on disk | checksums, atomic writes, migration backups, degraded modes — never crash, never execute |
| Secrets leakage (P2 cloud keys) | logs/storage | `flutter_secure_storage` when introduced; never in workspace docs or logs |

## 5. Privacy commitments (product-level, spec §12)

- **Offline by default**: MVP functions with airplane mode on; CI smoke test asserts it.
- No telemetry without opt-in; crash reporting (if added) is opt-in and scrubbed of data.
- Logs contain metadata only (counts, durations, field *names* at debug level — never row
  values, never file contents).
- When cloud AI arrives (P2): a consent screen explains exactly what leaves the device
  (profile summaries vs raw samples — user chooses), a persistent privacy mode disables all
  network AI, and every cloud-derived insight is labeled with its provenance.
