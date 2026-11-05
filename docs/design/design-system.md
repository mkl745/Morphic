# MORPHIC Design System — "Precision Instrument"

Implements spec §10 · [ADR-0013](../decisions/ADR-0013-design-system-material-foundation.md).
Tokens are defined once in `lib/design_system/tokens.dart` (Phase 0) and consumed everywhere;
no raw colors/sizes in feature code (lint-enforced).

## 1. Identity

Calm, technical, spatial. The workspace should feel like an instrument that *assembled
itself around your data* — not a chat app, not a BI dashboard. Information density with
breathing room; restrained color used **semantically** (severity, selection, focus), never
decoratively. Dark mode is the reference theme; light mode is first-class, not inverted.

## 2. Color tokens

| Token | Dark | Light | Use |
|---|---|---|---|
| `bg` | `#0A0C10` | `#F7F8FA` | app background |
| `surface` | `#12151C` | `#FFFFFF` | component surfaces |
| `surfaceElevated` | `#1A1F29` | `#FFFFFF` + shadow | sheets, menus |
| `border` | `#232A37` | `#E3E7ED` | hairlines, panel edges |
| `textPrimary` | `#E6EAF2` | `#14181F` | headings, values |
| `textSecondary` | `#9AA3B2` | `#5B6472` | labels, axes |
| `accent` | `#4FD1C5` | `#0D9488` | focus, selection, primary actions, "generated" moments |
| `info` | `#60A5FA` | `#2563EB` | informational |
| `success` | `#34D399` | `#059669` | healthy/verified |
| `warning` | `#FBBF24` | `#D97706` | inferred/uncertain (with confidence UI) |
| `error` | `#F87171` | `#DC2626` | errors, severity ERROR |
| `severity.*` | trace `#64748B` · debug `#94A3B8` · info `#60A5FA` · warn `#FBBF24` · error `#F87171` · fatal `#C084FC` | same hues, darkened for contrast | logs/timelines |

Contrast: all text/background pairs ≥ 4.5:1 (checked by a token unit test). Inferred/AI
content (P2) always carries the `warning`-tinted provenance chip — never styled as fact.

## 3. Typography

Inter (UI) · JetBrains Mono (data, code, timestamps, ids). Scale (sp): `display 28/600`,
`title 20/600`, `section 16/600`, `body 14/400`, `label 12/500`, `mono 13/400`,
`metric 32/650` (tabular figures). Line height 1.4; tabular numerals everywhere numbers
align (tables, metrics, axes). Text scaling honored to 1.3× minimum.

## 4. Space, shape, elevation

4 dp base grid: `xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32`. Radii: `sm 8 · md 12 ·
lg 16` (components use md; sheets lg). Elevation via **tonal surfaces + 1 dp hairlines**,
not heavy shadows (dark theme); light theme adds soft ambient shadow only on overlays.
Component internal padding: lg; gap between components: md (phone) / lg (tablet).

## 5. Motion

Tokens: `fast 150ms · standard 200ms · slow 250ms`, easing `standard (0.2, 0, 0, 1)`.
Rules: component entrance = fade+4 dp rise, staggered ≤ 40 ms, total ≤ 400 ms; layout
changes animate size/position (200 ms); **no artificial loading animation** — the morph
stage indicator reflects real engine events and disappears when work is done (spec §10.3).
Reduced-motion setting disables stagger/translation, keeps opacity.

## 6. Responsive layout

| Class | Width | Workspace behavior |
|---|---|---|
| compact | < 600 dp | single-column flow; **focus mode**: one expanded component at a time, others collapse to header+summary; bottom contextual controls; detail = bottom sheet |
| medium | 600–840 dp | two-column adaptive flow; hints `span` respected; detail = side sheet |
| expanded | > 840 dp | multi-column canvas-like flow; persistent detail rail (tablet/landscape) |

Phones never get a shrunk desktop grid. Layout `hints` (span/height) from the schema map to
these classes; manual reorder/resize works in all classes (M1.5).

## 7. Component chrome (shared)

Every generated component: header (title + type icon + confidence/provenance chip when
inferred) · overflow menu (Why this view? · Change type · Resize · Move · Remove) ·
content · footer state (row counts, filter-active indicator). Empty-after-filter and
binding-error states are designed surfaces with recovery actions, never blank boxes.

## 8. Key screens (MVP)

- **Home**: wordmark, recent workspaces (title, dataset chip, modified), primary "Import
  data" action, samples row, local-processing status line ("All processing on-device").
- **Import**: source chooser (file/clipboard/sample) → file facts card (size, detected
  format/encoding) → morph stages (real events) → workspace.
- **Workspace**: app bar (title editable, save state, undo/redo), global filter bar
  (chips), adaptive component flow, command FAB placeholder **hidden until P2**.
- **Settings**: theme, storage usage, import limits, about/privacy ("No data leaves this
  device" — literally true in MVP).

## 9. Accessibility contract

Semantic summaries per component (registry contract), logical focus order, ≥48 dp targets,
contrast token-tested, goldens at 1.3× text scale, screen-reader pass on the vertical slice
before MVP exit. Charts always offer "View as table".
