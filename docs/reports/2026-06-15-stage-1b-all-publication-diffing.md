# Stage 1B `.all` Publication Diffing

- **Date:** 2026-06-15
- **Status:** Stage 1B accepted as baseline; Stage 2 checkpoint scoping is next
- **Plan:** [`2026-06-14-003-frontier-publication-narrowing-plan.md`](../plans/2026-06-14-003-frontier-publication-narrowing-plan.md)
- **Measured code:** `swift-tui` `de49e2df` (`perf: diff runtime publication registrations`)
- **Baseline:** Stage 1A.2 artifact root `/tmp/swifttui-stage1a2-publication-2026-06-15-060316-bb2a047f`
- **Artifact root:** `/tmp/swifttui-stage1b-publication-2026-06-15-063712-de49e2df`
- **Diagnostics gate:** `SWIFTTUI_PUBLICATION_DIAGNOSTICS=1`

## What Changed

Stage 1B keeps unavoidable root-evaluation frames semantically `.all`, but makes
their runtime-registration publication cheaper when the registration graph has
not changed everywhere.

The implementation adds a committed graph fingerprint for nodes that own runtime
registrations. Each participating `ViewNode` records a mutation generation when
its registration capture resets or when any registry family records a handler or
snapshot. On `.all` publication, the current fingerprint is diffed against the
last committed fingerprint:

- unchanged fingerprints skip restore work;
- changed non-root owners remove and restore only their identity subtrees;
- root-level or unproven changes fall back to the old full reset and restore;
- diagnostics still report publication mode `all`;
- existing `.subtrees` publication behavior is unchanged.

The fingerprint is checkpointed with `ViewGraph`, and each node's registration
generation is checkpointed with `ViewNode`, so discarded frame-head work cannot
advance the committed publication baseline.

## Commands

From `swift-tui`:

```bash
swift test --filter 'ViewGraphCheckpointTotalityTests|RuntimeRegistrationRestoreScopingTests|ViewGraphTests|FrameResolveStateTests|TSVFileSinkTests' --jobs 1

./Scripts/check_concurrency_safety_policies.sh
./Scripts/generate_public_api_inventory.sh --check

swift build -c release --package-path Tools/TermUIPerf --product termui-perf

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
  Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency \
  --modes async \
  --iterations 8 \
  --artifacts-root /tmp/swifttui-stage1b-publication-2026-06-15-063712-de49e2df

TERMUI_PERF_INVALIDATION_TREE_ROWS=40 \
SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
  Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario synthetic-narrow-invalidation \
  --modes async \
  --iterations 20 \
  --artifacts-root /tmp/swifttui-stage1b-publication-2026-06-15-063712-de49e2df
```

## `.all` Restored-Node Work

| scenario | stage | `.all` frames | restored node sum | restored node mean | min | max |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `sheet-open-latency` | Stage 1A.2 | 80 | 19,872 | 248.40 | 234 | 263 |
| `sheet-open-latency` | Stage 1B | 77 | 2,227 | 28.92 | 2 | 234 |
| `synthetic-narrow-invalidation` | Stage 1A.2 | 57 | 21,261 | 373.00 | 373 | 373 |
| `synthetic-narrow-invalidation` | Stage 1B | 57 | 7,534 | 132.18 | 2 | 373 |

The `.all` restored-node total dropped 88.8% on `sheet-open-latency` and 64.6%
on `synthetic-narrow-invalidation`. `.subtrees` publication was unchanged:

| scenario | `.subtrees` frames | Stage 1A.2 restored sum | Stage 1B restored sum |
| --- | ---: | ---: | ---: |
| `sheet-open-latency` | 64 | 15,296 | 15,296 |
| `synthetic-narrow-invalidation` | 300 | 110,400 | 110,400 |

## Aggregate Medians

| scenario | stage | total CPU s | CPU s/frame | input p95 ms | head prepare p50 ms | checkpoint restore p50 ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `sheet-open-latency` | Stage 1A.2 | 0.5153 | 0.02863 | 463.05 | 6.88 | 0.94 |
| `sheet-open-latency` | Stage 1B | 0.4930 | 0.02768 | 439.50 | 7.03 | 0.98 |
| `synthetic-narrow-invalidation` | Stage 1A.2 | 0.2689 | 0.01501 | 212.26 | 2.58 | 1.36 |
| `synthetic-narrow-invalidation` | Stage 1B | 0.2704 | 0.01507 | 214.06 | 2.66 | 1.40 |

The structural publication work dropped sharply. Aggregate CPU/latency moved
only modestly and is mixed on the synthetic case, so the safe conclusion is that
Stage 1B reduces the `.all` registration restore work, not that it delivers a
large end-to-end perf win by itself.

## Interpretation

Stage 1A.2 showed the remaining `.all` frames came from explicit root-evaluation
guards such as focus, pressed, proposal, and root invalidation. Stage 1B does not
weaken those guards. Instead, it keeps the diagnostic and semantic shape of
`.all` frames while avoiding full registration publication when the graph can
prove which registration owners changed.

The first cut is intentionally conservative:

- root-level registration changes still use full publication;
- any missing committed fingerprint uses full publication;
- the diff is node-owner based, not registry-family-specific;
- task publication remains globally republished after scoped restores, matching
  the existing `.subtrees` safety rule.

## Coverage Follow-up

The immediate coverage follow-up is now in
`RuntimeRegistrationRestoreScopingTests`: `.all` diffed publication is compared
against a full rebuild across key/action, termination, pointer/hover, gesture,
gesture state, focus, focused values, scroll, lifecycle, task, preference,
command, and drop registrations. The fixture mutates one non-root sibling,
keeps the diagnostics mode at `all`, verifies only that changed subtree is
restored, and then checks the live registries against a full rebuild.

This is a test-only broadening of the Stage 1B baseline. It does not include a
new perf run. Further Stage 1B specialization should now be limited to cases
where end-to-end perf data shows the remaining `.all` restore work still
matters enough to justify registry-family-specific fingerprints.

Stage 2 checkpoint scoping should still wait until this publication behavior is
accepted as the new baseline.

## Stage 2 Decision Rerun

After adding the broader registry-family coverage, the same diagnostic inventory
was rerun against the same production sources (`swift-tui` `de49e2df`; test-only
coverage changes present).

- **Artifact root:**
  `/tmp/swifttui-stage1b-decision-2026-06-15-104545-de49e2df`
- **Decision:** accept Stage 1B as the publication baseline and proceed to
  Stage 2 checkpoint scoping. Do not start registry-family-specific publication
  fingerprints now.

Publication work stayed stable:

| scenario | `.all` frames | `.all` restored sum | `.all` mean | `.subtrees` restored sum |
| --- | ---: | ---: | ---: | ---: |
| `sheet-open-latency` | 80 | 2,240 | 28.00 | 15,296 |
| `synthetic-narrow-invalidation` | 59 | 7,538 | 127.76 | 110,400 |

Aggregate medians improved modestly from the original Stage 1B run:

| scenario | total CPU s | CPU s/frame | input p95 ms | head prepare p50 ms | checkpoint create p50 ms | checkpoint restore p50 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `sheet-open-latency` | 0.4611 | 0.02562 | 411.38 | 6.60 | 0.39 | 0.89 |
| `synthetic-narrow-invalidation` | 0.2591 | 0.01440 | 204.24 | 2.51 | 0.61 | 1.33 |

The checkpoint columns are now the better next target than publication
specialization. Checkpoint create + restore is roughly 19% of
`sheet-open-latency` head prepare p50 and roughly 78% of
`synthetic-narrow-invalidation` head prepare p50. That points at Stage 2's
checkpoint scoping work, with Stage 1B's publication behavior serving as the
correctness and perf baseline.

## Validation

- `swift test --filter 'ViewGraphCheckpointTotalityTests|RuntimeRegistrationRestoreScopingTests|ViewGraphTests|FrameResolveStateTests|TSVFileSinkTests' --jobs 1`
- `./Scripts/check_concurrency_safety_policies.sh`
- `./Scripts/generate_public_api_inventory.sh --check`
- `swift build -c release --package-path Tools/TermUIPerf --product termui-perf`
- perf inventory commands listed above
