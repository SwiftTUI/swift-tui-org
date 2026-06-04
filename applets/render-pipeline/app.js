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
  '      LabeledContent("Target", value: "terminal")',
  "      Button(\"Ship\") {",
  "        // state mutation schedules another frame",
  "      }",
  "    }",
  "    .padding(1)",
  "    .border(.terminalAccent())",
  "  }",
  "}",
  "",
  "@main",
  "struct BuildSummaryApp: App {",
  "  var body: some Scene {",
  '    WindowGroup("Build Summary") {',
  "      BuildSummary()",
  "    }",
  "  }",
  "}",
  "// SceneSession.run creates the interactive run loop.",
  "// The terminal host presents committed frame artifacts.",
];

const runtimeStages = [
  {
    id: "head",
    number: "1",
    title: "head",
    product: "FrameHeadDraft",
    color: "var(--cyan)",
    summary:
      "DefaultRendererFrameHeadCoordinator prepares resolve inputs, evaluates the graph frontier, installs presentation portal state, and returns a FrameHeadDraft.",
    codeLines: [3, 4, 5, 6, 7],
    phaseIndexes: [0],
    terminalStatus: "building frame head",
    terminal: [
      "FRAME 042  stage: head",
      "",
      "BuildSummary",
      "  VStack",
      "    Text(\"Deploy Queue\")",
      "    Divider",
      "    ProgressView",
      "    LabeledContent",
      "",
      "No terminal cells exist yet.",
    ],
  },
  {
    id: "animationInjection",
    number: "2",
    title: "animationInjection",
    product: "FrameHeadDraft",
    color: "var(--green)",
    summary:
      "AnimationInjectionStage samples animation state and updates resolved metadata before downstream layout, semantics, and drawing read the tree.",
    codeLines: [8, 9, 10, 11, 12],
    phaseIndexes: [0],
    terminalStatus: "sampling animation",
    terminal: [
      "FRAME 042  stage: animationInjection",
      "",
      "transaction:",
      "  animation: inherit",
      "  batch: none",
      "",
      "Resolved metadata is updated.",
      "Frame tail can now read stable inputs.",
    ],
  },
  {
    id: "latePreferenceReconciliation",
    number: "3",
    title: "latePreferenceReconciliation",
    product: "FrameTailLayoutOutput",
    color: "var(--amber)",
    summary:
      "Late preference reconciliation runs layout work that may feed root-level presentation state back into the effective tail input.",
    codeLines: [5, 8, 9, 15, 16],
    phaseIndexes: [1, 2],
    terminalStatus: "measuring and placing",
    terminal: [
      "FRAME 042  stage: layout",
      "",
      "proposal: 80 x 24 cells",
      "measured:",
      "  VStack        24 x 8",
      "  ProgressView  22 x 1",
      "",
      "placed:",
      "  origin: (1, 1)",
      "  size:   24 x 8",
    ],
  },
  {
    id: "fusedFrameTail",
    number: "4",
    title: "fusedFrameTail",
    product: "SemanticSnapshot + DrawNode + RasterSurface",
    color: "var(--amber)",
    summary:
      "The fused tail computes measure, place, semantics, draw, and raster as one scheduling node while preserving distinct typed products.",
    codeLines: [6, 7, 8, 9, 10, 11],
    phaseIndexes: [1, 2, 3, 4, 5],
    terminalStatus: "raster surface ready",
    terminal: [
      "+------------------------+",
      "| Deploy Queue           |",
      "|------------------------|",
      "| Release [#############-] |",
      "| Owner       infra      |",
      "| Target      terminal   |",
      "| [ Ship ]               |",
      "+------------------------+",
      "",
      "RasterSurface: styled cell grid",
    ],
  },
  {
    id: "commit",
    number: "5",
    title: "commit",
    product: "FrameArtifacts + CommitPlan",
    color: "var(--magenta)",
    summary:
      "Commit resolves completed-frame policy, publishes graph/runtime state, packages lifecycle and handlers, then RunLoop presents the committed artifacts.",
    codeLines: [11, 12, 20, 21, 22],
    phaseIndexes: [6],
    terminalStatus: "presented to host",
    terminal: [
      "+------------------------+",
      "| Deploy Queue           |",
      "|------------------------|",
      "| Release [#############-] |",
      "| Owner       infra      |",
      "| Target      terminal   |",
      "| [ Ship ]               |",
      "+------------------------+",
      "",
      "TerminalHost writes planned escape sequences.",
    ],
  },
];

const propagationSteps = [
  {
    title: "State or event changes",
    body:
      "@State writes enter State.wrappedValue, then ViewNode.setStateSlot queues graph dirtiness and asks the invalidator for a frame.",
    color: "var(--cyan)",
    points: [
      ["18%", "58%"],
      ["50%", "44%"],
      ["78%", "58%"],
    ],
  },
  {
    title: "Scheduler coalesces",
    body:
      "FrameScheduler.requestInvalidation records invalidated identities, wake causes, animation request, and intent count before waking the run loop.",
    color: "var(--green)",
    points: [
      ["20%", "44%"],
      ["39%", "62%"],
      ["60%", "38%"],
      ["80%", "60%"],
    ],
  },
  {
    title: "RunLoop consumes",
    body:
      "FrameScheduler.consumeReadyFrame returns one ScheduledFrame and clears pending sets, so multiple mutations can become one render intent.",
    color: "var(--amber)",
    points: [
      ["22%", "62%"],
      ["42%", "36%"],
      ["58%", "54%"],
      ["78%", "42%"],
    ],
  },
  {
    title: "Dirty frontier renders",
    body:
      "ViewGraph invalidation marks affected nodes dirty. Retained reuse can skip disjoint subtrees when the invalidation summary proves they are safe.",
    color: "var(--magenta)",
    points: [
      ["18%", "38%"],
      ["34%", "58%"],
      ["52%", "34%"],
      ["72%", "56%"],
      ["86%", "39%"],
    ],
  },
];

const callpath = [
  {
    name: "View.body",
    role: "authored input",
    detail:
      "The developer writes SwiftTUI View values. Resolver.resolve and graph evaluation lower that body into runtime products.",
    source: "swift-tui/Sources/SwiftTUIViews/Foundation/ViewProtocols.swift:22",
  },
  {
    name: "App.main",
    role: "launch",
    detail:
      "The SwiftTUI App entry point routes to a terminal or hosted launch path before scene selection begins.",
    source: "swift-tui/Sources/SwiftTUI/App.swift:29",
  },
  {
    name: "SceneSession.run",
    role: "session setup",
    detail:
      "Builds RunLoop with the root identity, presentation surface, input reader, scheduler, state container, focus tracker, environment, and root view builder.",
    source: "swift-tui/Sources/SwiftTUIRuntime/Scenes/SceneSession.swift:242",
  },
  {
    name: "RunLoop.run",
    role: "interactive driver",
    detail:
      "Installs invalidators, enables raw mode for TUI output, requests the initial root invalidation, then renders pending frames.",
    source: "swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop.swift:783",
  },
  {
    name: "renderPendingFramesAsync",
    role: "frame coalescing",
    detail:
      "Consumes ready scheduled frames, handles focus convergence, acquires artifacts, and applies the committed frame.",
    source: "swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+Rendering.swift:228",
  },
  {
    name: "renderAsyncCancellableEliding",
    role: "renderer entry",
    detail:
      "Creates the frame head and delegates cancellable stage execution to RuntimeRenderPipeline.",
    source: "swift-tui/Sources/SwiftTUIRuntime/SwiftTUI.swift:293",
  },
  {
    name: "RuntimeRenderPipeline.renderCancellable",
    role: "stage executor",
    detail:
      "Walks head, animationInjection, latePreferenceReconciliation, fusedFrameTail, and commit in orderedComposition order.",
    source: "swift-tui/Sources/SwiftTUIRuntime/Rendering/RuntimeRenderPipeline.swift:223",
  },
  {
    name: "applyAcquiredFrame",
    role: "post-render boundary",
    detail:
      "Merges lifecycle carry-forward, updates semantics, derives host-facing damage, presents the frame, applies lifecycle work, and flushes follow-up invalidations.",
    source: "swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+Rendering.swift:105",
  },
  {
    name: "presentCommittedFrame",
    role: "host handoff",
    detail:
      "Presentation dispatch chooses semantic host frames, damage-aware raster presentation, or plain raster presentation below the committed-frame boundary.",
    source: "swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+Presentation.swift:15",
  },
];

const sourceTabs = [
  {
    id: "stage-order",
    label: "stage order",
    title: "RuntimeRenderStageName",
    file: "swift-tui/Sources/SwiftTUIRuntime/Rendering/RuntimeRenderPipeline.swift:10",
    role: "Runtime scheduling boundary",
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
    hot: [1, 2, 3, 4, 5, 7],
    notes: [
      "The runtime pipeline is a scheduling model, not a replacement for the phase-product model.",
      "The executor loops over orderedComposition and switches exhaustively on each stage.",
      "Adding or reordering stages changes this enum and forces each executor path to compile against the new order.",
    ],
  },
  {
    id: "head",
    label: "frame head",
    title: "computeFrameHead",
    file: "swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRendererFrameHeadCoordinator.swift:26",
    role: "Resolve and draft setup",
    snippet: [
      "func computeFrameHead<V: View>(",
      "  _ root: V,",
      "  context: ResolveContext,",
      "  proposal: ProposedSize,",
      "  mode: FrameHeadMode",
      ") -> FrameHeadDraft {",
      "  let renderGeneration = renderGenerationSequencer.next()",
      "  var resolveContext = preparedResolveContext(context)",
      "  let registrationDraft = FrameHeadRegistrationDraft()",
      "  let graphDraft = ViewGraphFrameDraft(...)",
      "  let resolveInputs = storeResolveInputs(",
      "    in: &resolveContext,",
      "    proposal: proposal",
      "  )",
      "  let portal = installPresentationPortalEvaluator(...)",
      "  let resolvedHead = resolveGraphHead(...)",
      "  return FrameHeadDraft(",
      "    resolved: resolvedHead.resolved,",
      "    frameTailInput: frameProducts.frameTailInput,",
      "    transaction: transaction",
      "  )",
      "}",
    ],
    hot: [7, 10, 11, 15, 16, 17, 18, 19],
    notes: [
      "The head stage allocates a generation and prepares abortable graph/checkpoint state.",
      "Resolve happens here: authored bodies become a ResolvedNode tree plus frame-tail inputs.",
      "The returned FrameHeadDraft carries the staged transaction that commit will later publish or abort.",
    ],
  },
  {
    id: "tail",
    label: "fused tail",
    title: "FrameTailInlineStageRenderer",
    file: "swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift:10",
    role: "Measure, place, semantics, draw, raster",
    snippet: [
      "func renderInlineLayoutStage(_ input: FrameTailInput, ...) -> FrameTailLayoutOutput {",
      "  let measured = layoutEngine.measure(",
      "    input.resolved,",
      "    proposal: input.proposal,",
      "    passContext: input.layoutPassContext",
      "  )",
      "  let placed = layoutEngine.place(",
      "    input.resolved,",
      "    measured: measured,",
      "    passContext: input.layoutPassContext",
      "  )",
      "}",
      "",
      "func renderInlineRasterTail(...) -> FrameTailOutput {",
      "  let semantics = semanticExtractor.extract(from: placed, retained: retainedInput)",
      "  let draw = drawExtractor.extract(from: placed, retained: retainedInput)",
      "  let rasterized = rasterizer.rasterizeCollectingVisibleIdentities(",
      "    draw, previousSurface: previousSurface, damage: rasterReuseDamage",
      "  )",
      "}",
    ],
    hot: [2, 7, 15, 16, 17],
    notes: [
      "The fused tail is one runtime performance node over multiple typed products.",
      "Measure and place negotiate integer-cell size and geometry before semantic routing is extracted.",
      "Raster turns draw commands into a styled cell grid but still does not write terminal bytes.",
    ],
  },
  {
    id: "commit",
    label: "commit",
    title: "resolveCompletedFrameCandidate",
    file: "swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRenderer+CompletedFrameCandidates.swift:57",
    role: "Completed-frame policy and publication",
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
      "",
      "func commitFrameEffects(...) -> CommittedFrameEffects {",
      "  let lifecycleEvents = viewGraph.finalizeFrame(...)",
      "  runtimeRegistrationDiagnostics = commitFrameHeadDraftEffects(draft)",
      "  return commitPlanner.plan(...)",
      "}",
    ],
    hot: [7, 8, 12, 13, 17, 18, 19],
    notes: [
      "The runtime may drop a completed visual-only candidate when a newer render intent supersedes it.",
      "Committed candidates publish graph/runtime state and produce FrameArtifacts.",
      "CommitPlan packages lifecycle entries, handler installations, semantic snapshot, and transaction data.",
    ],
  },
  {
    id: "presentation",
    label: "handoff",
    title: "presentCommittedFrame",
    file: "swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+Presentation.swift:15",
    role: "Host-facing presentation boundary",
    snippet: [
      "func presentCommittedFrame(",
      "  _ artifacts: FrameArtifacts,",
      "  damage: PresentationDamage?",
      ") throws -> TerminalPresentationMetrics {",
      "  if runtimeConfiguration.output == .json { ... }",
      "  if runtimeConfiguration.output == .accessible { ... }",
      "",
      "  if let semanticHostFrameSurface =",
      "    presentationSurface as? any SemanticHostFramePresentationSurface {",
      "    metrics = try semanticHostFrameSurface.present(",
      "      SemanticHostFrame(",
      "        raster: artifacts.rasterSurface,",
      "        semantics: semanticSnapshotWithScrollOffsets(artifacts.semanticSnapshot),",
      "        rasterDamage: damage",
      "      )",
      "    )",
      "  } else if let damageAwareHost = presentationSurface as? any DamageAwarePresentationSurface {",
      "    metrics = try damageAwareHost.present(artifacts.rasterSurface, damage: damage)",
      "  }",
      "}",
    ],
    hot: [8, 10, 11, 12, 13, 14, 17, 18],
    notes: [
      "Presentation happens after a frame has been acquired and committed by the renderer.",
      "Semantic hosts receive raster, semantics, focused identity, host-facing damage, and preferred layout size.",
      "Terminal-native surfaces then plan full or incremental repaint bytes based on capabilities and host-facing damage.",
    ],
  },
  {
    id: "invalidation",
    label: "invalidation",
    title: "State mutation to scheduled frame",
    file: "swift-tui/Sources/SwiftTUICore/Resolve/ViewNode.swift:205",
    role: "Change propagation",
    snippet: [
      "package func setStateSlot<Value>(",
      "  ordinal: Int,",
      "  value: Value,",
      "  invalidationIdentity: Identity? = nil",
      ") {",
      "  var slot = stateSlots[ordinal] ?? .init()",
      "  let didChange = slot.set(value)",
      "  stateSlots[ordinal] = slot",
      "  if didChange {",
      "    ownerGraph?.queueDirtyForStateChange(",
      "      .init(owner: viewNodeID, ordinal: ordinal)",
      "    )",
      "    let invalidationIdentity = invalidationIdentity ?? identity",
      "    let animationRequest = AnimationContextStorage.currentRequest",
      "    let batchID = AnimationContextStorage.currentBatchID",
      "    if animationRequest != .inherit || batchID != nil,",
      "      let animationAware = invalidator as? any AnimationAwareInvalidating",
      "    {",
      "      animationAware.requestInvalidation(",
      "        of: [invalidationIdentity], animation: animationRequest, batchID: batchID",
      "      )",
      "    } else {",
      "      invalidator?.requestInvalidation(of: [invalidationIdentity])",
      "    }",
      "  }",
      "}",
      "",
      "public func requestInvalidation(of identities: Set<Identity>) {",
      "  pendingCauses.insert(.invalidation)",
      "  invalidatedIdentities.formUnion(identities)",
      "  pendingIntentRequestCount += 1",
      "  notifyPendingFrameRequestWaiters()",
      "}",
    ],
    hot: [7, 9, 10, 16, 19, 23, 28, 29, 30, 31],
    notes: [
      "Mutation and input do not call rendering phases directly; they enqueue intent.",
      "The graph marks affected dependent nodes dirty so selective evaluation has a frontier.",
      "The scheduler coalesces identities and causes until the run loop consumes the next ready frame.",
    ],
  },
];

const artifacts = [
  {
    type: "ResolvedNode",
    title: "resolve",
    body:
      "Authored bodies plus identity projection, StructuralPath, optional entity identity, state ownership, environment, metadata, and runtime registrations.",
    code: "FrameArtifacts.resolvedTree",
    color: "var(--cyan)",
  },
  {
    type: "MeasuredNode",
    title: "measure",
    body:
      "Subtree sizes under ProposedSize, negotiated by LayoutEngine before final coordinates exist.",
    code: "FrameArtifacts.measuredTree",
    color: "var(--green)",
  },
  {
    type: "PlacedNode",
    title: "place",
    body:
      "Integer-cell frames, content bounds, and placement-time metadata used by interaction and drawing.",
    code: "FrameArtifacts.placedTree",
    color: "var(--amber)",
  },
  {
    type: "SemanticSnapshot",
    title: "semantics",
    body:
      "Focus, interaction, scroll, selection, coordinate-space, accessibility, and routing data.",
    code: "FrameArtifacts.semanticSnapshot",
    color: "var(--magenta)",
  },
  {
    type: "DrawNode",
    title: "draw",
    body:
      "Placed nodes lowered into draw commands, borders, backgrounds, effects, and payload paint instructions.",
    code: "FrameArtifacts.drawTree",
    color: "var(--cyan)",
  },
  {
    type: "RasterSurface",
    title: "raster",
    body:
      "Styled terminal cells and image attachments. This is host-neutral grid data, not terminal bytes.",
    code: "FrameArtifacts.rasterSurface",
    color: "var(--green)",
  },
  {
    type: "CommitPlan",
    title: "commit",
    body:
      "Lifecycle entries, handler installations, semantic snapshot, and transaction work applied by the runtime.",
    code: "FrameArtifacts.commitPlan",
    color: "var(--amber)",
  },
  {
    type: "PresentationDamage",
    title: "host damage",
    body:
      "Renderer artifact damage is private. Host-facing damage is re-derived against the last raster surface actually presented to that host.",
    code: "RunLoop.presentationDamage(for:)",
    color: "var(--magenta)",
  },
];

const handoff = [
  {
    title: "FrameArtifacts",
    body: "Committed products leave the renderer as a data bundle.",
    color: "var(--cyan)",
    icon: "bundle",
  },
  {
    title: "RunLoop",
    body: "Merges lifecycle, focus, diagnostics, and host-facing damage.",
    color: "var(--green)",
    icon: "loop",
  },
  {
    title: "SemanticHostFrame",
    body: "Non-terminal hosts can consume raster, semantics, focus, and damage.",
    color: "var(--amber)",
    icon: "frame",
  },
  {
    title: "PresentationPlan",
    body: "Terminal hosts choose full repaint or incremental row batches.",
    color: "var(--amber)",
    icon: "plan",
  },
  {
    title: "Escape sequences",
    body: "Cursor moves, row writes, image protocol replay, and sync wrappers.",
    color: "var(--magenta)",
    icon: "wire",
  },
  {
    title: "Terminal",
    body: "The client paints UTF-8 cells and graphics into pixels.",
    color: "var(--cyan)",
    icon: "terminal",
  },
];

const iconPaths = {
  bundle:
    '<path d="M5 7l7-4 7 4-7 4-7-4z"/><path d="M5 12l7 4 7-4"/><path d="M5 17l7 4 7-4"/>',
  loop:
    '<path d="M17 2l4 4-4 4"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><path d="M7 22l-4-4 4-4"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/>',
  frame:
    '<path d="M4 5h16v12H4z"/><path d="M8 21h8"/><path d="M12 17v4"/>',
  plan:
    '<path d="M4 5h16"/><path d="M4 12h16"/><path d="M4 19h16"/><path d="M8 3v4M14 10v4M11 17v4"/>',
  wire:
    '<path d="M3 12c3-7 6 7 9 0s6 7 9 0"/>',
  terminal:
    '<path d="M4 5h16v14H4z"/><path d="M7 9l3 3-3 3"/><path d="M13 15h4"/>',
};

const hexDump = [
  "0000  1B 5B 3F 32 30 32 36 68  1B 5B 32 4A 1B 5B 48  |.[?2026h.[2J.[H|",
  "0010  2B 2D 2D 2D 2D 2D 2D 2D  2D 2D 2D 2D 2D 2D 2D  |+---------------|",
  "0020  44 65 70 6C 6F 79 20 51  75 65 75 65 1B 5B 6D  |Deploy Queue.[m|",
  "0030  52 65 6C 65 61 73 65 20  5B 23 23 23 23 23 23  |Release [######|",
  "0040  4F 77 6E 65 72 20 20 20  20 20 20 69 6E 66 72  |Owner      infr|",
  "0050  1B 5B 3F 32 30 32 36 6C  0A 1B 5B 3F 32 35 68  |.[?2026l..[?25h|",
];

let activeIndex = 0;
let timer = null;
let intervalMs = 1600;
let playing = true;

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function highlightSwift(value) {
  const stringLiterals = [];
  const protectedLine = escapeHtml(value).replace(/"[^"]*"/g, (match) => {
    const token = stringToken(stringLiterals.length);
    stringLiterals.push(match);
    return token;
  });

  return protectedLine
    .replace(/\b(import|struct|var|some|let|func|return)\b/g, '<span class="tok-kw">$1</span>')
    .replace(/\b(View|VStack|Text|Divider|ProgressView|LabeledContent|Button|TerminalRunner|BuildSummary|BuildSummaryApp)\b/g, '<span class="tok-type">$1</span>')
    .replace(/\b(\d+)\b/g, '<span class="tok-num">$1</span>')
    .replace(/@@[A-Z]+@@/g, (token) => {
      const index = stringTokenIndex(token);
      return `<span class="tok-str">${stringLiterals[index] ?? token}</span>`;
    });
}

function stringToken(index) {
  let n = index;
  let token = "";
  do {
    token = String.fromCharCode(65 + (n % 26)) + token;
    n = Math.floor(n / 26) - 1;
  } while (n >= 0);
  return `@@${token}@@`;
}

function stringTokenIndex(token) {
  let value = 0;
  const letters = token.slice(2, -2);
  for (const char of letters) {
    value = value * 26 + (char.charCodeAt(0) - 64);
  }
  return value - 1;
}

function renderViewCode() {
  const code = document.getElementById("view-code");
  code.innerHTML = viewLines
    .map((line, index) => {
      const lineNo = String(index + 1).padStart(2, "0");
      return `<span class="code-line" data-line="${index + 1}"><span class="line-no">${lineNo}</span><span>${highlightSwift(line)}</span></span>`;
    })
    .join("");
}

function renderPipeline() {
  const stack = document.getElementById("pipeline-stack");
  stack.innerHTML = runtimeStages
    .map(
      (stage) => `
        <article class="stage-card" style="color:${stage.color}" data-stage="${stage.id}">
          <span class="stage-num">${stage.number}</span>
          <div class="stage-body">
            <h3>${stage.title}</h3>
            <p>${stage.summary}</p>
            <code>${stage.product}</code>
          </div>
        </article>
      `
    )
    .join("");

  const track = document.getElementById("timeline-track");
  track.innerHTML = runtimeStages
    .map(
      (stage) => `
        <button class="track-node" type="button" data-step="${stage.number}" aria-label="Show ${stage.title}">
          <span class="track-dot"></span>
          <span>${stage.title}</span>
        </button>
      `
    )
    .join("");

  for (const node of track.querySelectorAll(".track-node")) {
    node.addEventListener("click", () => {
      activeIndex = Number(node.dataset.step) - 1;
      updateActiveStage();
      restartTimer();
    });
  }
}

function renderPropagation() {
  const grid = document.getElementById("propagation-grid");
  grid.innerHTML = propagationSteps
    .map((step) => {
      const points = step.points
        .map(([left, top], index) => `<span style="left:${left};top:${top};animation-delay:${index * 120}ms"></span>`)
        .join("");
      return `
        <article class="propagation-card" style="color:${step.color}">
          <h3>${step.title}</h3>
          <p>${step.body}</p>
          <div class="mini-graph" aria-hidden="true">${points}</div>
        </article>
      `;
    })
    .join("");
}

function sourceHref(path) {
  return `../../${path.split(":")[0]}`;
}

function renderCallpath() {
  const list = document.getElementById("callpath-list");
  list.innerHTML = callpath
    .map(
      (item, index) => `
        <li>
          <span class="callpath-index">${String(index + 1).padStart(2, "0")}</span>
          <code>${item.name}</code>
          <p>${item.detail}</p>
          <a href="${sourceHref(item.source)}">${item.source}</a>
        </li>
      `
    )
    .join("");
}

function renderSourceTabs() {
  const tabs = document.getElementById("source-tabs");
  tabs.innerHTML = sourceTabs
    .map(
      (tab, index) => `
        <button class="source-tab" type="button" data-source="${tab.id}" aria-pressed="${index === 0 ? "true" : "false"}">
          ${tab.label}
        </button>
      `
    )
    .join("");

  for (const tab of tabs.querySelectorAll(".source-tab")) {
    tab.addEventListener("click", () => {
      setSourceTab(tab.dataset.source);
    });
  }
  setSourceTab(sourceTabs[0].id);
}

function setSourceTab(id) {
  const selected = sourceTabs.find((tab) => tab.id === id) ?? sourceTabs[0];
  for (const tab of document.querySelectorAll(".source-tab")) {
    tab.setAttribute("aria-pressed", String(tab.dataset.source === selected.id));
  }

  document.getElementById("source-index").innerHTML = `
    <h3>${selected.title}</h3>
    <p>${selected.role}</p>
    <dl>
      <dt>file</dt>
      <dd><a href="${sourceHref(selected.file)}">${selected.file}</a></dd>
      <dt>stage</dt>
      <dd>${selected.label}</dd>
    </dl>
  `;

  document.getElementById("source-snippet").innerHTML = selected.snippet
    .map((line, index) => {
      const escaped = escapeHtml(line);
      const hot = selected.hot.includes(index + 1);
      return hot ? `<span class="snippet-hot">${escaped}</span>` : escaped;
    })
    .join("\n");

  document.getElementById("source-notes").innerHTML = `
    <h3>Why this matters</h3>
    <ul>${selected.notes.map((note) => `<li>${note}</li>`).join("")}</ul>
  `;
}

function renderArtifacts() {
  const board = document.getElementById("artifact-board");
  board.innerHTML = artifacts
    .map(
      (item) => `
        <article class="artifact-card" style="color:${item.color}">
          <span class="artifact-type"><span>${item.type}</span></span>
          <h3>${item.title}</h3>
          <p>${item.body}</p>
          <code>${item.code}</code>
        </article>
      `
    )
    .join("");
}

function renderHandoff() {
  const flow = document.getElementById("handoff-flow");
  flow.innerHTML = handoff
    .map(
      (node) => `
        <article class="handoff-node" style="color:${node.color}">
          <div class="handoff-icon" aria-hidden="true"><svg viewBox="0 0 24 24">${iconPaths[node.icon]}</svg></div>
          <h3>${node.title}</h3>
          <p>${node.body}</p>
        </article>
      `
    )
    .join("");
}

function renderHexDump() {
  document.getElementById("hex-dump").textContent = hexDump.join("\n");
}

function renderTerminal(stage) {
  const output = stage.terminal
    .map((line, index) => {
      const escaped = escapeHtml(line);
      if (index === 0) return `<span class="term-cyan">${escaped}</span>`;
      if (line.includes("Release") || line.includes("animation")) return `<span class="term-amber">${escaped}</span>`;
      if (line.includes("RasterSurface") || line.includes("TerminalHost")) return `<span class="term-green">${escaped}</span>`;
      if (line.includes("No terminal")) return `<span class="term-muted">${escaped}</span>`;
      return escaped;
    })
    .join("\n");
  document.getElementById("terminal-output").innerHTML = output;
  document.getElementById("terminal-status").textContent = stage.terminalStatus;
}

function updateActiveStage() {
  const stage = runtimeStages[activeIndex];

  for (const card of document.querySelectorAll(".stage-card")) {
    card.classList.toggle("is-active", card.dataset.stage === stage.id);
  }
  for (const node of document.querySelectorAll(".track-node")) {
    node.classList.toggle("is-active", Number(node.dataset.step) === activeIndex + 1);
  }
  for (const line of document.querySelectorAll(".code-line")) {
    const lineNumber = Number(line.dataset.line);
    line.classList.toggle("is-hot", stage.codeLines.includes(lineNumber));
    line.classList.toggle("is-warm", stage.id === "commit" && lineNumber === 12);
  }
  for (const [index, node] of Array.from(document.querySelectorAll(".phase-map span")).entries()) {
    node.classList.toggle("is-active", stage.phaseIndexes.includes(index));
  }

  document.getElementById("active-stage-title").textContent = stage.title;
  document.getElementById("active-stage-summary").textContent = stage.summary;
  renderTerminal(stage);
}

function stepStage() {
  activeIndex = (activeIndex + 1) % runtimeStages.length;
  updateActiveStage();
}

function restartTimer() {
  if (timer) {
    clearInterval(timer);
  }
  if (playing) {
    timer = setInterval(stepStage, intervalMs);
  }
}

function setupControls() {
  const playToggle = document.getElementById("play-toggle");
  const stepButton = document.getElementById("step-button");
  const speedSelect = document.getElementById("speed-select");

  playToggle.addEventListener("click", () => {
    playing = !playing;
    document.body.classList.toggle("is-paused", !playing);
    playToggle.setAttribute("aria-label", playing ? "Pause pipeline animation" : "Play pipeline animation");
    restartTimer();
  });

  stepButton.addEventListener("click", () => {
    stepStage();
    restartTimer();
  });

  speedSelect.addEventListener("change", () => {
    intervalMs = Number(speedSelect.value);
    restartTimer();
  });
}

function prefersReducedMotion() {
  return window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches === true;
}

function init() {
  renderViewCode();
  renderPipeline();
  renderPropagation();
  renderCallpath();
  renderSourceTabs();
  renderArtifacts();
  renderHandoff();
  renderHexDump();
  setupControls();
  updateActiveStage();
  if (prefersReducedMotion()) {
    playing = false;
    document.body.classList.add("is-paused");
    document
      .getElementById("play-toggle")
      .setAttribute("aria-label", "Play pipeline animation");
    return;
  }
  restartTimer();
}

init();
