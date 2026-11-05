# Architecture Decision Records

Format: Context → Decision → Alternatives considered → Consequences. Status is `Accepted`
unless noted. New decisions get the next number; superseded ADRs are kept and linked.

| # | Decision | Status |
|---|---|---|
| [0001](ADR-0001-monorepo-dual-toolchain.md) | Monorepo: Flutter app + root Cargo workspace | Accepted |
| [0002](ADR-0002-bridge-flutter-rust-bridge.md) | flutter_rust_bridge 2.13 + cargokit for Dart↔Rust | Accepted |
| [0003](ADR-0003-rust-owns-state.md) | Rust owns canonical state; command/snapshot sync | Accepted |
| [0004](ADR-0004-riverpod-presentation-state.md) | Riverpod 3 (Notifier API) for presentation state | Accepted |
| [0005](ADR-0005-columnar-store-custom-query.md) | Custom columnar store + query engine; Arrow/DuckDB deferred | Accepted |
| [0006](ADR-0006-ui-schema-typed-contract.md) | UI Schema: Rust types as source of truth, JSON Schema exported | Accepted |
| [0007](ADR-0007-persistence-files-atomic.md) | Folder-per-workspace, JSON + binary snapshots, atomic writes; SQLite deferred | Accepted |
| [0008](ADR-0008-flutter-first-rendering.md) | Flutter-only rendering in MVP; benchmark-gated native backends | Accepted |
| [0009](ADR-0009-deterministic-first-intelligence.md) | Deterministic compiler first; AI behind a provider trait (P2) | Accepted |
| [0010](ADR-0010-android-configuration.md) | Android matrix: Flutter 3.47, SDK 36/24, NDK r28+, 16 KB pages | Accepted |
| [0011](ADR-0011-github-actions-ci.md) | GitHub Actions: CI, drift gates, signed releases, nightly quality | Accepted |
| [0012](ADR-0012-dependency-policy.md) | Minimal, pinned, audited dependencies; license allowlist | Accepted |
| [0013](ADR-0013-design-system-material-foundation.md) | Custom design system on Material 3; hand-built chart painters | Accepted |
