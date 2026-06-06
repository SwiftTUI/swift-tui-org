# Right-aligned controls in an HStack are not mouse-activatable

**Date:** 2026-06-06
**Scope:** `SwiftTUI/swift-tui` runtime — pointer interaction-region / identity
derivation for controls placed after a `Spacer()` in an `HStack`. Real product
bug: such controls swallow no click of their own; the click dispatches the wrong
action.
**Severity:** High (right-aligned buttons are silently unclickable via mouse).
**Status:** Root-caused, not fixed. Fix is framework-level (interaction-region /
identity derivation).
**Discovered while:** making `swift test` for the gallery example pass (the gated
todo-delete suites). Gating shipped at `swift-tui-examples@67f24a1`.

---

## Symptom

A `Button` (or `Toggle`) placed **after a `Spacer()` in an `HStack`** does not
get its own pointer interaction region. A primary mouse click at the control's
rendered cell does **not** invoke the control's action — it dispatches the
**parent `HStack`'s** action instead. Affected gallery controls (confirmed):

- `TodoTab` row delete `×` — `HStack { Toggle(title); Spacer(); Button("×") }`.
  Clicking `×` does not delete the row.
- `TodoTab` footer `Clear ✓` — `HStack { Button("+ New task"); Spacer(); Button("Clear ✓") }`.
  Clicking `Clear ✓` does not clear done items.

Left-packed controls work (gallery **tabs** activate fine — the tab bar has no
`Spacer`). The bug correlates with a control positioned after a `Spacer`.

## Reproduction

Fully reproducible **in memory** (no PTY) by driving `RunLoop.run()` with a
scripted primary mouse down+up at the right-aligned control's rendered cell.

1. Render `GallerySelectionSeedHarness(initialSelection: .todo)` (or any
   `HStack { …; Spacer(); Button(action) }`).
2. Compute the right control's cell from the placed tree / rendered surface — the
   coordinate is **correct** (verified: probe and live render agree, e.g.
   `×` at `(77, 13)`).
3. Send `.mouse(.down(.primary), at: cell)` then `.mouse(.up(.primary), at: cell)`.
4. Observe: the control's action does not run.

A two-control scope check confirmed generality: both `Clear ✓` (right Button in a
**two-Button** HStack) and the row `×` (right Button in a **Toggle+Button**
HStack) fail — so it is **not** Toggle-specific.

## Root cause (instrumented evidence)

Temporary `print` instrumentation in
`RunLoop+PointerHandling.handleMouseDown/handleMouseUp` plus a dump of
`latestSemanticSnapshot.interactionRegions` at the click cell showed:

```
down cell=(77,13): matching interaction regions (high→low hit-test order):
  order=132 rect=(76,13) 3×1  id=…/ID[uuid]/HStack[2]      ← the only specific region
  order=3   rect=(0,0) 80×23  id=…/content
  order=0   rect=(0,0) 80×24  id=…<root>
up: armed route == HStack[2]; hitTarget route == HStack[2]; match=true
    localActionRegistry.dispatch(HStack[2]) handled=true   ← wrong action, not the ×'s
```

Key facts:

- There is **no distinct interaction region for the `×` Button**. The only
  specific region covering the `×` cell is `…/HStack[2]` (the parent HStack
  identity), rect `(76,13) 3×1` (the `×` area).
- The press/release machinery itself is sound: `armedPointerRouteID` is set on
  down, the up hit-tests to the same route (`match=true`), and
  `localActionRegistry.dispatch(...)` returns `handled=true` — but for the
  **parent HStack identity**, so the wrong (or no-op) action fires.
- The activation path is otherwise correct: the *passing*
  `galleryCommandPaletteRowsStayClickable` test clicks a palette row via direct
  `runLoop.handle(.input(.mouse(…)))` and it activates — because a palette row is
  a single control with no sibling collision. The defect is the right-aligned
  control's region/action being attributed to the parent `HStack` identity rather
  than to a distinct child identity.

Conclusion: **the trailing (post-`Spacer`) control's interaction region is
emitted with the parent `HStack`'s identity instead of its own**, so the
`localActionRegistry` entry hit by the click is the wrong one.

## Workarounds attempted (and why they failed)

- **Separating press and release across render cycles** (down → await a frame →
  up): no effect. The press is already correctly armed to `HStack[2]`; the
  release dispatches `HStack[2]`'s action. So it is not a sequencing/coalescing
  issue — it is identity/region attribution.

No consumer-level workaround: the controls are correct SwiftUI-shaped code
(`HStack { … ; Spacer(); Button(…) }`); the wrong identity is assigned by the
framework.

## Suspected fix surface

- Interaction-region emission in the semantics phase and `HStack` layout's
  identity propagation: a control positioned after a `Spacer()` must emit its
  interaction region (and `localActionRegistry`/focus entry) under its **own**
  child identity, not the parent `HStack`'s. Investigate how the trailing child's
  identity collapses to the `HStack` when a flexible `Spacer` precedes it.
- Verify there isn't an identity collision among siblings (Toggle + Button) in
  the same `HStack` — confirm each sibling control gets a distinct positional
  identity and a distinct interaction region.

## Suggested regression test (framework)

Add a `SwiftTUITests` test that renders `HStack { Button("A"){flagA}; Spacer();
Button("B"){flagB} }`, drives a primary down+up at each button's cell through
`RunLoop.run()` (or `runLoop.handle`), and asserts the **correct** flag flips for
each — pinning that a trailing, post-`Spacer` control activates its own action.

## Related

- Gallery gating that surfaced this: `swift-tui-examples@67f24a1`
  (`realTerminalHostDeletingTopTodoRowKeepsTodoVisible` and the in-memory
  `deletingTopTodoRowKeepsTodoSelected`, which under-asserted — it only checked
  "stayed on Todo", never that the row was actually deleted).
- Sibling report: `2026-06-06-geometryreader-autonomous-animation-bug.md`.
