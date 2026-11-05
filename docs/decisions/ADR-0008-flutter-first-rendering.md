# ADR-0008 — Flutter-only rendering in MVP; native backends are benchmark-gated

## Context
Spec §4.3/§7/§13: Flutter renders the initial product; Vulkan/Metal only when measured
requirements justify them; a renderer abstraction must exist from the start; embedding
native output in Flutter has compositing costs.

## Decision
MVP renders **100% in Flutter**: widget composition + `CustomPainter` charts/timelines with
repaint boundaries and immutable scene objects; sliver tables with fixed row extents. A thin
`WorkspaceRenderer` interface (Dart) consumes renderer-independent **scene contracts**
produced from engine output — this is the entire abstraction in Phase 1 (it has an immediate
consumer, so it isn't speculative). No `graphics/` crates, no platform views, no textures.
Native backend entry is gated by pre-registered benchmark triggers (see
[07-rendering.md](../architecture/07-rendering.md)) including battery/thermal co-metrics.

## Alternatives
- **Vulkan backend from the start** — rejected by spec and by engineering judgment: Impeller
  already targets Vulkan on Android; a custom backend adds compositing, lifecycle, and
  device-fragmentation costs before we have a workload that needs it.
- **Third-party chart package (fl_chart & co.)** — rejected: our design system, interaction
  model (tap-to-filter, scrub), and scene contracts are specific; a dependency would fight
  the renderer abstraction and golden-test determinism. Bar/line/timeline painters are
  bounded, well-understood work (~M1.4).
- **WebView/canvas-in-web** — rejected by spec §4 (not a WebView product).

## Consequences
- Fastest path to the Phase 1 hypothesis; all rendering skills stay in one framework.
- Scene contracts + provider-override renderer make Phase 3 A/B benchmarking possible
  without touching components or the engine.
- We own chart rendering correctness/a11y — mitigated by goldens, semantics summaries, and
  the always-available table fallback.
- Explicit debt register: freeform canvas (P2), culling/spatial index/LOD (P2/P3) — the
  schema's reserved `freeform` mode and scene contracts are the seams.
