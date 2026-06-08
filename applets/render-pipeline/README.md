# SwiftTUI Render Pipeline — developer walkthrough

A self-contained, source-grounded onboarding page that explains how SwiftTUI
turns an authored `View` into terminal output. It is meant for engineers reading
the framework for the first time, and as a refresher when changing the renderer.

Open it directly in a browser — no Bun, npm, Astro, or website package required:

```bash
open applets/render-pipeline/index.html
```

## What it covers

The page is structured as documentation, with a sticky table of contents:

1. **The mental model** — the two views of one frame (the 7-product *data* model
   vs the 5-stage *scheduling* model) and a diagram of how they map.
2. **Interactive walkthrough** — step a frame through the five runtime stages;
   the authored lines, the stage's job, and the products that exist *so far* stay
   in sync (no fictional terminal cells before `raster`).
3. **The seven phase products** — what each owns and its `FrameArtifacts` field.
4. **Change propagation** — how a `@State` write becomes a `ScheduledFrame`
   through invalidation and coalescing (not a direct re-render).
5. **What runs where** — main-actor vs off-actor frame-tail work, and the
   renderer invariants.
6. **Four fates of a frame** — committed / dropped / cancelled / elided.
7. **Host handoff** — host-facing damage semantics and the `SemanticHostFrame`
   contract.
8. **Source deep-dive** — tabbed excerpts of the real implementation.
9. **Diagnostics** — what a `RuntimeFrameSample` records.
10. **Where to look next** — a question-to-file code map and a glossary.

## Source grounding

Every claim links to a `path:line` in the checked-out `swift-tui` package
(relative links, so they open from your local clone). The content mirrors the
framework's own DocC articles and is kept current at `HEAD`:

- [`Runtime-Render-Pipeline.md`](../../swift-tui/Sources/SwiftTUIRuntime/SwiftTUIRuntime.docc/Runtime-Render-Pipeline.md)
  — runtime scheduling, cancellation, commit policy, host handoff.
- [`Rendering-Pipeline.md`](../../swift-tui/Sources/SwiftTUICore/SwiftTUICore.docc/Rendering-Pipeline.md)
  — the phase-product data model.

When the renderer changes, update those DocC articles first; this applet should
follow them, not the other way around.

## Files

| File | Role |
| --- | --- |
| `index.html` | Document structure and section prose. |
| `app.js` | All content as data, plus the interactive rendering (vanilla JS, no dependencies). |
| `styles.css` | The documentation-grade theme (flat, calm, no decorative motion). |

The only motion is the opt-in **Auto-play** in the walkthrough; everything else
is static, and `prefers-reduced-motion` is respected.
