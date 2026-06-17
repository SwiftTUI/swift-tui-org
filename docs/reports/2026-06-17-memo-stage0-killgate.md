# Memoized Body Re-evaluation — Stage 0 Results & Kill-Gate

- **Date:** 2026-06-17
- **swift-tui:** `2fcff87a` (Stage 0 diagnostics + a Tier-2 public-init follow-up)
- **Design:** [2026-06-17-002-memoized-body-reevaluation-proposal.md](../plans/2026-06-17-002-memoized-body-reevaluation-proposal.md)

## What landed

- `MemoValueComparator` (`SwiftTUICore`) — layered structural value-equality:
  `Equatable` fast path (the `StateSlot` existential-open trampoline) → reference
  identity → `Mirror` field-wise (skipping `@State`/`@Binding`/… wrapper storage)
  → **blocked** for closures / `AnyView` / opaque existentials. No `unsafe`, no
  Foundation. Unit-tested.
- `MemoSkipTrace` (`SWIFTTUI_MEMO_TRACE`, DEBUG, inert by default) — per-frame
  `[MEMO-TRACE]` histogram, modeled on `ReuseDenialTrace`.
- The `resolveView` hook + **shadow oracle**: for each recomputed node an
  ancestor reached (not itself invalidated), compare the new view value to the
  prior committed value; a structurally-equal candidate that passes the non-dirty
  reuse guards is *verified* by recomputing and asserting the output equals the
  prior committed output — sound matches count as `addressable_memo_skip`,
  mismatches as `unsound_skip`.
- Gates nothing; release is untouched (`#if DEBUG`, env-gated). Full repo gate
  green. A Tier-2 follow-up kept `SemanticExtractor`'s public `init()` stable
  (moved the warnings flag to a `package init`) — the item-2a change had
  expanded the public surface and the full gate had not run after it landed.

## Measurement (sync, 2 iters, interaction frames)

| scenario | computed/frame | **addressable (sound, verified)** | unsound | blocked (closures) |
| --- | ---: | ---: | ---: | ---: |
| `text-input-editing` | 136 | **98 (72%)** | 0 | 0 |
| `gallery-tab-switch` | 183 | **31 (17%)** | 6 | 11 |
| `file-browser-selection` | 352 | **42 (12%)** | 36 | 72 |
| `synthetic-narrow-invalidation` | 16 | 1–2 | 0 | 3 |

`addressable_memo_skip` counts only candidates whose recomputed output was
**byte-identical** to the prior committed output — i.e. nodes that could be
memoized with provably no behavior change.

## Kill-gate decision: PROCEED

Sound addressable skips are far from zero on interaction frames (text-editing
memoizes 72% of recomputed nodes; the static form is verified identical). The
design's stop criterion ("addressable ≈ 0 on interaction frames") is not met.
**Proceed to Stage 1.**

## Two findings that shape Stages 1–2

1. **The shadow oracle's `unsound_skip` alarm fires (file-browser 36/frame).**
   This is the design working as intended: view-value equality + the *coarse*
   "not-self-invalidated" proxy is **not** a sound skip condition. Those 36
   nodes have an equal view value but a changed body output — they read dynamic
   state whose change reader-attribution did not surface as the node's own
   invalidation. **Stage 2's gate must AND view-value equality with a real
   dependency-clean check** (the node's `DependencySet` / dependency-value
   snapshot vs the frame's changed set), not merely "identity ∉ invalidated
   set." (`addressable_memo_skip` already excludes these; under the naive proxy
   they would be *wrong* skips.) This empirically mandates the design's
   "value-equal AND deps-clean" two-halves requirement.
2. **The closure ceiling is real but bounded** — `file-browser-selection` blocks
   72/352 (≈20%, the Button rows), `gallery-tab-switch` ~6%, `text-input-editing`
   0% (pure-value static form). The `EquatableView`/`.equatable()` opt-in
   (Stage 3) is the escape valve for author-certified interactive leaves.

The oracle has proven teeth on real scenarios (the 36 mismatches), so a separate
adversarial closure-capture fixture is not needed for soundness coverage.

## Next: Stage 1

Store the comparable view value (and a dependency-*value* snapshot) on `ViewNode`
as production state — `Checkpoint` parity, wrapper-field exclusion, per-type
field-plan cache — in compare-only mode, keeping the shadow byte-identity
assertion live in CI. No behavior change; measures the memory cost.
