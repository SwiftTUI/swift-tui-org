# Reuse-Trace Productization + Sheet-Cone Confirmation

- **Date:** 2026-06-15
- **Status:** Implemented in `swift-tui` (engine file sink + harness capture +
  test); org pin bump pending.
- **Goal:** [perf phase completion goal](../plans/2026-06-15-001-perf-phase-completion-goal.md),
  **Item F** — "productize the breakdown probes … step one of the infra PR is to
  fix [the reuse-trace] gap" — and the prerequisite for **item 4b**
  (invalidation-cone narrowing).
- **Supersedes the empty-trace conclusion in:**
  [item-E frontier design + reframing](2026-06-15-item-e-frontier-design-and-reframing.md)
  (§ "Reuse-trace result").

## Headline

1. **The reuse/cone trace was never broken.** It fires correctly on the
   **release** perf path. Re-running `SWIFTTUI_REUSE_TRACE=1` on
   `sheet-open-latency` (rows 176, `--modes async`) produced **100
   `[REUSE-TRACE]` lines** with the cone diagnostic intact. The item-E report's
   "no `[REUSE-TRACE]` lines / `reasonCounts` empty every frame" was an
   **observation/capture artifact**, not a code gap: the trace writes only to
   **stderr** (via `write(STDERR_FILENO, …)`), which is *not* one of the run's
   captured artifacts (it is not in `frames.tsv`) and is trivially lost among
   build/runtime output.

2. **The cone source is now measured, not inferred.** On the ~18 ms open frames
   the dominant reason is `invalidation-conflict=890`, with
   `invalidated: App/sheet-open-latency/Layout[0]` — i.e. the background's
   ~890 nodes deny reuse because they are **descendants of the toggled `@State`
   owner** (`Layout[0]`, the `PerfSheetLatencyProbeView` body VStack). On close,
   the cone is `__presentationTrigger` + `VStack[0]` + the portal host.

3. **The fix is durability, not recording.** Added an optional file sink so the
   diagnostic is a captured artifact (`reuse-trace.log`) next to `frames.tsv`,
   auto-enabled by the perf harness whenever the trace is armed.

## Why the item-E run looked empty

The trace records at the per-node recompute site
(`ViewFoundation.resolveView`, reuse-return) and flushes the per-frame histogram
to **stderr** in `ViewGraph.beginFrame()`. The render runs **in-process** inside
`termui-perf`, so those lines land on the harness process's own stderr. The
structured run data (`frames.tsv`, `summary.json`, …) is written to files; stderr
is not collected. So a run whose stderr was redirected/`2>/dev/null`'d, buried
under `swift run` build output, or simply not inspected shows "no trace" while
the histogram was in fact being written and discarded.

Crucially, `recordReuseDenialIfTracing` **already** categorizes cone denials:
when a node would otherwise be reuse-eligible but its identity intersects the
invalidation set, it records `invalidation-conflict` and the invalidated identity
paths (`ViewGraph.swift`). So the premise that "the trace only catches leaf-level
denials, therefore empty ⇒ cone-driven" was incorrect — the trace catches the
cone case directly, and now we can read it.

## Measured cone (release, sheet rows 176, async)

Per-frame `[REUSE-TRACE]` excerpts (open frames):

```
invalidation-conflict=890 visited=3 dirty=2 env-mismatch=1 stale-snapshot=1
  | env-diffs: style=1 val:…ForegroundStyleKey=1
  | invalidated: App/sheet-open-latency/Layout[0]
```

- **Dominant reason:** `invalidation-conflict` (~880–896/frame on open), rooted
  at `Layout[0]`. The `.paletteSheet(isPresented: $sheetPresented)` modifier
  reads `isPresented.wrappedValue` **inside the owner's body**, so `Layout[0]`
  (the owner) is a legitimate reader → invalidated → and because the background
  grid is a **descendant** of `Layout[0]`, `reusableSnapshot`'s
  `identity.isDescendant(of: invalidatedIdentity)` guard denies reuse to the
  entire background. **This is the cone.**
- **Minor reasons:** `env-mismatch` on `ForegroundStyleKey` (a handful of nodes),
  `stale-snapshot`, `visited`, `dirty`, `no-node`, `suppressed` — all small
  relative to the ~890 conflict.

### SPIKE A/B — confirms the lever

Re-run with `TERMUI_PERF_SHEET_SPIKE=1` (toggle `@State` owned by a **sibling**
of the background instead of an ancestor):

| shape | max `invalidation-conflict` / open frame |
| --- | ---: |
| default (toggle owner = **ancestor** of background) | **890** |
| spike (toggle owner = **sibling** of background) | **14** |

Moving the toggle off the background's ancestor chain cuts cone-driven recompute
**890 → 14 (−98.4%)**. This is direct, measured proof that the dominant sheet
residual is the `@State`-owner-ancestor **structure** — the territory of
reader-attribution / item 4b (G2 + G3), **not** the force-queue (Item E) and
**not** head bookkeeping (Items A–C, all downstream of the cone).

## The fix (in `swift-tui`)

- **Engine file sink** — `ReuseDenialTrace` gains `SWIFTTUI_REUSE_TRACE_FILE`:
  when set to a writable path, each `[REUSE-TRACE]` line is appended there
  (`open(O_WRONLY|O_CREAT|O_APPEND)`, EINTR-safe, compiled out on WASI per the
  `Standard.File` precedent) instead of stderr. Unset ⇒ unchanged stderr
  behavior. Inert when the trace is off.
- **Harness capture** — `TermUIPerf` (`RunCommand` →
  `PerfScenarioRunner.configureReuseTraceArtifact`) defaults the file sink to
  `<artifacts-root>/reuse-trace.log` whenever `SWIFTTUI_REUSE_TRACE` is armed and
  the operator has not set an explicit path. The diagnostic is now a captured
  artifact, correlated with the run, surviving stderr loss.
- **Test** — `ReuseDenialTraceTests` (4 cases): inert-when-disabled, file sink
  captures reasons + the invalidated cone source, empty histogram opens no file,
  dump resets per frame. The trace previously had **no** tests.

**End-to-end validation:** the standard command + `SWIFTTUI_REUSE_TRACE=1` with
**stderr discarded** (`2>/dev/null`) now writes `reuse-trace.log` containing
`invalidation-conflict=890 … invalidated: App/sheet-open-latency/Layout[0]`.

## Disposition

- **Item F "fix the reuse-trace release-path gap" — DONE.** The cone diagnostic
  is reliable and now lands as a durable run artifact. The remaining Item F
  productization (create-split probe, `SWIFTTUI_PROFILE` sub-phase integration)
  is still future infra and not blocked by this.
- **Item 4b prerequisite — MET.** The cone diagnostic 4b needs is now trustworthy
  and has already produced its first result: the open-frame cone is the
  `@State`-owner-ancestor case (`Layout[0]`), de-amplified 98.4% by the SPIKE
  sibling shape.

## Next work (4b, the actual sheet lever)

Reduce the open-frame cone so the background is not a descendant of the toggled
`@State` owner's invalidation. Two non-exclusive directions, now evidence-backed:

1. **Reader-attribution / presentation-read scoping (G2-adjacent):** the
   presentation modifier's read of `isPresented.wrappedValue` attributes the
   invalidation to the owner body (`Layout[0]`). Investigate attributing the
   presentation toggle to the presentation subtree / trigger leaf rather than the
   owner that also roots the background — the same "move the hot read into a
   trigger leaf" pattern that won for popover and `isFocused`.
2. **Reuse under ancestor invalidation (G3):** allow the disjoint background
   subtree to be reused even though an ancestor (`Layout[0]`) is invalidated,
   via the transitive dependency-summary work the gap analysis sequences last.

The SPIKE knob is the upper-bound oracle (890 → 14); a shipped fix should
approach it on the real `.paletteSheet` shape without the throwaway
restructuring.
