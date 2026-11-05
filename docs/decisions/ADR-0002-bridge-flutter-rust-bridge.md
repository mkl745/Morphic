# ADR-0002 — flutter_rust_bridge 2.13 + cargokit for Dart↔Rust

## Context
Spec §4.2 requires stable FFI with batched data exchange and suggests evaluating
flutter_rust_bridge. Options: hand-rolled `dart:ffi` + C ABI, frb v2, or platform channels
with JNI/ObjC glue.

## Decision
**flutter_rust_bridge 2.13.0** (verified current stable 2026-11-05; 2.14 in beta — not
adopted) with **cargokit** building the Rust cdylib/staticlib inside `flutter build` for all
Android ABIs. Generated Dart/Rust glue is **committed** and drift-checked in CI. Opaque
handles (`RustAutoOpaque`) for Engine/Session; `StreamSink` for events; typed lists for bulk
column data. Contract: [02-dart-rust-contract.md](../architecture/02-dart-rust-contract.md).

## Alternatives
- **Hand-rolled dart:ffi + C ABI** — rejected for MVP velocity: we'd rebuild serialization,
  async dispatch, stream plumbing, and error mapping ourselves; frb is exactly this,
  maintained. The contract doc keeps us frb-independent conceptually if we ever must drop it.
- **Platform channels (JNI)** — rejected: per-call overhead, string-based codecs, and
  Android-specific glue leaking into the core (spec §4.2 says JNI only when necessary).
- **Dart native assets / hooks (emerging)** — watch item: frb 2.13 already documents native
  assets support; revisit when Flutter's native-assets story stabilizes. Not a blocker.

## Consequences
- One codegen step (`flutter_rust_bridge_codegen generate`) after bridge API changes; CI
  gate prevents hand-editing generated files.
- cargokit handles NDK toolchains, 16 KB alignment flags, and debug/release profiles; we pin
  NDK r28+ and verify alignment in CI anyway (trust but verify).
- Version coupling: frb runtime (pub) + frb macro/codegen (cargo) versions must match; pinned
  in lockfiles and upgraded together (dependency policy).
- Risk accepted: frb is a community project (very active, verified publisher). Exit path:
  the bridge crate isolates all frb-specific code; engine crates never see frb types.

## Addendum (Phase 0 execution, 2026-11-05)

The build sandbox has **no local Flutter/Dart/Rust toolchain and no access to crates.io /
pub.dev / the Flutter CDN** (only GitHub, npm, PyPI are reachable). frb codegen cannot run
locally, and its generated output would have to be produced in CI and committed back — a
fragile loop for a first proof of concept.

**Decision for Phase 0 only:** the Dart↔Rust PoC uses a **hand-written C ABI over
`dart:ffi`** (see `apps/morphic_flutter/rust/src/lib.rs`), which is fully authorable and
testable in CI without codegen. It implements the same coarse-grained contract
(`engine_info`, `profile_csv`, `create_workspace`, `load/load`, `free_string`) with the
panic firewall. The engine crates are FFI-agnostic, so this is contained to the bridge crate.

**M1.1 is explicitly the production-integration milestone:** migrate the bridge to
flutter_rust_bridge 2.13 + cargokit (running codegen in CI), adopt go_router and Riverpod 3,
and wire file_picker. The Phase 0 app uses minimal dependencies (Flutter + path_provider +
ffi) and Navigator routes to keep the first CI build low-risk. This is the "smaller but
architecturally compatible version" sanctioned by spec §21; no engine architecture changes.
