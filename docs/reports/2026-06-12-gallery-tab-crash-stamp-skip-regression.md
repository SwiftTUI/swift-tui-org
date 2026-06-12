# Gallery tab-click crash: stamp-skip fast-path unsoundness (found + fixed)

**Date:** 2026-06-12 ·
**Regression:** swift-tui `0b041764` ("perf: skip runtime-ID restamping of fully
stamped subtrees", 2026-06-11) ·
**Fix:** swift-tui `5d64c1de` ("fix: withdraw stamp completeness on
count-mismatched applies")

## Symptom

Clicking a tab in the gallery (dev overlay, `swift run`, debug) crashed with
SIGTRAP: `ViewNode.assertResolvedStampsCoherent` (`ViewNode.swift:550`) during
toolbar late-preference reconciliation in the frame tail. Release builds would
not crash; they would silently carry incoherent runtime-node-ID stamps.

Headless repro: expect + PTY driving the overlay gallery binary
(arrow-right/Enter, then SGR mouse clicks on the tab row); deterministic,
crashes <15 s after launch.

## Root cause (bisect-confirmed)

Bisect across `a93112b3 → 0b041764 → 0b9b4c23 → 2b05d0fa → e9b9d00e` with
content-verified builds (`nm | grep StampsCoherent` after the stale-`.build`
skew trap fired twice): clean at `a93112b3`, crashing from `0b041764` onward.
Part 0 and Part A are not implicated.

Mechanism: the gallery's `.toolbar(style: .defaultBottom)` host re-resolves
`ToolbarScopeNode`/`ToolbarContentNode` with **captured, already-resolved
main-tree children spliced in** (`Toolbar.swift` `reconciledToolbarHost`).
When the stamping walk's count guard is unmet at such a splice (live children
cannot be paired with value children), the walk skipped the recursion but the
**unconditional tail `recomputeSubtreeRuntimeNodeIDsStamped()` still marked
the subtree complete** — over child stamps written by *other* live nodes. The
committed lie then qualified the subtree for the fully-stamped fast path on a
later apply: root stamp matched the live node, the interior diverged (assert:
value `ViewNodeID(204)` vs live `ViewNodeID(132)` at
`App/window/Layout[0]/base/content/TabBody` — two live nodes for one
identity, one a child-less stub on the reconcile path).

`subtreeRuntimeNodeIDsStamped` recorded only *that* stamps exist, not *which
live pairing* wrote them; the fast-path guard checks coherence only at the
root. The `AnimationTransitionOverlay` tolerance ("overlay trees never
re-enter graph applies") does not extend to the toolbar reconcile, which does
re-enter `ViewNode.apply`.

## Fix

`resolvedWithRuntimeNodeIDs` now **withdraws the completeness claim**
(`markSubtreeRuntimeNodeIDsUnstamped()`) whenever the count guard is unmet.
Unverified splices stay on the slow restamping path until a count-aligned
apply verifies them; count-aligned regions keep the fast skip. The previously
checked-in test that encoded the unsound expectation
(`countMismatchedApplyRecomputesStampedFlag`) is inverted into the regression
test (`countMismatchedApplyRefusesStampedFlag`).

Verified: red→green unit test; gallery PTY repro clean (no SIGTRAP, no
assert output, no new crash logs); swift-tui repo gate PASS; gallery suite
green ungated; gated (`GALLERY_RUNTIME_TESTS=1`) shows only the pre-existing
overflow-physics stall (fails identically at pre-regression `a93112b3`).

## Why no gate caught it

1. **swift-tui repo gate:** `RuntimeNodeIDStampingTests` are hand-built-tree
   unit tests; no composed toolbar + tab-switch multi-frame coverage. Worse,
   the suite *encoded* the unsound count-mismatch behavior as expected.
2. **Gallery's own click test** ("clicking a gallery tab switches tabs
   without crashing") passes against the broken framework: a single
   cold-graph switch never reaches the second reconcile against warm live
   children that the bug requires; the live app idles on the animating logo
   tab, which warms exactly that state before the first click.
3. **No automated surface runs the gallery tests at all:**
   `check_examples.sh` (what `//:org_full` and examples CI run) only builds
   the gallery (`swift test` only for WebHostExample/three-hosts-demo);
   `check_examples_focused_tests.sh` — the only script that runs gallery
   tests — is wired to no Bazel target and no CI (`bun run check:focused`,
   manual only); the runtime/PTY tests additionally sit behind
   `GALLERY_RUNTIME_TESTS=1`, which nothing sets.

## Follow-ups (tracked)

- Wire the gallery test suite into an automated gate (org pretag/worktree
  gates and/or examples CI), including a decision on `GALLERY_RUNTIME_TESTS`.
- Triage the pre-existing gated failures: overflow-physics stage-clock stall;
  quarantined palette focus-region count test.
- Re-run the stamp-skip A/B (synthetic-narrow-invalidation, sheet-open) to
  quantify how much of `0b041764`'s win (resolve_ms −15/−20 %) survives the
  soundness fix; revisit per the 2026-06-12 next-phase ranking if eroded.
- Standing trap, third occurrence: SwiftPM stale-`.build` ABI skew after
  swapping framework sources under an existing build (SIGSEGV in
  `EnvironmentValues` setters from stale test bundles). `rm -rf .build` is
  the only reliable reset; content-verify binaries (`nm`) before trusting a
  bisect step.
