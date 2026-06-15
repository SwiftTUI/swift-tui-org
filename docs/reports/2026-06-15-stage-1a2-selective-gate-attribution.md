# Stage 1A.2 Selective-Gate Attribution

- **Status:** Stage 1A.2 complete; Stage 1B recommended next
- **Plan:** [`2026-06-14-003-frontier-publication-narrowing-plan.md`](../plans/2026-06-14-003-frontier-publication-narrowing-plan.md)
- **Measured code:** `swift-tui` `bb2a047f` (`diagnostics: attribute selective evaluation gates`)
- **Artifact root:** `/tmp/swifttui-stage1a2-publication-2026-06-15-060316-bb2a047f`

## What Changed

Stage 1A.2 adds diagnostic attribution for frames that reach
`nil_selective_evaluation_disabled` before `ViewGraph` can form a dirty
frontier. The frame diagnostics TSV now includes:

```text
runtime_selective_evaluation_disabled_reasons
```

The reasons are emitted from `FrameResolveState` and carried through dirty-plan
diagnostics, runtime publication diagnostics, and the TSV sink. The possible
values are:

- `selective_evaluation_not_enabled`
- `frame_state_force_root`
- `context_force_root`
- `focus_changed`
- `pressed_changed`
- `proposal_changed`
- `root_invalidated`

This is diagnostic plumbing only. It does not narrow or bypass any root
evaluation guard.

## Commands

```bash
swift build -c release --package-path Tools/TermUIPerf --product termui-perf

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
  Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency \
  --modes async \
  --iterations 8 \
  --artifacts-root /tmp/swifttui-stage1a2-publication-2026-06-15-060316-bb2a047f

TERMUI_PERF_INVALIDATION_TREE_ROWS=40 \
SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
  Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario synthetic-narrow-invalidation \
  --modes async \
  --iterations 20 \
  --artifacts-root /tmp/swifttui-stage1a2-publication-2026-06-15-060316-bb2a047f
```

## Publication Mode Summary

| scenario | TSV rows | publication rows | `.all` | `.subtrees` | no publication row | portal root queued |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `sheet-open-latency` | 208 | 144 | 80 | 64 | 64 | 144 |
| `synthetic-narrow-invalidation` | 357 | 357 | 57 | 300 | 0 | 357 |

The Stage 1A identity bridge remains effective: no portal-hosted unmapped sample
is present. The only unmapped samples are application-root shaped:

| scenario | unmapped sample | frames |
| --- | --- | ---: |
| `sheet-open-latency` | `App/sheet-open-latency` | 8 |
| `synthetic-narrow-invalidation` | `App/synthetic-narrow-invalidation` | 20 |

## Dirty Plan Results

| scenario | result | frames | avg `commit_ms` | avg restored nodes |
| --- | --- | ---: | ---: | ---: |
| `sheet-open-latency` | `formed` | 64 | 0.409 | 239 |
| `sheet-open-latency` | `nil_selective_evaluation_disabled` | 80 | 2.578 | 248.4 |
| `synthetic-narrow-invalidation` | `formed` | 300 | 0.451 | 368 |
| `synthetic-narrow-invalidation` | `nil_selective_evaluation_disabled` | 57 | 3.019 | 373 |

`.all` publication still costs roughly 6x-7x the scoped publication frames in
these scenarios.

## Gate Attribution

| scenario | disabled reasons | frames |
| --- | --- | ---: |
| `sheet-open-latency` | `frame_state_force_root,focus_changed` | 64 |
| `sheet-open-latency` | `frame_state_force_root,focus_changed,pressed_changed` | 8 |
| `sheet-open-latency` | `selective_evaluation_not_enabled,context_force_root,proposal_changed,root_invalidated` | 8 |
| `synthetic-narrow-invalidation` | `selective_evaluation_not_enabled,context_force_root,proposal_changed,root_invalidated` | 20 |
| `synthetic-narrow-invalidation` | `frame_state_force_root,focus_changed,pressed_changed` | 17 |
| `synthetic-narrow-invalidation` | `frame_state_force_root,pressed_changed` | 17 |
| `synthetic-narrow-invalidation` | `focus_changed` | 3 |

Aggregated by individual reason:

| scenario | top reason | frames |
| --- | --- | ---: |
| `sheet-open-latency` | `frame_state_force_root` | 72 |
| `sheet-open-latency` | `focus_changed` | 72 |
| `synthetic-narrow-invalidation` | `frame_state_force_root` | 34 |
| `synthetic-narrow-invalidation` | `pressed_changed` | 34 |
| `synthetic-narrow-invalidation` | `selective_evaluation_not_enabled` | 20 |
| `synthetic-narrow-invalidation` | `context_force_root` | 20 |
| `synthetic-narrow-invalidation` | `proposal_changed` | 20 |
| `synthetic-narrow-invalidation` | `root_invalidated` | 20 |

## Interpretation

The remaining `.all` frames are not a safe presentation-identity translation
miss. They are dominated by explicit root-evaluation guards:

- `frame_state_force_root` from the renderer/run-loop root-evaluation path;
- focus/pressed/proposal deltas that currently require a root pass;
- startup or application-root invalidation frames where selective evaluation is
  either disabled or blocked by the root identity.

That makes Stage 1A.2 a decision point rather than a behavior change. The
dominant gates can only be narrowed after proving the focus/pressed/root
semantics do not need a full root walk, and that proof is outside the safe
identity bridge that Stage 1A just landed.

## Next Stage

Move to Stage 1B: make unavoidable `.all` publication cheaper. The current data
shows `.all` is still expensive, but the cause is legitimate root-evaluation
guarding rather than portal frontier loss. Stage 1B should reduce the
registration-publication cost of those root frames without weakening the
selective-evaluation safety gates.

If a later slice wants to challenge the focus/pressed force-root behavior, it
should be scoped as a separate semantic proof with targeted focus/gesture tests,
not folded into Stage 1B's publication-cost work.

## Validation

- `swift test --filter 'FrameResolveStateTests|ViewGraphTests|TSVFileSinkTests' --jobs 1`
- `./Scripts/generate_public_api_inventory.sh --check`
- `./Scripts/check_concurrency_safety_policies.sh`
- `swift build -c release --package-path Tools/TermUIPerf --product termui-perf`
- perf inventory commands listed above
