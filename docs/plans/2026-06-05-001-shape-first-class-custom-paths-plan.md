# First-Class Custom Shapes — `path(in:)` + arbitrary-path rasterization

**Date:** 2026-06-05
**Status:** Plan approved for execution. Targets the `swift-tui` submodule
(currently `main` @ `6f761b41`, atop `0.0.17`).
**Verdict:** **A-with-caveats** — implement SwiftUI-style first-class custom
shapes as a strict **superset of option C**. Keep the analytic fast path and the
single-`geometry` rendering plumbing (C); add a frame-reactive `path(in:)`
authoring surface and full `.fill`/`.stroke`/`.strokeBorder`/`.foregroundStyle`
composition (A).

> This plan was produced by a fan-out investigation + adversarial 3-architect
> design panel. Every file:line claim below was independently re-verified
> against the tree before approval.

## 1. Goal & decision

Add author-defined custom shapes (`struct Tri: Shape { func path(in rect:) -> Path }`)
that compose with the existing shape-modifier algebra exactly like the built-in
shapes. The user's bar: **prefer C; choose A only if every expected A-issue is
fully mitigable.** All five are mitigable under the stated scope, so we take the
hybrid that is *both* A (frame-reactive `path(in:)`) and C (geometry stays the
plumbing).

The recommended design is a **strict superset of C**: it sacrifices nothing C
protects (analytic built-ins, cheap reuse, single-`geometry` plumbing) and adds
A's authoring surface on top.

## 2. A-issue mitigation table

| A-issue | Mitigable | Mechanism (verified anchor) |
| --- | --- | --- |
| **(1) rect-timing** — `path(in:)` is frame-reactive, but `geometry` resolves before layout | **FULLY** | Value-early / appearance-late. Evaluate `path(in:)` once at resolve against the **unit rect** `Rect(0,0,1,1)` → normalized, frame-independent `Path` in the rect-independent `ShapePayload`. Placed bounds fuse with geometry at draw-extraction (`DrawExtractor.swift:257+`, `.fill(bounds: bounds, geometry: payload.geometry)`). Raster scales the unit polygon into `shapeBounds`. No `GeometryReader` re-resolve — the measurement arm `case (.shape, .shape): return true` (`NodeLayoutInfo.swift:65`) means a path affects pixels, not layout. |
| **(2) inset / strokeBorder** don't generalize to arbitrary paths | **FULLY** (for the SwiftUI-correct semantics) | `inset(by:)` = scale the unit polygon into a **frame-inset** `shapeBounds` (matches SwiftUI built-in self-inset; mirrors how `insetAmount` already shrinks the bounding rect). `strokeBorder` = **subpixel mask-intersection**: fill interior into Braille canvas A, stroke outline into B, keep `B ∧ A` (generalizes the existing `strokeEllipseSegment` include-predicate). True polyline offsetting is **out of scope** (mathematically ambiguous; A wouldn't enable it either). |
| **(3) Path in the value payload** pressures resolve-reuse / commit perf | **FULLY** | `indirect case path(Boxed<Path>, FillRule)`. `indirect` keeps the 5 existing cases one enum word (precedent: `indirect case tileStyle`, `ShapeStyles.swift:92`). `Boxed<Path>` (`Support/Boxed.swift`) gives COW + pointer-identity-first `==` (`_storage === rhs._storage || snapshot()==snapshot()`), so `ResolvedNode ==` / placement reuse is O(1) on unchanged frames. The `RetainedPhaseExtractionSignature.NodeSignature` per-frame `drawPayload` copy (`RetainedPhaseExtraction.swift:35/:89`) carries the 8-byte box pointer, mirroring the `DrawMetadataSignature.heavyFields` projection precedent (`:41–50`). **Non-path nodes regress zero** — banked H2/H3/place-ms/commit-ms wins preserved. |
| **(4) adding `path(in:)`** breaks the just-standardized single-`geometry` requirement | **FULLY** | Don't replace `geometry`. Both `geometry` and `path(in:)` are public requirements with **bidirectional defaults** (`geometry` defaults to `.path(Boxed(path(in: unitRect)), .nonZero)`; `path(in:)` defaults to a `Path` synthesized from the analytic geometry case). The 5 built-ins keep overriding `geometry`; new custom shapes implement `path(in:)`; existing custom shapes (geometry-only) compile unchanged. Contract: **implement at least one.** `kindName`/`insetAmount` stay `@_spi(ShapeRendering)`. AnyView policy untouched (a value `Path` is not node-erasure). |
| **(5) loss of analytic bit-exactness** | **N/A in scope** | The 5 built-ins **never route through the path rasterizer** (they keep analytic `ShapeGeometry` cases), so their fixture-pinned, bit-exact output is byte-for-byte untouched. Arbitrary custom paths cannot be bit-exact *by definition* — identical under A or C, and pre-accepted by the user. **Containment:** the path rasterizer mirrors the exact cell-center convention (`px=cellRelX*2+0.5, py=cellRelY*4+1.5`, `ColorResolution.swift:101`) and aspect fold so it is internally consistent and aspect-true. |

Architect verdicts: A-with-caveats, **C**, A-with-caveats. The lone "C" still
adds `path(in:)` as a defaulted requirement and routes paths through a new
`indirect ShapeGeometry` case — i.e. functionally the same hybrid. Consensus on
mechanism is total; the only disagreement is the *label* on issue (5), which the
user already scoped as acceptable.

## 3. Architecture (the hybrid)

**One `Path` type.** Extend the **existing** `Sources/SwiftTUICore/Geometry/Path.swift`
(`public struct Path: Equatable, Sendable`, cell-space `Double` coords, already
used for `contentShape` hit-testing). Do **not** fork a second Path — one type
serves both hit-testing and rendering.
- Add `Element.quadCurve(to:control:)` and `.curve(to:control1:control2:)`; keep
  `close`, add `closeSubpath()` alias.
- Add `public enum FillRule { case nonZero, evenOdd }` and
  `public struct FillStyle { var isEOFilled = false; var isAntialiased = true }`
  (`isAntialiased` accepted, documented informational on the Braille grid).
- Generalize `contains(_:)` to take a `FillRule` (default **`.evenOdd`** to
  preserve current hit-test behavior; signed-crossing accumulation for `.nonZero`).
- Add `flattened(tolerance:) -> [[Point]]` (recursive de Casteljau; stdlib math
  via the `Darwin/Glibc/WASILibc/ucrt` shim block `BrailleCanvas.swift:1–9` uses).
- SwiftUI-named constructors: `init(_ build:)`, `init(_ rect:)`,
  `init(roundedRect:cornerRadius:)`, `init(ellipseIn:)`, plus
  `addRect/addRoundedRect/addEllipse/addQuadCurve/addCurve`. **Defer** `addArc`
  (needs a Foundation-free `Angle`; follow-on). **Omit** `transform:` params (no
  `CGAffineTransform`). **Do not** conform `Path` to `Animatable` in v1.

**Geometry / protocol.** `ShapeGeometry` gains exactly one case:
`indirect case path(Boxed<Path>, FillRule)`. The 5 analytic cases are unchanged.
`Shape` keeps `var geometry: ShapeGeometry { get }` **and** gains
`func path(in rect: Rect) -> Path` — both **public**, both defaulted (§2 issue 4).
The 6 exhaustive `ShapeGeometry` switches each get a `.path` arm:
`shapeContains` (`ColorResolution.swift:21`), `curvedShapeContains`
(`:104` — route `.path` *away*; never reach the `:165` `assertionFailure`),
`paintFill` dispatch (`PaintCommands.swift:36`), `paintBrailleShape` (`:332`,
explicit unreachable rect case at `:369`), `paintStroke` dispatch
(`Borders.swift:30`), `SnapshotRenderer.describe` (`StyleDescriptions.swift:131`).
`BorderMask` (`DrawExtractor.swift:21`) gets a `.path` interior predicate.
`.clip` stays rect-only (`DrawTreeTypes.swift:118`) — unaffected.

**Rasterizer.** Two routes sharing **one** "is normalized point inside the
polygon" core so silhouettes agree cell-for-cell:
- **Route A (Braille subpixel, default):** in `paintBrailleShape`'s `.path` arm,
  flatten → project unit points into subpixel coords folding aspect exactly like
  `subpixelCircleRadii` (`width/2`, `height/4`) → **winding-rule scanline fill**
  (per-row edge x-intersections, sort, accumulate per `FillRule`, fill spans via
  `BrailleCanvas.setPixel`, analogous to `fillEllipse`'s per-row span). Existing
  cell-walk emits one glyph per lit cell with one resolved fg color.
- **Route B (cell-walk, for tile/gradient/solid block):** `.path` arm of
  `shapeContains` calls the shared `pathContains` at the cell visual center
  (`px=cellRelX*2+0.5, py=cellRelY*4+1.5`).
- **Stroke:** chain `BrailleCanvas.line` over the flattened closed polyline
  (thicken by `lineWidth` via offset lines). **strokeBorder:** fill-mask ∧
  stroke-mask intersection. Clip to `shapeBounds` (`setPixel` already clips) so a
  path can't overflow its frame or violate the off-screen-elision "never record
  clipped identities" invariant.

**Composition.** `.fill`/`.stroke`/`.strokeBorder`/`.foregroundStyle` work
natively because `.path` flows through the same `ShapeOperation`/`ShapePayload`/
`DrawCommand` machinery; nil-style fill inherits `foregroundStyle ?? .semantic(.foreground)`
(`DrawExtractor.swift:262`). One fg per cell is the structural ceiling.

## 4. Resolved open questions (decisions for execution)

1. **`path(in:)` is PUBLIC** (full SwiftUI authoring parity), with `geometry`
   public+defaulted and bidirectional defaults. Contract: implement at least one.
   `kindName`/`insetAmount` remain `@_spi(ShapeRendering)`.
2. **FillRule defaults:** `contains()` → `.evenOdd` (preserve hit-test); the
   geometry-default rendering bridge → `.nonZero` (SwiftUI default). Document the
   dual default so it isn't surprising.
3. **Built-in `strokeBorder`** stays analytic in v1 (do not retrofit the
   mask-intersection onto built-ins; avoids touching pinned fixtures).
4. **Reuse identity:** `Boxed<Path>` only (no extra `contentToken`) — already
   in-tree, matches `_boxedDrawMetadata`.
5. **Curves:** ship full de Casteljau flattening in v1 (needed by
   `addEllipse`/`addRoundedRect`), tolerance-based recursive subdivision.

## 5. Phased plan (each phase verified by individual `--filter` runs only)

> **Verification discipline:** a hanging test is being fixed concurrently.
> **Never** run `bun run test` / the full org or native gate. Use only
> `swiftly run swift test --filter <Suite>[/<test>]` and the individual policy
> scripts (which are independent of the hanging suite).

- **Phase 0 — dead-param cleanup.** Remove/implement the unused
  `strokeBorder _: Bool` in `insetBounds` (`ColorResolution.swift:170–173`); fix
  call sites (`ColorResolution.swift:14`, `Borders.swift`). *Verify:* `--filter
  SwiftTUITests.CircleEllipseCapsuleTests` stays byte-identical green.
- **Phase 1 — extend `Path`.** Curve cases, `closeSubpath()`, `FillRule`,
  `FillStyle`, `contains(_:fillRule:)`, `flattened(tolerance:)`, SwiftUI
  constructors. *Verify:* new `SwiftTUICoreTests.PathConstructionTests`
  (nonZero-vs-evenOdd on a self-intersecting star; flatten segment counts;
  bounding rect over curves) + `./Scripts/check_foundation_free_layers.sh`.
- **Phase 2 — `ShapeGeometry.path` case + compile-fix the 6 switches.** Stubs
  (bounding-rect fallback) allowed so the build is green. *Verify:* `--filter
  SwiftTUICoreTests.RasterizerTests` stays green (built-ins never emit `.path`).
- **Phase 3 — reuse/perf plumbing.** Confirm `indirect`+`Boxed` O(1) reuse; teach
  `NodeSignature` to carry the box pointer (not the `[Element]`) for `.shape(.path)`.
  *Verify:* `--filter SwiftTUICoreTests.RasterizerTests` incremental==fresh matrix
  incl. a path-vertex mutation + an unchanged-path-frame reuse row;
  `./Scripts/check_concurrency_safety_policies.sh`.
- **Phase 4 — path FILL** (Route B then Route A), shared `pathContains` core.
  *Verify:* new `SwiftTUITests.PathFillTests` — filled triangle interior lit /
  corner empty; pentagram differs nonZero vs evenOdd; Route A silhouette == Route B.
- **Phase 5 — path STROKE + strokeBorder.** *Verify:* new
  `SwiftTUITests.PathStrokeTests` — ring ≠ body; `strokeBorder` stays strictly
  inside the placed frame.
- **Phase 6 — `Shape.path(in:)` + built-in defaulting + path `inset`.** Override
  `geometry` in the 5 built-ins (no path routing). *Verify:* `--filter
  CircleEllipseCapsuleTests` + `CircleAspectFixtureTests` +
  `ShapeInsetAccumulationTests` stay green; new `PathCustomShapeTests` proves a
  `struct Tri: Shape` composes with `.fill`/`.stroke`/`.strokeBorder`/
  `.foregroundStyle` and `inset(by:)` accumulates byte-stably.
- **Phase 7 — foregroundStyle equivalence + `BorderMask`-to-path.** *Verify:* new
  `PathForegroundOverloadTests` (nil-style == explicit == inherited) + a
  masked-background-to-path test.
- **Phase 8 — frame-reactivity proof.** *Verify:* new
  `SwiftTUITests.PathFrameReactivityTests` — rasterSurface re-projects across
  `RunLoop` ticks for a frame-size-bound custom path; and/or a Core incremental
  frame-size-mutation row.
- **Phase 9 — baseline + DocC + gates.** Regenerate
  `Scripts/generate_public_api_inventory.sh`; classify new symbols in
  `docs/public_api_overrides.yml`; **reverse** the `Shapes.md:40` "no `path(in:)`
  / no `FillStyle`" non-goals and document custom paths as sub-cell-quantized
  (not analytic-bit-exact) + path `inset`/`strokeBorder` semantics; add `///`
  summaries. *Verify (each individually, never the full gate):*
  `generate_public_api_inventory.sh --check` (slow, **non-hanging**),
  `check_foundation_free_layers.sh`, `check_concurrency_safety_policies.sh`.

## 6. Risk register

- **Perf (highest):** a non-`indirect`/non-`Boxed` payload value-copies the
  whole `[Element]` into `NodeSignature` per node per frame. Mitigation =
  `indirect`+`Boxed`+pointer-carrying signature; **ship Phase 3 together**.
- **Two-route silhouette divergence:** Route A/B must share one inside-test and
  the exact `px*2+0.5,py*4+1.5` convention; Phase 4 asserts agreement.
- **Aspect-fold omission:** the `width/2,height/4` fold is mandatory or paths
  distort on non-2:1 metrics; the path-circle consistency test is **loose**
  (within 1–2 cells), never byte-exact.
- **`assertionFailure` trip:** route `.path` explicitly before the curved/rect
  branches; never let it reach `curvedShapeContains` (`:165`).
- **Inset trap:** path `inset` = scale-into-frame-inset bounds, **not** the
  uniform bbox contraction; document as approximate, never promise offsetting.
- **clipShape scope creep:** general arbitrary-path `.clipShape` requires
  generalizing the rectangular clip + re-proving the off-screen-elision "fully
  clipped" invariant. **Out of scope** (designed follow-on). Ship fill / stroke /
  strokeBorder / foregroundStyle / `BorderMask`-to-path.
- **Baseline staleness:** classify the new `ShapeGeometry.path` case in
  `public_api_overrides.yml` or `--check` fails as pending-review; its slowness
  is **not** the concurrent hang.
- **One Path only:** extend the hit-test `Path`; `contains()` selects rule
  (evenOdd hit-test default, nonZero rendering).
- **Animatable over-promise:** defer `Path: Animatable` (morphs only well-defined
  at equal element counts); parameterized shapes animate via `AnimatablePair`.

## 7. Gates / policy checklist

- **Foundation-free (CRITICAL):** all new Core/Views code uses stdlib + the libc
  shim only; verify with `check_foundation_free_layers.sh` (transitive trace, not
  just the prek grep).
- **Concurrency:** no `@unchecked Sendable` / `nonisolated(unsafe)` / `@safe`;
  `Path`/`FillRule`/`FillStyle` are plain `Sendable` value types.
- **Public-API baseline:** regen + override-classify the new public symbols.
- **Public-surface policies:** `ShapeGeometry` is geometry data (a new case is
  fine, not a `*Style`); `Path` is a value type (no AnyView/erasure concern).
- **DocC:** reverse `Shapes.md` non-goals in lockstep; doc-comment ratchet.
- **Fixtures:** none added by hand; built-ins unchanged ⇒ their fixtures must not
  change.
- **Child-repo workflow:** code + `Shapes.md` (HEAD-as-built) land in the
  `swift-tui` submodule; this plan stays in the org root `docs/`; record the pin
  in the root after pushing the child.

## 8. Out of scope (designed follow-ons)

General arbitrary-path `.clipShape` / `.mask`; `Path: Animatable` morphing;
`addArc` (+ Foundation-free `Angle`); `trim(from:to:)`; true polygon offsetting
for inset; retrofitting built-in `strokeBorder` onto the mask-intersection path.
