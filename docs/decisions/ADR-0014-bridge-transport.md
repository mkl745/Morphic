# ADR-0014 — Bridge transport: keep the typed C ABI for M1.1, defer flutter_rust_bridge

- **Status:** Accepted (2026-11-06)
- **Supersedes:** the M1.1 migration commitment in the ADR-0002 addendum
- **Context phase:** M1.1 task 1.1.4

## Context

ADR-0002's addendum committed to migrating the Phase 0 hand-written C ABI to
`flutter_rust_bridge` (frb) + `cargokit` during M1.1. Task 1.1.4 is where that migration was
scheduled.

Two facts make the migration the wrong move *right now*:

1. **The development sandbox has no Rust or Flutter toolchain.** CI is the only compiler.
   frb is a *code generator*: it requires `flutter_rust_bridge_codegen` to run against a
   Flutter SDK, and cargokit adds a CMake/Gradle build integration. Neither can be authored
   or debugged locally here, so the migration would be a large blind change validated only
   by ~13-minute CI round trips — precisely the conditions under which silent breakage
   survives.
2. **The migration is orthogonal to the task's actual value.** 1.1.4 is about *real engine
   capabilities* — sessions, `queryPage`, `metricData`, revisioned snapshots, progress
   events. None of those need a different transport. The existing ABI already carries them.

The architectural guarantee that matters is unchanged: **only `morphic-bridge` knows about
FFI**. The engine crates never see it, so the transport can still be swapped later without
touching business logic.

## Decision

Keep the hand-written C ABI over `dart:ffi` with a JSON control plane for M1.1, and
**explicitly re-schedule** the frb evaluation to M1.7 (release hardening), where a real
toolchain and physical devices are available.

What ships in 1.1.4 instead of the migration:

- A **stateful** bridge: engines cached per storage root, so imported sessions survive
  between calls. This is what makes `queryPage`/`metricData` execute against canonical Rust
  state rather than re-parsing.
- New entry points: `morphic_import_csv`, `morphic_snapshot`, `morphic_query_page`,
  `morphic_metric_data`, `morphic_close_workspace`.
- A nullable `extern "C"` progress callback, contract-tested in Rust with a real callback.
- `API_VERSION` bumped to **2**; the Phase 0 entry points are retained so the PoC screen and
  existing callers keep working.
- Dart `EngineController` + `ImportController` with contract tests against a recording fake.

## Consequences

**Positive**

- The task's real value lands now, fully compiled and tested by CI.
- No new build-time dependency, no codegen step, no Gradle/CMake integration risk before
  the release pipeline is exercised on hardware.
- The panic firewall, `{"error": …}` envelope, and explicit string ownership stay simple and
  auditable.

**Negative / accepted debt**

- Hand-written FFI must be kept in sync by hand. Mitigated by contract tests on **both**
  sides and by the closed `MorphicBridge` interface (a new method breaks the fake, so it
  cannot be added silently).
- JSON is not the most efficient control plane. Acceptable at M1.1 volumes; bulk row data is
  already paged and bounded (`limit ≤ 1024`).
- **Dart does not yet consume the progress callback.** The Rust capability is real and
  tested; cross-isolate delivery (`NativeCallable.listener` plus a worker isolate) is wired
  with the import UI in **1.1.7**. Until then `ImportController` reports honest coarse
  stages (`reading` → `importing` → `done`) and does **not** invent sub-stages it cannot
  observe.
- The FFI import call currently runs on the calling isolate. Moving it to a worker isolate
  (with its own bridge instance against the same process-global engine registry) is also
  part of **1.1.7**, and is required before the 10 MB responsiveness budget can be claimed.

## Revisit when

M1.7, or sooner if a local Flutter + Rust toolchain becomes available. The decision to
revisit is recorded here so the deferral is a tracked choice, not a quiet omission.
