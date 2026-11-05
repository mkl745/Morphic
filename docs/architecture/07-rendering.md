# 07 — Rendering Architecture

Status: **Design frozen for Phase 0** · Implements spec §4.3, §7 ·
Related: [ADR-0008](../decisions/ADR-0008-flutter-first-rendering.md)

## 1. Position

**Flutter renders everything in MVP.** No Vulkan, no Metal, no platform views, no textures.
Flutter's own renderer (Impeller, default on Android and — since Flutter 3.47 — desktop)
already uses Vulkan/Metal under the hood; our job is to feed it efficiently, not to replace it.

A custom native backend is a **measured escape hatch**, gated by benchmarks (spec §13 Phase 3):
it enters the codebase only when a realistic workload demonstrably misses frame budgets
*after* Flutter-side optimization, and only behind the abstraction below.

## 2. The abstraction (built in Phase 1 because it has an immediate consumer)

```dart
// lib/rendering/
abstract interface class WorkspaceRenderer {
  Widget buildComponent(ComponentRenderRequest request);   // binding+state+data → widget
  ChartPainter createChartPainter(ChartScene scene);        // scene = engine-aggregated data
}

class FlutterWorkspaceRenderer implements WorkspaceRenderer { … }  // the only MVP impl
```

- **Scene contracts are renderer-independent**: `ChartScene`, `TimelineScene`, `TableScene`
  are immutable data objects produced from engine output (`chartData`, `queryPage`). A future
  Vulkan renderer consumes the *same* scenes — the data engine never learns about pixels.
- Components depend on the interface via Riverpod; swapping renderers is a provider override
  (also how we'll A/B benchmark backends in Phase 3).
- No `graphics/` crate scaffolding is created now (spec §19: no empty modules). When the gate
  opens, the backend lands as `graphics/android_vulkan` + a texture/platform-view adapter,
  with compositing costs measured, not assumed (spec §4.3 warning).

## 3. Flutter rendering playbook (MVP)

| Surface | Technique | Why |
|---|---|---|
| Workspace flow | scrollable adaptive column/section layout (slivers), focus mode on phones | phone-first; no infinite canvas in MVP |
| Data table | sliver list, **fixed row extent**, sticky header, horizontal scroll, page prefetch | O(visible rows) build/layout; 100k rows scroll like 100 |
| Bar/line/timeline | `CustomPainter` + `RepaintBoundary`, picture caching, immutable scene objects | repaint only on data/size change; gestures repaint overlay layer only |
| Tooltips/scrub | separate overlay painter layer | avoids full chart repaint per pointer move |
| Metric cards | plain widget composition | cheap; no painter needed |
| Morph transitions | staggered entrance (150–250 ms), `AnimatedSize`/implicit animations | communicates generation without artificial delay (spec §10.3) |

Rules: no `setState` storms (Riverpod selective watches), no per-frame allocations in
painters, `shouldRepaint` compares scene identity, text laid out via cached `TextPainter`s,
and every chart degrades gracefully to a summary + table link for accessibility.

## 4. The road to the canvas (spec §7) without rewrites

- v1 layout modes: `adaptive`, `grid` (schema enum). `freeform` is **reserved** — the
  compiler never emits it in MVP; the runtime would fall back to adaptive with a notice.
- Phase 2 introduces the spatial canvas *in Flutter first*: pan/zoom container + viewport
  culling + spatial index (Rust `morphic-query` sibling module) + level-of-detail scenes.
  The schema gains freeform coordinates as a **minor** version (additive).
- Phase 3 benchmarks decide the native question with pre-registered triggers, e.g.:
  > 5,000-node interactive graph misses p95 ≤ 16.6 ms after culling/LOD/caching on the
  > mid-range reference device → prototype Vulkan texture backend behind `WorkspaceRenderer`.
- Battery/thermal are co-equal metrics with frame time (spec §18): a backend that wins fps
  but doubles power draw does not ship.

## 5. Performance instrumentation (from day one)

- `SchedulerBinding.addTimingsCallback` → frame build/raster times aggregated per screen.
- Integration-test harness drives scripted scroll/pan/filter workloads on the fixture
  datasets and emits JSON metrics (see [quality doc](../engineering/quality-and-performance.md)).
- Rust side: criterion benches for query/aggregate paths that feed scenes.
- Budgets (hypotheses, mid-range reference): table scroll p95 ≤ 16.6 ms; chart interaction
  p95 ≤ 33 ms; workspace first render ≤ 400 ms after snapshot. All validated, none advertised.
