# ADR-0013 — Custom MORPHIC design system on Material 3; hand-built chart painters

## Context
Spec §10: minimal, technical, calm, precise, premium; not generic AI-chat aesthetics; not
unmodified Material; dark + light; phone-first responsive; accessibility non-negotiable.
Flutter 3.47 decouples Material into its own package, making "Material as foundation,
identity on top" cleaner than ever.

## Decision
Build a **token-driven design system** (`lib/design_system/`): color/typography/space/
radius/elevation/motion tokens, light+dark themes mapped onto Material 3 `ColorScheme`/
`ThemeData` where sensible, custom component styling everywhere the product identity shows
(workspace surfaces, component chrome, import/morph flow). Typography: **Inter** (UI) +
**JetBrains Mono** (data/code), both OFL, bundled as assets. Charts are hand-built
`CustomPainter`s per [ADR-0008](ADR-0008-flutter-first-rendering.md). Full token spec:
[design-system.md](../design/design-system.md). Navigation: **go_router 18.x**
(flutter.dev-maintained, feature-complete).

## Alternatives
- **Stock Material 3** — rejected by spec: the workspace must not look like a settings app.
- **Cupertino hybrid** — rejected: Android-first; iOS release will still use MORPHIC identity.
- **Design-token package (e.g. themed third-party kits)** — rejected: our token set is small
  and specific; a kit adds indirection without value.

## Consequences
- One place to change the product's feel; goldens lock it against regressions.
- Material gives us accessible primitives (ripples, focus traversal, text scaling) for free
  while the identity layer keeps us distinctive.
- Font assets add ~1–2 MB; subset weights in release builds if size budget pressures.
- Motion budget (150–250 ms, no artificial delays) is a token, so the "morphing" experience
  stays fast and honest (spec §10.3).
