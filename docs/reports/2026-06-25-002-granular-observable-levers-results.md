# Granular Observable Support — Implementation Results (Levers A/B/C)

- **Date:** 2026-06-25
- **Status:** Lever A + Lever C **SHIPPED** to `swift-tui` main (flag-gated,
  default OFF). Lever B **measured null-result** (no code change).
- **Plan:** [`docs/plans/2026-06-25-001-granular-observable-support-plan.md`](../plans/2026-06-25-001-granular-observable-support-plan.md)
- **Code:** `swift-tui` commits `c12bd928` (Lever A), `9ec7ff06` (Lever C), on
  base `2126c6f4`.

## What shipped

| Lever | Flag (default OFF) | Change |
| --- | --- | --- |
| **A** | `SWIFTTUI_PRECISE_OBSERVATION_FIRING` | `observationChangeDirtyNodeIDs` returns only the precise firing node — drops the object-token co-reader union. |
| **C** | `SWIFTTUI_OBSERVABLE_KEYPATH_INVALIDATION` | Additive `(object, keyPath)` dependency index; narrows the union to same-key-path co-readers (keeps a non-firing `\.hot` peer, spares `\.cold`/`\.rare`). Falls back to the object union unless every co-reader is key-path-attributed. |

Both default OFF and are byte-identical to the legacy union when off (verified:
the full gate's flag-off suites pass unchanged). Lever A takes precedence over
Lever C when both are enabled.

## Measurement (release, `synthetic-observable-fanout`, rows 12×4)

Per-frame `resolved_computed` on a hot-mutation click frame, from `frames.tsv`:

| config | click recompute | reused |
| --- | ---: | ---: |
| `bindable-fanout`, all flags OFF (legacy union) | **76/72** | 0/72 |
| `bindable-fanout`, Lever A on | **44/72** | 32/72 |
| `bindable-fanout`, Lever C on | **44/72** | 32/72 |
| plain-body `fanout` (baseline) | **44/72** | 32/72 |

A new `bindable-fanout` shape was added to the scenario
(`TERMUI_PERF_OBSERVABLE_SHAPE=bindable-fanout`) because the existing plain-body
`fanout` shape does **not** exercise the union (plain `model.hot` reads record no
object token), so neither lever moves it — by design.

### Reading the numbers

- The object-token union forces a **full-tree recompute** (76/72, zero reuse)
  for `@Bindable` fan-out. Both levers drop it to **44/72** — exactly the
  plain-body baseline. So the union was the entire `@Bindable`-vs-plain
  difference, and both levers eliminate it.
- Lever A and Lever C converge on 44/72 here: each `\.hot` cell fires on its own
  `onChange`, and Lever C's same-key-path co-readers are those same `\.hot`
  cells. Lever C's distinguishing value (re-dirtying a `\.hot` peer that did
  *not* fire) is proven by unit test, not visible in this scenario.

## Lever B — measured null-result (the structural-sibling premise is disproven)

The plan hypothesized a third lever: "narrow structural sibling re-resolution",
where clean `\.cold`/`\.rare` cells re-resolve when a `\.hot` sibling dirties.
**Measurement disproves this.** On a click frame (44/72 computed, via
`SWIFTTUI_REUSE_TRACE`):

```
dirty=17          # the ~16 hot cells + root — necessary (they read the change)
stale-snapshot=13 # the hot cells' ancestor chain re-running cheap layout bodies
suppressed=13     # a CONSTANT focus/press reuse-suppression, present every frame
```

and **32 reused = exactly the 32 cold/rare cells.** The clean siblings are
**already reused** by the existing reuse machinery. There is no "clean sibling
re-resolution" to fix:

- For `@Bindable` fan-out, the union *was* the sibling-re-resolution cause, and
  **Lever A is the fix** (76→44).
- For plain-body reads, siblings were never over-invalidated (the union never
  touched them).

The residual 44 is **necessary** (hot cells) + **ancestor reconciliation**
(`markDirty` → `invalidateCachedSnapshotUpward`, cheap layout-container bodies) +
a **constant focus/press `suppressed=13` baseline** that is orthogonal to
observables and risky to touch (focus/press reuse-suppression scope). No safe,
observable-specific structural fix exists, so Lever B ships no code.

The every-frame `suppressed=13` is the one genuinely click-independent overhead
and a possible *separate* focus/press perf follow-up — explicitly out of scope
here.

## Status of the flags

Both flags are **OFF by default**, pending a soak (gallery + gif-editor across
the five hosts) for the deferred/conditional-read residual the plan documents.
The flip-to-default-on criteria and rollout mirror `ReaderAttributionConfiguration`.
