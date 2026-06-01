# Render Pipeline DocC Consolidation Todo

## Goal

Make DocC the canonical developer-facing home for SwiftTUI render pipeline
documentation, while keeping top-level/root docs internal and ensuring all
developer-facing material describes only the current state of `HEAD`.

## Todo

- [ ] Inventory current pipeline-related references before editing.
  - Include DocC pages, `swift-tui/docs/`, `swift-tui/README.md`, root/internal
    `docs/`, and the website pipeline page.
  - Classify each surface as developer-facing, user-facing website, or internal.

- [ ] Create or promote a DocC runtime pipeline article.
  - Preferred home: `swift-tui/Sources/SwiftTUIRuntime/SwiftTUIRuntime.docc/`.
  - Cover the full current callpath: app/scene entry, `RunLoop`,
    `DefaultRenderer`, `RuntimeRenderPipeline`, frame-tail work, commit,
    diagnostics, and host handoff.
  - Describe only current behavior at `HEAD`.

- [ ] Keep `SwiftTUICore.docc/Rendering-Pipeline.md` focused on phase products.
  - Cover `resolve -> measure -> place -> semantics -> draw -> raster -> commit`.
  - Cover `FrameArtifacts` and related symbols.
  - Link to the runtime DocC article for scheduling, cancellation, run-loop, and
    host presentation details.

- [ ] Remove historical context from developer-facing docs.
  - Remove report names, H1/H2/H3/H4 labels, "recent work", "historically", and
    pre-release chronology from DocC, package README content, and website copy.
  - Preserve only current-state behavior, invariants, and diagnostics.

- [ ] Convert `swift-tui/docs/RENDER-PIPELINE.md` to internal-only status.
  - Either replace it with a short internal pointer to the DocC source of truth
    or remove it after updating links.
  - Do not leave it as a parallel developer-facing implementation walkthrough.

- [ ] Update discovery links.
  - Update `swift-tui/README.md`.
  - Update `swift-tui/docs/README.md` to mark internal docs appropriately.
  - Update DocC `See Also` sections.
  - Update website links so developer detail points to DocC.

- [ ] Keep host-contract ownership split clean.
  - Keep host/platform detail in `HOSTS-AND-PLATFORMS.md` or its DocC
    counterpart.
  - Keep the pipeline article focused on the runtime handoff and link out for
    host-specific details.

- [ ] Verify documentation consistency.
  - Run `rg` for stale links to `docs/RENDER-PIPELINE.md`.
  - Run `rg` for historical terms in developer-facing docs.
  - Run `git diff --check`.
  - If DocC build tooling is practical locally, run the DocC build/archive
    command.

## Open Decisions

- [ ] Decide whether `swift-tui/docs/RENDER-PIPELINE.md` should be deleted or kept
  as an internal pointer.
- [ ] Decide whether the runtime DocC article should be named
  `Render-Pipeline.md`, `Rendering-Pipeline.md`, or `Runtime-Render-Pipeline.md`.
- [ ] Decide whether `HOSTS-AND-PLATFORMS.md` should eventually get a DocC
  developer-facing counterpart, or remain internal for now.
