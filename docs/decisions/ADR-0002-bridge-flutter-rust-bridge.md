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
