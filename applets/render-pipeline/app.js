"use strict";

/*
 * SwiftTUI Render Pipeline — developer walkthrough.
 *
 * All content is data-first so the interactive explorer and the static diagrams
 * cannot drift apart. Every `source` string is a repo-relative `path:line`
 * reference into the checked-out `swift-tui` package, verified against HEAD.
 */

/* ------------------------------------------------------------------ */
/* Authored example                                                    */
/* ------------------------------------------------------------------ */

const viewLines = [
  "import SwiftTUI",
  "",
  "struct BuildSummary: View {",
  "  var body: some View {",
  "    VStack(alignment: .leading, spacing: 0) {",
  '      Text("Deploy Queue").bold()',
  "      Divider()",
  '      ProgressView("Release", value: 18, total: 24)',
  '      LabeledContent("Owner", value: "infra")',
  "      Button(\"Ship\") {",
  "        queued += 1   // a state write — schedules a frame",
  "      }",
  "    }",
  "    .padding(1)",
  "    .border(.rounded)",
  "  }",
  "}",
];

/* ------------------------------------------------------------------ */
/* Phase products — the data model (owned by SwiftTUICore)             */
/* ------------------------------------------------------------------ */

const PHASES = [
  {
    key: "resolve",
    type: "ResolvedNode",
    field: "resolvedTree",
    question: "What is in the tree, and who owns it?",
    owns:
      "Authored bodies lowered to nodes, plus the identity projection, StructuralPath, optional entity identity, state ownership, merged environment, view metadata, and runtime registrations.",
  },
  {
    key: "measure",
    type: "MeasuredNode",
    field: "measuredTree",
    question: "How big does each subtree want to be?",
    owns:
      "Subtree sizes negotiated by LayoutEngine under a ProposedSize. No final coordinates exist yet.",
  },
  {
    key: "place",
    type: "PlacedNode",
    field: "placedTree",
    question: "Where does everything land?",
    owns:
      "Final integer-cell frames, content bounds, and placement-time metadata. This is the authority for interaction regions.",
  },
  {
    key: "semantics",
    type: "SemanticSnapshot",
    field: "semanticSnapshot",
    question: "How do focus, pointers, and accessibility route?",
    owns:
      "Focus, interaction, action, selection, scroll, named coordinate spaces, and pointer routing — derived from the placed tree.",
  },
  {
    key: "draw",
    type: "DrawNode",
    field: "drawTree",
    question: "What paint commands describe the frame?",
    owns:
      "Placed nodes lowered into draw commands: borders, backgrounds, effects, and payload paint instructions.",
  },
  {
    key: "raster",
    type: "RasterSurface",
    field: "rasterSurface",
    question: "What does the cell grid look like?",
    owns:
      "Styled terminal cells, continuation-cell handling, and image attachments. Host-neutral grid data — still not terminal bytes.",
  },
  {
    key: "commit",
    type: "CommitPlan",
    field: "commitPlan",
    question: "What side effects must the runtime apply?",
    owns:
      "Lifecycle entries, handler installations, the semantic snapshot, and transaction work the runtime applies after the products are published.",
  },
];

const phaseIndex = Object.fromEntries(PHASES.map((p, i) => [p.key, i]));

/* ------------------------------------------------------------------ */
/* Runtime stages — the scheduling model (owned by SwiftTUIRuntime)    */
/* ------------------------------------------------------------------ */

const STAGES = [
  {
    key: "head",
    product: "FrameHeadDraft",
    covers: ["resolve"],
    codeLines: [3, 4, 5, 6, 7, 8, 9],
    actor: "main",
    headline: "Resolve the dirty frontier into a draft.",
    consumes: "Resolve context, proposal, environment, invalidation set, reuse policy.",
    produces:
      "A FrameHeadDraft: the resolved tree, frame-tail input, staged transaction, render generation, timing clock, and frame context for commit.",
    does:
      "Allocates a render generation, builds a FrameHeadTransaction, creates checkpoints for abortable frames, evaluates the dirty graph frontier (or the root), installs the presentation-portal evaluator, and snapshots retained frame-tail inputs from the previous committed frame.",
    not:
      "Does not measure, place, draw, or touch the terminal. Side effects are staged in the transaction so the frame can still be aborted cleanly.",
    source:
      "swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRendererFrameHeadCoordinator.swift:26",
    status: "resolving frontier",
  },
  {
    key: "animationInjection",
    product: "FrameHeadDraft (updated)",
    covers: [],
    codeLines: [10, 11, 12],
    actor: "main",
    headline: "Sample animation and update the draft.",
    consumes: "The FrameHeadDraft plus the animation controller's state for this frame.",
    produces: "The same draft with sampled animation metadata applied.",
    does:
      "Samples the animation controller, applies the sampled transaction, and updates resolved metadata before any downstream work reads it. Reports whether animation is still pending and whether the frame can be elided before the tail runs.",
    not:
      "Introduces no new phase product. It adjusts the in-flight draft — this is a scheduling stage, not a data stage.",
    source: "swift-tui/Sources/SwiftTUIRuntime/Rendering/RuntimeRenderPipeline.swift:10",
    status: "sampling animation",
  },
  {
    key: "latePreferenceReconciliation",
    product: "Reconciled tail input",
    covers: [],
    codeLines: [5, 13, 14],
    actor: "main",
    headline: "Let placement-dependent state settle before the tail.",
    consumes: "The draft and any root-level presentation state that depends on placement.",
    produces: "An effective tail input the fused tail can read consistently.",
    does:
      "Some authored preferences depend on placement or root presentation state. This stage updates that state before the final tail reads the effective tree, re-running the relevant work rather than publishing inconsistent artifacts.",
    not:
      "Also introduces no new phase product. Like animation injection, it exists to keep the data model consistent across the off-actor boundary that follows.",
    source: "swift-tui/Sources/SwiftTUIRuntime/Rendering/LatePreferenceReconciliation.swift:44",
    status: "reconciling preferences",
  },
  {
    key: "fusedFrameTail",
    product: "MeasuredNode → … → RasterSurface",
    covers: ["measure", "place", "semantics", "draw", "raster"],
    codeLines: [5, 6, 7, 8, 9, 13, 14],
    actor: "tail",
    headline: "Compute five products as one scheduling node.",
    consumes: "The resolved tree and retained frame-tail inputs.",
    produces:
      "Five distinct products in order — measure, place, semantics, draw, raster — plus timing and reuse diagnostics.",
    does:
      "Runs measure → place → semantics → draw → raster. May run inline or on a frame-tail worker depending on strategy and platform. This is the performance node that can leave the main actor because every input is already resolved.",
    not:
      "Does not collapse the products into one type. The five values keep distinct ownership and diagnostics; only their scheduling is fused.",
    source:
      "swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift:4",
    status: "raster surface ready",
  },
  {
    key: "commit",
    product: "FrameArtifacts + CommitPlan",
    covers: ["commit"],
    codeLines: [3, 10, 11],
    actor: "main",
    headline: "Apply policy, publish state, hand off.",
    consumes: "The completed draft and tail output.",
    produces:
      "Either committed FrameArtifacts, or a decision to drop, cancel, or elide the frame.",
    does:
      "Turns a completed draft into a committed candidate: packages lifecycle events, semantic handlers, runtime registrations, transaction effects, and retained tail state, then publishes graph and runtime state on the main actor.",
    not:
      "Does not write terminal bytes or browser frames. Presentation is owned by RunLoop after frame acquisition succeeds.",
    source:
      "swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRenderer+CompletedFrameCandidates.swift:57",
    status: "committed → RunLoop",
  },
];

/* Cumulative phase products available after each runtime stage. */
function productsAfterStage(stageIndex) {
  const available = new Set();
  for (let i = 0; i <= stageIndex; i += 1) {
    for (const phaseKey of STAGES[i].covers) available.add(phaseKey);
  }
  return available;
}

/* Honest, stage-by-stage product preview (no fictional pixels). */
const stagePreview = {
  head: [
    "resolved tree (ResolvedNode)",
    "  VStack #1",
    '    Text("Deploy Queue").bold()',
    "    Divider",
    "    ProgressView  value 18 / 24",
    "    LabeledContent",
    "    Button(\"Ship\")",
    "",
    "no geometry yet · no cells yet",
  ],
  animationInjection: [
    "transaction:",
    "  animation: inherit",
    "  batch: none",
    "",
    "resolved metadata updated",
    "frame can be elided if off-screen only",
    "",
    "still no geometry · no cells",
  ],
  latePreferenceReconciliation: [
    "effective tail input ready",
    "",
    "root presentation state settled;",
    "placement-dependent preferences",
    "will read a consistent tree.",
    "",
    "tail may now run off the main actor.",
  ],
  fusedFrameTail: [
    "measure → place → semantics → draw → raster",
    "",
    "╭────────────────────────╮",
    "│ Deploy Queue           │",
    "│ ────────────────────── │",
    "│ Release ▕███████████▏   │",
    "│ Owner            infra │",
    "│ [ Ship ]               │",
    "╰────────────────────────╯",
    "",
    "RasterSurface: styled 26×8 cell grid",
  ],
  commit: [
    "FrameArtifacts committed",
    "  resolvedTree · measuredTree · placedTree",
    "  semanticSnapshot · drawTree · rasterSurface",
    "  commitPlan · diagnostics",
    "",
    "handed to RunLoop.presentCommittedFrame",
    "→ host writes bytes below this line",
  ],
};

/* ------------------------------------------------------------------ */
/* Change propagation — the corrected invalidation story               */
/* ------------------------------------------------------------------ */

const propagation = [
  {
    title: "A write records intent",
    body:
      "queued += 1 lands in the @State slot via ViewNode.setStateSlot. That call does two things: it marks the owning graph node dirty (queueDirtyForStateChange) and asks the invalidator for a frame. It does not render.",
    source: "swift-tui/Sources/SwiftTUICore/Resolve/ViewNode.swift:205",
  },
  {
    title: "The scheduler coalesces",
    body:
      "The invalidator is a FrameScheduler. requestInvalidation(of:) inserts the .invalidation wake cause, unions the identity into the pending set, bumps an intent counter, and wakes the loop. Input, signals, external wakes, and deadlines feed the same scheduler.",
    source: "swift-tui/Sources/SwiftTUICore/Pipeline/Scheduler.swift:135",
  },
  {
    title: "One frame is consumed",
    body:
      "consumeReadyFrame drains every pending cause and identity into a single ScheduledFrame, then resets the pending sets. Ten writes between two consume calls become one frame — and intentRequestCount records how many intents merged.",
    source: "swift-tui/Sources/SwiftTUICore/Pipeline/Scheduler.swift:186",
  },
  {
    title: "The dirty frontier renders",
    body:
      "The run loop runs head with the frame's invalidatedIdentities. ViewGraph invalidates and evaluates only the affected nodes; retained reuse can skip disjoint subtrees the invalidation summary proves are safe.",
    source: "swift-tui/Sources/SwiftTUICore/Resolve/ViewGraph.swift:635",
  },
];

const wakeCauses = ["input", "invalidation", "signal", "external", "deadline"];

/* ------------------------------------------------------------------ */
/* Isolation                                                           */
/* ------------------------------------------------------------------ */

const isolation = {
  main: {
    title: "Main actor",
    reason: "Evaluates authored bodies, mutates live runtime state, publishes user-visible effects.",
    items: [
      "resolve (evaluating View bodies)",
      "graph, state, focus, lifecycle, task coordination",
      "transaction and registration publication",
      "the commit boundary and presentation",
    ],
  },
  tail: {
    title: "Frame-tail worker (eligible)",
    reason: "Pure over already-resolved products, so it can move off the main actor when the strategy supports it.",
    items: [
      "measure",
      "place",
      "semantics extraction",
      "draw lowering",
      "raster",
    ],
  },
};

const invariants = [
  "Resolve and commit stay on the main actor — they evaluate authored bodies, mutate runtime state, and publish user-visible effects.",
  "Frame-head side effects are staged in a FrameHeadTransaction; aborting, cancelling, or dropping a frame must leak no registrations, graph changes, animation, portal, or observation state.",
  "The frame tail may be scheduled as one fused stage, but the phase products stay distinct and ordered.",
  "Host-facing damage is derived against the previous raster surface actually presented to that host — never against renderer-private retained state.",
  "Presentation layers consume committed frame contracts; they do not reach into renderer-private retained state.",
];

/* ------------------------------------------------------------------ */
/* Four fates of a frame                                               */
/* ------------------------------------------------------------------ */

const fates = [
  {
    name: "Committed",
    body:
      "The candidate becomes FrameArtifacts: products published, graph and runtime state advanced, ready for presentation.",
    detail: "The normal path. Everything downstream assumes this happened.",
  },
  {
    name: "Dropped",
    body:
      "Completed-frame policy can discard a visual-only candidate when a newer render intent already supersedes it.",
    detail: "Why a burst of state changes can resolve to fewer presented frames than writes.",
  },
  {
    name: "Cancelled",
    body:
      "A queued async tail can be cancelled before it starts when a newer frame makes its output irrelevant.",
    detail: "The cancellation points are exactly the runtime-stage boundaries.",
  },
  {
    name: "Elided",
    body:
      "An animation-deadline frame with no visible drawn effect commits animation state without running the tail or presenting.",
    detail: "Animation progresses without paying for a frame nobody would see.",
  },
];

/* ------------------------------------------------------------------ */
/* Damage + handoff                                                    */
/* ------------------------------------------------------------------ */

const damageRules = [
  { signal: "nil damage", meaning: "Repaint the full surface — the previous surface is unavailable or incompatible." },
  { signal: "empty damage", meaning: "Non-nil but empty: no visible raster cells changed." },
  { signal: "row / range damage", meaning: "Relative to the previous surface actually presented to this same host." },
];

const handoff = [
  {
    title: "FrameArtifacts",
    body: "Committed products leave the renderer as one immutable data bundle.",
  },
  {
    title: "RunLoop.applyAcquiredFrame",
    body: "Merges lifecycle carry-forward, updates semantics, derives host-facing damage, then presents.",
  },
  {
    title: "Output mode branch",
    body: "json and accessible modes write command-oriented output; tui and hosted modes present a raster surface.",
  },
  {
    title: "SemanticHostFrame",
    body: "A semantic host receives raster, semantics, focused identity, host-facing damage, and preferred size.",
  },
  {
    title: "PresentationPlan",
    body: "A terminal-native surface plans a full or incremental repaint from its capabilities and the damage.",
  },
  {
    title: "Host bytes",
    body: "Escape sequences, synchronized-output wrappers, image-protocol replay, and UTF-8 text reach the terminal.",
  },
];

/* ------------------------------------------------------------------ */
/* Diagnostics                                                         */
/* ------------------------------------------------------------------ */

const diagnostics = [
  { label: "Phase timings", body: "resolve, measure, place, semantics, draw, raster, and commit durations." },
  { label: "Worker timing", body: "frame-tail enqueue, compute, and completion; main-actor blocked and suspended time." },
  { label: "Scheduling", body: "render and desired generation, wake causes, coalescing counts, focus-sync rerenders." },
  { label: "Animation", body: "animation-controller active and pending state for the frame." },
  { label: "Disposition", body: "drop eligibility and the committed-frame outcome (committed / dropped / cancelled / elided)." },
  { label: "Presentation", body: "presentation metrics and presentation duration after handoff." },
];

/* ------------------------------------------------------------------ */
/* Source deep-dive                                                    */
/* ------------------------------------------------------------------ */

const sourceTabs = [
  {
    id: "stage-order",
    label: "stage order",
    title: "RuntimeRenderStageName",
    file: "swift-tui/Sources/SwiftTUIRuntime/Rendering/RuntimeRenderPipeline.swift:10",
    role: "The scheduling model, enforced by the type system",
    snippet: [
      "enum RuntimeRenderStageName: String, CaseIterable, Sendable {",
      "  case head",
      "  case animationInjection",
      "  case latePreferenceReconciliation",
      "  case fusedFrameTail",
      "  case commit",
      "",
      "  static let orderedComposition: [Self] = allCases",
      "}",
      "",
      "struct RuntimeRenderPipeline: Sendable {",
      "  var stageOrder: [RuntimeRenderStageName] {",
      "    RuntimeRenderStageName.orderedComposition",
      "  }",
      "}",
    ],
    hot: [1, 2, 3, 4, 5, 8],
    notes: [
      "Each render* entry point walks orderedComposition and dispatches every stage through an exhaustive switch.",
      "Stage order is therefore a structural property of the executor loop — reordering a case forces the switches to be updated, so the order cannot drift silently.",
      "There is no stored stage list and no canonical-order precondition to guard; the loop is the contract.",
    ],
  },
  {
    id: "head",
    label: "head",
    title: "computeFrameHead",
    file: "swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRendererFrameHeadCoordinator.swift:26",
    role: "Where resolve happens and the draft is staged",
    snippet: [
      "func computeFrameHead<V: View>(",
      "  _ root: V,",
      "  context: ResolveContext,",
      "  proposal: ProposedSize,",
      "  mode: FrameHeadMode",
      ") -> FrameHeadDraft {",
      "  let renderGeneration = renderGenerationSequencer.next()",
      "  var resolveContext = preparedResolveContext(context)",
      "  let resolveInputs = storeResolveInputs(in: &resolveContext, proposal: proposal)",
      "  let portal = installPresentationPortalEvaluator(...)",
      "  let resolvedHead = resolveGraphHead(...)",
      "  return FrameHeadDraft(",
      "    resolved: resolvedHead.resolved,",
      "    frameTailInput: frameProducts.frameTailInput,",
      "    transaction: transaction",
      "  )",
      "}",
    ],
    hot: [7, 9, 10, 11, 12],
    notes: [
      "A render generation is allocated up front so later stages can detect when a newer frame has superseded this one.",
      "resolveGraphHead evaluates the dirty frontier; authored bodies become a ResolvedNode tree plus frame-tail inputs.",
      "The returned draft carries a staged transaction that commit will later publish — or that an aborted frame discards.",
    ],
  },
  {
    id: "tail",
    label: "fused tail",
    title: "FrameTailInlineStageRenderer",
    file: "swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift:4",
    role: "Measure, place, semantics, draw, raster — one node, five products",
    snippet: [
      "func renderInlineLayoutStage(_ input: FrameTailInput, ...) -> FrameTailLayoutOutput {",
      "  let measured = layoutEngine.measure(",
      "    input.resolved, proposal: input.proposal, passContext: input.layoutPassContext)",
      "  let placed = layoutEngine.place(",
      "    input.resolved, measured: measured, passContext: input.layoutPassContext)",
      "}",
      "",
      "func renderInlineRasterTail(...) -> FrameTailOutput {",
      "  let semantics = semanticExtractor.extract(from: placed, retained: retainedInput)",
      "  let draw = drawExtractor.extract(from: placed, retained: retainedInput)",
      "  let rasterized = rasterizer.rasterizeCollectingVisibleIdentities(",
      "    draw, previousSurface: previousSurface, damage: rasterReuseDamage)",
      "}",
    ],
    hot: [2, 4, 9, 10, 11],
    notes: [
      "measure and place negotiate integer-cell geometry before semantics is extracted from the placed tree.",
      "semantics, draw, and raster each derive from the placed tree; none mutates it.",
      "raster turns draw commands into a styled cell grid and can reuse parts of the previous surface — but still writes no terminal bytes.",
    ],
  },
  {
    id: "commit",
    label: "commit",
    title: "resolveCompletedFrameCandidate",
    file: "swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRenderer+CompletedFrameCandidates.swift:57",
    role: "Completed-frame policy: the four fates",
    snippet: [
      "func resolveCompletedFrameCandidate(",
      "  draft: FrameHeadDraft,",
      "  tailOutput: AsyncFrameTailDraftOutput,",
      "  newestDesiredGeneration: RenderGeneration,",
      "  completedFramePolicy: CompletedFramePolicy? = nil",
      ") -> CompletedFrameCandidateResolution {",
      "  let candidate = makeCompletedFrameCandidate(...)",
      "  if candidate.dropDecision.canSkipCompletedFrame {",
      "    discardCompletedFrameCandidate(candidate, ...)",
      "    return .dropped(...)",
      "  }",
      "  let artifacts = commitCompletedFrameCandidate(candidate)",
      "  return .committed(artifacts, candidate.dropDecision)",
      "}",
    ],
    hot: [7, 8, 9, 10, 12, 13],
    notes: [
      "A completed visual-only candidate can be dropped when newestDesiredGeneration shows a newer intent already supersedes it.",
      "Committed candidates publish graph and runtime state and produce FrameArtifacts.",
      "commitCompletedFrameCandidate packages the CommitPlan: lifecycle entries, handler installs, semantic snapshot, and transaction data.",
    ],
  },
  {
    id: "present",
    label: "present",
    title: "presentCommittedFrame",
    file: "swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+Presentation.swift:15",
    role: "The committed-frame boundary into the host",
    snippet: [
      "package func presentCommittedFrame(",
      "  _ artifacts: FrameArtifacts,",
      "  damage: PresentationDamage?",
      ") throws -> TerminalPresentationMetrics {",
      "  if runtimeConfiguration.output == .json { ... }",
      "  if runtimeConfiguration.output == .accessible { ... }",
      "",
      "  if let semanticHost = presentationSurface",
      "    as? any SemanticHostFramePresentationSurface {",
      "    metrics = try semanticHost.present(SemanticHostFrame(",
      "      raster: artifacts.rasterSurface,",
      "      semantics: semanticSnapshotWithScrollOffsets(artifacts.semanticSnapshot),",
      "      rasterDamage: damage))",
      "  } else if let damageAware = presentationSurface",
      "    as? any DamageAwarePresentationSurface {",
      "    metrics = try damageAware.present(artifacts.rasterSurface, damage: damage)",
      "  }",
      "}",
    ],
    hot: [5, 6, 8, 9, 10, 14, 15],
    notes: [
      "Presentation runs after a frame is acquired and committed — never inside the renderer.",
      "The surface's roles decide the path: a semantic host receives raster + semantics + damage; a damage-aware host receives raster + damage.",
      "Terminal-native surfaces then plan full or incremental repaint bytes from their capabilities and the host-facing damage.",
    ],
  },
  {
    id: "invalidation",
    label: "invalidation",
    title: "setStateSlot → requestInvalidation",
    file: "swift-tui/Sources/SwiftTUICore/Resolve/ViewNode.swift:205",
    role: "Change propagation: intent, not rendering",
    snippet: [
      "// ViewNode.swift",
      "package func setStateSlot<Value>(ordinal: Int, value: Value, ...) {",
      "  let didChange = slot.set(value)",
      "  if didChange {",
      "    ownerGraph?.queueDirtyForStateChange(.init(owner: viewNodeID, ordinal: ordinal))",
      "    invalidator?.requestInvalidation(of: [invalidationIdentity])",
      "  }",
      "}",
      "",
      "// Scheduler.swift — the invalidator is a FrameScheduler",
      "public func requestInvalidation(of identities: Set<Identity>) {",
      "  pendingCauses.insert(.invalidation)",
      "  invalidatedIdentities.formUnion(identities)",
      "  pendingIntentRequestCount += 1",
      "  notifyPendingFrameRequestWaiters()",
      "}",
    ],
    hot: [3, 4, 5, 6, 11, 12, 13, 14],
    notes: [
      "Mutation and input enqueue intent; they never call rendering phases directly.",
      "setStateSlot marks the graph dirty AND asks the invalidator for a frame — two separate effects.",
      "The scheduler coalesces identities and causes until consumeReadyFrame produces the next ScheduledFrame.",
    ],
  },
];

/* ------------------------------------------------------------------ */
/* Code map + glossary                                                 */
/* ------------------------------------------------------------------ */

const codemap = [
  {
    q: "How does an app become a run loop?",
    files: [
      "swift-tui/Sources/SwiftTUIRuntime/Scenes/SceneSession.swift:244",
      "swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop.swift:783",
    ],
  },
  {
    q: "How does the loop decide a frame is needed?",
    files: [
      "swift-tui/Sources/SwiftTUICore/Pipeline/Scheduler.swift:105",
      "swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+Rendering.swift:228",
    ],
  },
  {
    q: "What is the renderer entry point?",
    files: ["swift-tui/Sources/SwiftTUIRuntime/SwiftTUI.swift:293"],
  },
  {
    q: "What executes the runtime stages?",
    files: ["swift-tui/Sources/SwiftTUIRuntime/Rendering/RuntimeRenderPipeline.swift:223"],
  },
  {
    q: "Where does resolve happen?",
    files: [
      "swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRendererFrameHeadCoordinator.swift:26",
      "swift-tui/Sources/SwiftTUICore/Resolve/ViewGraph.swift:635",
    ],
  },
  {
    q: "Where do measure → raster run?",
    files: ["swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift:4"],
  },
  {
    q: "Where does commit decide a frame's fate?",
    files: ["swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRenderer+CompletedFrameCandidates.swift:57"],
  },
  {
    q: "Where does a committed frame reach a host?",
    files: [
      "swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+Presentation.swift:15",
      "swift-tui/Sources/SwiftTUIRuntime/Terminal/PresentationSurface.swift:235",
    ],
  },
];

const glossary = [
  { term: "FrameHeadDraft", def: "The output of head: resolved tree, frame-tail input, staged transaction, generation, and frame context. Abortable until commit." },
  { term: "FrameArtifacts", def: "The committed bundle of all seven phase products plus diagnostics, presentation damage, and the commit plan." },
  { term: "ScheduledFrame", def: "One consumed frame request: every pending wake cause, the unioned invalidated identities, deadlines, and the coalesced intent count." },
  { term: "WakeCause", def: "Why a frame was scheduled: input, invalidation, signal, external, or deadline." },
  { term: "FrameScheduler", def: "Coalesces invalidations, input, signals, and deadlines into frame work; consumeReadyFrame drains them into one ScheduledFrame." },
  { term: "RenderGeneration", def: "A monotonic id allocated in head. Lets later stages detect that a newer frame supersedes this one, enabling drop and cancel." },
  { term: "PresentationDamage", def: "Host-facing changed rows/ranges, re-derived by RunLoop against the surface last presented to that host." },
  { term: "SemanticHostFrame", def: "The committed contract a non-terminal host consumes: raster, semantics, focused identity, damage, and preferred size." },
];

/* ================================================================== */
/* Rendering                                                           */
/* ================================================================== */

let activeIndex = 0;
let timer = null;
let playing = false;
const STEP_MS = 2600;

function escapeHtml(value) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

/* --- lightweight Swift highlighting (string- and comment-safe) ---
 * Strings and line comments are stashed behind delimited, letter-only
 * placeholders before the keyword/type/number passes run, so those passes can
 * neither corrupt nor re-colour protected spans. The delimiter is a private-use
 * sentinel that survives every pass; tokens are uppercase letters (no digits,
 * never a Swift keyword or a listed type), so the word and number passes skip
 * them and the restore pass only matches genuine placeholders. */
function highlightSwift(value) {
  const stashed = [];
  const DELIM = "\uE000";
  const stash = (html) => {
    stashed.push(html);
    let n = stashed.length - 1;
    let token = "";
    do {
      token = String.fromCharCode(65 + (n % 26)) + token;
      n = Math.floor(n / 26) - 1;
    } while (n >= 0);
    return DELIM + token + DELIM;
  };

  let line = escapeHtml(value)
    .replace(/\/\/.*/g, (m) => stash('<span class="tok-com">' + m + "</span>"))
    .replace(/"[^"]*"/g, (m) => stash('<span class="tok-str">' + m + "</span>"));

  line = line
    .replace(
      /\b(import|struct|enum|var|let|some|func|return|case|if|else|static|package|public)\b/g,
      '<span class="tok-kw">$1</span>'
    )
    .replace(
      /\b(View|VStack|HStack|Text|Divider|ProgressView|LabeledContent|Button|BuildSummary|ResolvedNode|MeasuredNode|PlacedNode|SemanticSnapshot|DrawNode|RasterSurface|CommitPlan|FrameArtifacts|FrameHeadDraft|ScheduledFrame|FrameScheduler|Identity)\b/g,
      '<span class="tok-type">$1</span>'
    )
    .replace(/\b(\d+)\b/g, '<span class="tok-num">$1</span>');

  return line.replace(/\uE000([A-Z]+)\uE000/g, (_, token) => {
    let index = 0;
    for (const ch of token) index = index * 26 + (ch.charCodeAt(0) - 64);
    return stashed[index - 1];
  });
}

function sourceHref(path) {
  return `../../${path.split(":")[0]}`;
}

function sourceLabel(path) {
  const [file, line] = path.split(":");
  const short = file.replace(/^swift-tui\/Sources\//, "");
  return line ? `${short}:${line}` : short;
}

function sourceAnchor(path, extraClass) {
  const cls = extraClass ? ` class="${extraClass}"` : "";
  return `<a${cls} href="${sourceHref(path)}">${sourceLabel(path)}</a>`;
}

/* --- TOC --- */
const tocItems = [
  ["overview", "01 · The mental model"],
  ["explorer", "02 · Walkthrough"],
  ["products", "03 · Phase products"],
  ["propagation", "04 · Change propagation"],
  ["isolation", "05 · What runs where"],
  ["commit", "06 · Four fates"],
  ["handoff", "07 · Host handoff"],
  ["source", "08 · Source"],
  ["diagnostics", "09 · Diagnostics"],
  ["map", "10 · Where to look next"],
];

function renderToc() {
  const nav = document.getElementById("toc-nav");
  nav.innerHTML = tocItems
    .map(([id, label]) => `<a href="#${id}" data-toc="${id}">${label}</a>`)
    .join("");

  const links = Array.from(nav.querySelectorAll("a"));
  const targets = tocItems.map(([id]) => document.getElementById(id)).filter(Boolean);
  const spy = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          for (const link of links) {
            link.classList.toggle("is-active", link.dataset.toc === entry.target.id);
          }
        }
      }
    },
    { rootMargin: "-45% 0px -50% 0px", threshold: 0 }
  );
  for (const t of targets) spy.observe(t);
}

/* --- view code --- */
function renderViewCode() {
  document.getElementById("view-code").innerHTML = viewLines
    .map((line, i) => {
      const n = String(i + 1).padStart(2, "0");
      return `<span class="code-line" data-line="${i + 1}"><span class="ln">${n}</span><span class="lc">${highlightSwift(line)}</span></span>`;
    })
    .join("");
}

/* --- stage ↔ product mapping diagram --- */
function renderMapping() {
  const board = document.getElementById("mapping-board");

  // Stages that own phase products get grid columns derived from those products
  // (head -> resolve, fusedFrameTail -> measure..raster, commit -> commit), so
  // the row aligns under the products without hand-tuned spans. The two stages
  // that own no product are rendered in a separate band: they adjust the
  // in-flight draft rather than introduce a new value.
  const covering = STAGES.filter((s) => s.covers.length);
  const adjusting = STAGES.filter((s) => !s.covers.length);

  const stageCells = covering
    .map((s) => {
      const idxs = s.covers.map((c) => phaseIndex[c]);
      const first = Math.min(...idxs);
      const last = Math.max(...idxs);
      const range =
        first === last ? PHASES[first].key : `${PHASES[first].key}…${PHASES[last].key}`;
      return `<div class="map-stage map-${s.actor}" style="grid-column: ${first + 1} / ${last + 2}">
          <span class="map-name">${s.key}</span>
          <span class="map-tag">covers ${range}</span>
        </div>`;
    })
    .join("");

  const adjustCells = adjusting
    .map((s) => `<span class="adjust-chip map-${s.actor}">${s.key}</span>`)
    .join("");

  const productRow = PHASES.map(
    (p) => `<div class="map-product"><span class="map-phase">${p.key}</span><code>${p.type}</code></div>`
  ).join("");

  board.innerHTML = `
    <div class="map-rowlabel">runtime stages</div>
    <div class="map-stages">${stageCells}</div>
    <div class="map-adjust">${adjustCells}<span class="adjust-note">these adjust the in-flight draft — no new product</span></div>
    <div class="map-rowlabel">phase products</div>
    <div class="map-products">${productRow}</div>
  `;
}

/* --- the interactive explorer --- */
function renderStageRail() {
  const rail = document.getElementById("stage-rail");
  rail.innerHTML = STAGES.map(
    (s, i) => `
      <button class="rail-node" type="button" data-step="${i}" aria-label="Show stage ${s.key}">
        <span class="rail-dot rail-${s.actor}"></span>
        <span class="rail-name">${s.key}</span>
      </button>`
  ).join("");
  for (const node of rail.querySelectorAll(".rail-node")) {
    node.addEventListener("click", () => {
      setStage(Number(node.dataset.step));
      pause();
    });
  }
}

function renderStageDetail(stage) {
  const actorLabel =
    stage.actor === "tail" ? "off-actor eligible" : "main actor";
  const covers = stage.covers.length
    ? stage.covers.map((c) => `<code>${c}</code>`).join(" ")
    : "<span class='detail-muted'>no new product — adjusts the draft</span>";

  document.getElementById("stage-detail").innerHTML = `
    <div class="detail-top">
      <h4>${stage.key}</h4>
      <span class="actor-pill actor-${stage.actor}">${actorLabel}</span>
    </div>
    <p class="detail-headline">${stage.headline}</p>
    <dl class="detail-io">
      <div><dt>covers</dt><dd>${covers}</dd></div>
      <div><dt>consumes</dt><dd>${stage.consumes}</dd></div>
      <div><dt>produces</dt><dd>${stage.produces}</dd></div>
    </dl>
    <p class="detail-does"><span class="lbl">Does:</span> ${stage.does}</p>
    <p class="detail-not"><span class="lbl">Does not:</span> ${stage.not}</p>
    <p class="detail-src">${sourceAnchor(stage.source)}</p>
  `;
}

function renderProductLedger(stageIndex) {
  const available = productsAfterStage(stageIndex);
  const ledger = document.getElementById("product-ledger");
  ledger.innerHTML = PHASES.map((p) => {
    const ready = available.has(p.key);
    return `<span class="ledger-chip ${ready ? "is-ready" : "is-pending"}" title="${p.type}">${p.key}</span>`;
  }).join("");
}

function renderTerminal(stage) {
  const lines = stagePreview[stage.key] || [];
  document.getElementById("terminal-output").textContent = lines.join("\n");
  document.getElementById("product-status").textContent = stage.status;
}

function setStage(index) {
  activeIndex = ((index % STAGES.length) + STAGES.length) % STAGES.length;
  const stage = STAGES[activeIndex];

  for (const node of document.querySelectorAll(".rail-node")) {
    node.classList.toggle("is-active", Number(node.dataset.step) === activeIndex);
    node.classList.toggle("is-done", Number(node.dataset.step) < activeIndex);
  }
  for (const line of document.querySelectorAll(".code-line")) {
    const n = Number(line.dataset.line);
    line.classList.toggle("is-hot", stage.codeLines.includes(n));
  }
  document.getElementById("stage-counter").textContent = `${activeIndex + 1} / ${STAGES.length}`;
  document.getElementById("explorer-progress").textContent =
    `Stage ${activeIndex + 1} of ${STAGES.length}: ${stage.key}`;

  renderStageDetail(stage);
  renderProductLedger(activeIndex);
  renderTerminal(stage);
}

function step(delta) {
  setStage(activeIndex + delta);
}

function play() {
  playing = true;
  document.body.classList.add("is-playing");
  if (timer) clearInterval(timer);
  timer = setInterval(() => step(1), STEP_MS);
}

function pause() {
  playing = false;
  document.body.classList.remove("is-playing");
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
}

function setupExplorerControls() {
  document.getElementById("next-button").addEventListener("click", () => {
    step(1);
    pause();
  });
  document.getElementById("prev-button").addEventListener("click", () => {
    step(-1);
    pause();
  });
  document.getElementById("play-toggle").addEventListener("click", () => {
    if (playing) pause();
    else play();
  });
}

/* --- static reference sections --- */
function renderProductTable() {
  document.getElementById("product-table").innerHTML = PHASES.map(
    (p, i) => `
      <article class="product-row">
        <div class="product-key"><span class="product-no">${i + 1}</span><span>${p.key}</span></div>
        <div class="product-type"><code>${p.type}</code><span class="product-q">${p.question}</span></div>
        <p class="product-owns">${p.owns}</p>
        <code class="product-field">FrameArtifacts.${p.field}</code>
      </article>`
  ).join("");
}

function renderPropagation() {
  const flow = document.getElementById("propagation-flow");
  const causes = wakeCauses
    .map((c) => `<span class="cause-chip ${c === "invalidation" ? "is-lit" : ""}">${c}</span>`)
    .join("");
  flow.innerHTML =
    `<li class="flow-causes"><span class="flow-causes-label">five wake causes funnel into one scheduler</span><div class="cause-row">${causes}</div></li>` +
    propagation
      .map(
        (s, i) => `
        <li class="flow-step">
          <span class="flow-no">${i + 1}</span>
          <div class="flow-body">
            <h3>${s.title}</h3>
            <p>${s.body}</p>
            ${sourceAnchor(s.source, "flow-src")}
          </div>
        </li>`
      )
      .join("");
}

function renderIsolation() {
  const col = (data, side) => `
    <div class="iso-card iso-${side}">
      <h3>${data.title}</h3>
      <p class="iso-reason">${data.reason}</p>
      <ul>${data.items.map((it) => `<li>${it}</li>`).join("")}</ul>
    </div>`;
  document.getElementById("isolation-main").innerHTML = col(isolation.main, "main");
  document.getElementById("isolation-tail").innerHTML = col(isolation.tail, "tail");

  document.getElementById("invariants").innerHTML = invariants
    .map((inv) => `<li>${inv}</li>`)
    .join("");
}

function renderFates() {
  document.getElementById("fates").innerHTML = fates
    .map(
      (f) => `
      <article class="fate-card">
        <h3>${f.name}</h3>
        <p>${f.body}</p>
        <p class="fate-detail">${f.detail}</p>
      </article>`
    )
    .join("");
}

function renderHandoff() {
  document.getElementById("damage").innerHTML = damageRules
    .map(
      (d) => `
      <div class="damage-row">
        <code>${d.signal}</code>
        <p>${d.meaning}</p>
      </div>`
    )
    .join("");

  document.getElementById("handoff-flow").innerHTML = handoff
    .map(
      (n, i) => `
      <article class="handoff-node">
        <span class="handoff-no">${i + 1}</span>
        <h3>${n.title}</h3>
        <p>${n.body}</p>
      </article>`
    )
    .join("");
}

function renderDiagnostics() {
  document.getElementById("diag").innerHTML = diagnostics
    .map(
      (d) => `
      <div class="diag-row">
        <h3>${d.label}</h3>
        <p>${d.body}</p>
      </div>`
    )
    .join("");
}

function renderSourceTabs() {
  const tabs = document.getElementById("source-tabs");
  tabs.innerHTML = sourceTabs
    .map(
      (t, i) => `
      <button class="source-tab" type="button" role="tab" data-source="${t.id}" aria-selected="${i === 0}">
        ${t.label}
      </button>`
    )
    .join("");
  for (const tab of tabs.querySelectorAll(".source-tab")) {
    tab.addEventListener("click", () => setSourceTab(tab.dataset.source));
  }
  setSourceTab(sourceTabs[0].id);
}

function setSourceTab(id) {
  const sel = sourceTabs.find((t) => t.id === id) || sourceTabs[0];
  for (const tab of document.querySelectorAll(".source-tab")) {
    tab.setAttribute("aria-selected", String(tab.dataset.source === sel.id));
  }
  document.getElementById("source-meta").innerHTML = `
    <h3>${sel.title}</h3>
    <p class="meta-role">${sel.role}</p>
    <dl>
      <dt>file</dt>
      <dd>${sourceAnchor(sel.file)}</dd>
    </dl>`;
  document.getElementById("source-snippet").innerHTML = sel.snippet
    .map((line, i) => {
      const escaped = highlightSwift(line);
      return sel.hot.includes(i + 1)
        ? `<span class="snippet-hot">${escaped}</span>`
        : `<span class="snippet-line">${escaped}</span>`;
    })
    .join("\n");
  document.getElementById("source-notes").innerHTML = `
    <h3>Reading notes</h3>
    <ul>${sel.notes.map((n) => `<li>${n}</li>`).join("")}</ul>`;
}

function renderCodemap() {
  document.getElementById("codemap").innerHTML = codemap
    .map(
      (row) => `
      <div class="codemap-row">
        <p class="codemap-q">${row.q}</p>
        <div class="codemap-files">${row.files.map((f) => sourceAnchor(f)).join("")}</div>
      </div>`
    )
    .join("");
}

function renderGlossary() {
  document.getElementById("glossary").innerHTML = glossary
    .map(
      (g) => `
      <div class="glossary-row">
        <code>${g.term}</code>
        <p>${g.def}</p>
      </div>`
    )
    .join("");
}

function prefersReducedMotion() {
  return window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches === true;
}

function init() {
  renderToc();
  renderViewCode();
  renderMapping();
  renderStageRail();
  setupExplorerControls();
  renderProductTable();
  renderPropagation();
  renderIsolation();
  renderFates();
  renderHandoff();
  renderDiagnostics();
  renderSourceTabs();
  renderCodemap();
  renderGlossary();
  setStage(0);

  // Auto-play is opt-in and off by default: a serious doc should not move on
  // its own. Honour reduced-motion by never offering motion in the first place.
  if (!prefersReducedMotion()) {
    document.body.classList.add("motion-ok");
  }
}

init();
