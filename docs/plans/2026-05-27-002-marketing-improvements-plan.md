# SwiftTUI Marketing Improvements — Implementation Plan

> **For agentic workers:** Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task is self-contained: file paths are exact, copy/code is committed in the plan (no "fill in here"), and verification commands are concrete. Tasks marked **(parallel-safe)** can be dispatched concurrently to separate agents.

**Goal:** Close the gap between what the SwiftTUI marketing site claims and what it visibly demonstrates. Land the day-of polish (5 tasks) and the one-week showcase work (4 tasks) — total 9 tasks producing measurable copy, code, and asset deliverables.

**Architecture:**
- Submodule-first: every change happens inside the child repo (`swift-tui-site`, `swift-tui-examples`), gets committed there, then the org root records the new SHA. Never commit child changes from the org root directly.
- Two execution surfaces touched: the Astro site (`swift-tui-site/Website/src/`) and the WebExample / gallery (`swift-tui-examples/`). The framework (`swift-tui/`) is **not touched** — every distinctive capability is already there; the plan only surfaces it.
- "Test" is adapted per task: Astro tasks verify with `bun run check && bun run build` plus a dev-server visual pass. Swift tasks add a Swift Testing `@Test` where there's behavior to assert (scene count, tab title). Asset tasks verify by file existence + visual review.

**Tech Stack:** Astro 5 + Bun (site), SwiftTUI / Swift 6.3 + WASI / Bun (examples), Git submodules (org orchestration).

---

## Cross-repo workflow (read once, apply per task)

The org root provides a **coordination overlay** (`tools/coordination/open_overlay.sh`, wired through Bazel and mise) that lets a single change validate across multiple submodules **without committing first**. Use it. The full reference is in [`docs/CROSS-REPO-DEVELOPMENT.md`](../CROSS-REPO-DEVELOPMENT.md); the workflow below is the short version for this plan.

### During iteration (default — no commits required)

Edit files freely inside any submodule working tree. Validate against the live (uncommitted) state of every submodule via worktree-mode gates:

```bash
cd /Users/adamz/Developer/swift-tui-org

# Site-only changes (Tasks 1.1, 1.2, 1.3, 1.4, 1.5, 2.2, 2.3):
mise run -- bazel test //:site_worktree_gate

# Examples-only changes (Tasks 1.6, 2.1):
mise run -- bazel test //:examples_worktree_gate

# Cross-repo changes (Task 2.4 — touches examples + site together):
mise run worktree-gates    # alias for bazel test //:worktree_gates
```

For ad-hoc native-tool iteration (e.g., running `bun --cwd Website dev` against an uncommitted WebExample wasm), source the overlay env-exports so the site dev server picks up the local examples tree:

```bash
eval "$(mise run overlay -- --print-env all 2>/dev/null)"
# now SWIFTTUI_CHECKOUT, SWIFTTUI_WEB_CHECKOUT, SWIFTTUI_EXAMPLES_CHECKOUT,
# and WEBEXAMPLE_DIR are all set. The site's wasm embed uses WEBEXAMPLE_DIR
# to pick up the local WebExample build instead of the tagged tarball.
bun --cwd swift-tui-site/Website dev
```

Re-run `mise run overlay -- --print-env all` after structural edits — the overlay is a one-shot `rsync` copy, not a live mirror.

### Commits & pin bumps (only at task close)

After the worktree gate passes, commit inside each affected submodule, then bump pins from the org root. **Do not push child branches yet** — Phase 3 batches the integration commit so one org-root commit records all submodule bumps together.

```bash
# Per affected submodule:
cd /Users/adamz/Developer/swift-tui-org/<submodule>
git add <files>
git commit -m "<message>"

# Then from the org root (Phase 3):
cd /Users/adamz/Developer/swift-tui-org
git add <submodule>
```

### Final CI shape (Phase 3 only)

`//:org_full` and the `*_pretag_native_gate` targets always run in **head mode** (committed pins, `git archive HEAD`). The worktree gates are explicitly excluded from `org_full` to keep CI byte-for-byte deterministic. After committing and bumping pins, run `bazel test //:org_full` from the org root to mirror CI before declaring the integration done.

---

## Parallelism map

| Group | Tasks | Parallel-safe? | Why |
|---|---|---|---|
| **A: Site copy** | 1.2, 1.3, 1.4, 1.5 | Yes within group | All edit distinct files under `swift-tui-site/Website/src/` |
| **B: Demo polish** | 1.1, 1.6 | Yes within group | 1.1 edits site iframe shell; 1.6 edits WebExample CSS |
| **C: One-week swings** | 2.1, 2.2, 2.3, 2.4 | Yes within group | Distinct subtrees; 2.2 uses placeholder assets initially, then real ones from 2.3/2.4 |
| **D: Integration** | 3.1 | No (last) | Records all child SHAs once everything else is committed |

Recommended dispatch: spin up 4 agents on Group A in parallel, then 2 on Group B, then 4 on Group C. Group D runs serially at the end.

**Worktree-overlay implication for parallel agents:** since worktree-mode gates `rsync` the live tree, two agents editing *different* submodules can both run `//:worktree_gates` concurrently without stepping on each other. Two agents editing the *same* submodule should still serialize gate runs (or use distinct branches and rebase) to avoid interpreting each other's in-flight edits as part of their own change.

---

# Phase 1: Day-of polish (5 tasks)

## Task 1.1: Bake a placeholder frame into the demo iframe shell

**Why:** The WASM module is 1.3 MiB brotli — visitors see a black void for ~1s before the seeded gliders animate in. A static "first frame" inside the terminal-frame chrome converts cold-start into perceived instant load.

**Files:**
- Modify: `swift-tui-site/Website/src/components/DemoTerminal.astro` (the iframe shell rendered above the embed)
- Add: `swift-tui-site/Website/public/demo-cold-frame.svg` (static placeholder showing seeded grid + header text)

**Parallel-safe:** Yes (within Group B).

- [ ] **Step 1: Read the current DemoTerminal shell**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
sed -n '1,80p' Website/src/components/DemoTerminal.astro
```

Confirm the iframe element exists and locate the element directly above/around the iframe where a placeholder image can sit underneath until the iframe loads.

- [ ] **Step 2: Create the placeholder SVG**

Create `swift-tui-site/Website/public/demo-cold-frame.svg`. Use a static SVG that mimics the first painted frame: a dark `#0a0a0a` background, two rows of header text (`Conway's Life · 18 live · gen 0` and a divider), and a 24×8 grid of monospace `·` and `█` characters arranged in the canonical glider pattern from `LifeGrid.seedDefault()`. Keep total SVG under 4 KB.

Concrete SVG content:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 280" role="img" aria-label="SwiftTUI demo placeholder: Conway's Life with two gliders">
  <rect width="640" height="280" fill="#0a0a0a"/>
  <g font-family="Geist Mono, ui-monospace, monospace" font-size="13" fill="#ededed">
    <text x="20" y="32" font-weight="600">Conway's Life</text>
    <text x="140" y="32" fill="#a0a0a0">· 18 live · gen 0</text>
    <text x="600" y="32" text-anchor="end" fill="#34d399">half-cell 2×</text>
  </g>
  <line x1="20" y1="44" x2="620" y2="44" stroke="#2a2a2a" stroke-width="1"/>
  <g font-family="Geist Mono, ui-monospace, monospace" font-size="14" fill="#34d399">
    <!-- glider pattern -->
    <text x="80"  y="110">█</text>
    <text x="100" y="110">█</text>
    <text x="120" y="110">█</text>
    <text x="120" y="90">█</text>
    <text x="100" y="70">█</text>
    <!-- second glider -->
    <text x="420" y="190">█</text>
    <text x="440" y="190">█</text>
    <text x="460" y="190">█</text>
    <text x="460" y="170">█</text>
    <text x="440" y="150">█</text>
    <!-- blinker oscillator -->
    <text x="280" y="150">█</text>
    <text x="300" y="150">█</text>
    <text x="320" y="150">█</text>
  </g>
  <line x1="20" y1="240" x2="620" y2="240" stroke="#2a2a2a" stroke-width="1"/>
  <g font-family="Geist Mono, ui-monospace, monospace" font-size="11" fill="#666">
    <text x="20" y="262">▶ play   ⏭ step   ⟳ random   ⌫ clear   ◐ zoom</text>
  </g>
</svg>
```

- [ ] **Step 3: Layer the placeholder behind the iframe in DemoTerminal.astro**

Inside the existing terminal-frame container (the one with the colored dots and title bar — locate it by searching for the iframe element or `embed=marketing` query string), wrap the iframe in a container with the SVG as background:

```html
<div class="demo-stage">
  <img
    class="demo-placeholder"
    src={`${base}/demo-cold-frame.svg`}
    alt=""
    aria-hidden="true"
    loading="eager"
    decoding="sync"
  />
  <!-- existing iframe element stays here, unchanged -->
</div>
```

Add CSS in the same component's `<style>` block:

```css
.demo-stage {
  position: relative;
}
.demo-placeholder {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  object-fit: cover;
  z-index: 0;
  pointer-events: none;
}
.demo-stage iframe {
  position: relative;
  z-index: 1;
  background: transparent;
}
.demo-stage iframe[data-loaded="true"] + .demo-placeholder {
  opacity: 0;
  transition: opacity 200ms ease 120ms;
}
```

If the iframe element doesn't already emit a `data-loaded` attribute on its `load` event, also add an inline script next to the iframe:

```html
<script is:inline>
  document.querySelectorAll('.demo-stage iframe').forEach(f => {
    f.addEventListener('load', () => f.setAttribute('data-loaded', 'true'));
  });
</script>
```

- [ ] **Step 4: Verify the placeholder appears and fades**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
bun install --cwd Website --frozen-lockfile
bun run --cwd Website check
bun run --cwd Website dev
```

Open `http://localhost:4321` in a browser. With network throttling set to "Slow 3G" (DevTools → Network), reload the page and confirm:
- The SVG placeholder is visible immediately (under 300ms after page load).
- The iframe fades in over the placeholder once WASM loads.
- No layout shift between placeholder and real frame.

Then with no throttling, confirm the transition is smooth and the placeholder is gone within ~1s.

- [ ] **Step 5: Commit**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
git add Website/src/components/DemoTerminal.astro Website/public/demo-cold-frame.svg
git commit -m "feat(site): bake static placeholder into demo iframe shell"
```

---

## Task 1.2: Replace AuthoringSnippet with a `@State`+`@FocusState` counter

**Why:** The current snippet (`BuildSummary` panel) is generic — could be any TUI lib. The replacement uses `@main App`, `@State`, `@FocusState`, `Button`, `.onAppear`, and `WindowGroup` — every line of code that makes a SwiftUI developer go "wait, this is just SwiftUI." The right pane keeps the rendered output to preserve the "code → cells" payoff.

**Files:**
- Modify: `swift-tui-site/Website/src/components/AuthoringSnippet.astro` (lines 23–42 for the code pane source, lines 53–60 for the rendered output pane)

**Parallel-safe:** Yes (within Group A).

- [ ] **Step 1: Replace the code pane source block**

Open `swift-tui-site/Website/src/components/AuthoringSnippet.astro`. Replace lines 23–42 (the `<pre class="code mono">` block currently containing `BuildSummary`) with:

```html
        <pre class="code mono"><code><span class="kw">import</span> <span class="ty">SwiftTUI</span>

<span class="at">@main</span> <span class="kw">struct</span> <span class="ty">CounterApp</span>: <span class="ty">App</span> &#123;
  <span class="kw">var</span> body: <span class="kw">some</span> <span class="ty">Scene</span> &#123;
    <span class="ty">WindowGroup</span>(<span class="s">"Counter"</span>) &#123;
      <span class="ty">CounterView</span>()
    &#125;
  &#125;
&#125;

<span class="kw">struct</span> <span class="ty">CounterView</span>: <span class="ty">View</span> &#123;
  <span class="at">@State</span> <span class="kw">private var</span> count = <span class="n">0</span>
  <span class="at">@FocusState</span> <span class="kw">private var</span> focused: <span class="ty">Bool</span>

  <span class="kw">var</span> body: <span class="kw">some</span> <span class="ty">View</span> &#123;
    <span class="ty">VStack</span>(spacing: <span class="n">1</span>) &#123;
      <span class="ty">Text</span>(<span class="s">"Count: \(count)"</span>).bold()
      <span class="ty">Button</span>(<span class="s">"Increment"</span>) &#123; count += <span class="n">1</span> &#125;
        .focused(<span class="s">$</span>focused)
    &#125;
    .onAppear &#123; focused = <span class="kw">true</span> &#125;
    .padding(<span class="n">2</span>)
  &#125;
&#125;</code></pre>
```

- [ ] **Step 2: Update the file-name label**

On line 20 (`<span class="path">BuildSummary.swift</span>`) change to:

```html
          <span class="path">CounterApp.swift</span>
```

And on line 21 update the proposal label:

```html
          <span class="meta">24 cells × 6 rows · proposal</span>
```

- [ ] **Step 3: Replace the rendered output block**

Replace lines 53–60 (inside `<pre class="render mono">`) with output that matches the new code:

```html
        <pre class="render mono"><code> <span class="b">Count: 3</span>

 <span class="hl">[ Increment ]</span><span class="cursor"> </span>


</code></pre>
```

(The `[ Increment ]` token is styled by the existing `.hl` class to look focused; the `cursor` span keeps the blink animation pulling the eye to the focused control.)

- [ ] **Step 4: Update the section eyebrow and headline copy**

Update lines 6–13 to reflect the new content:

```html
    <header class="head">
      <span class="eyebrow"><span class="num">/04</span>Authoring &rarr; render</span>
      <h2>Read this and you can write SwiftTUI.</h2>
      <p class="lede">
        Every line is SwiftUI you already know.
        <span class="mono">@main App</span>, <span class="mono">WindowGroup</span>,
        <span class="mono">@State</span>, <span class="mono">@FocusState</span>,
        <span class="mono">.onAppear</span> &mdash; no new mental model. SwiftTUI
        lowers this exact tree through its render pipeline into the integer-cell
        output on the right.
      </p>
    </header>
```

- [ ] **Step 5: Verify build and visual**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
bun run --cwd Website check
bun run --cwd Website dev
```

Visit `http://localhost:4321/#authoring` and confirm:
- Code pane shows the new `CounterApp` source.
- Syntax tokens (`@main`, `@State`, `@FocusState`) are colored.
- Output pane shows `Count: 3` and a highlighted `[ Increment ]` button with the cursor blinking.
- Header reads "Read this and you can write SwiftTUI."

- [ ] **Step 6: Commit**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
git add Website/src/components/AuthoringSnippet.astro
git commit -m "feat(site): swap authoring snippet to focused counter showing SwiftUI parity"
```

---

## Task 1.3: Add "Four runs, one source" code block to the Hero

**Why:** The hero copy *claims* four execution targets at `Hero.astro:62`. The reader has no way to see this claim materialized in code. A second `install` block immediately below the `Package.swift` block makes the claim copy-pasteable.

**Files:**
- Modify: `swift-tui-site/Website/src/components/Hero.astro` (insert new block between lines 57 and 59)

**Parallel-safe:** Yes (within Group A).

- [ ] **Step 1: Insert the new code block after the existing install block**

After line 57 (which closes the existing `<div class="install ...">` with `</div>`) and before line 59 (the `<ul class="meta ...">`), insert:

```html
      <div class="install reveal" style="--i:5" role="region" aria-label="run modes">
        <div class="install-head mono">
          <span class="prompt">$ run anywhere</span>
          <span class="sep">·</span>
          <span class="ver">one source &middot; four hosts</span>
        </div>
        <pre class="install-body mono"><code><span class="cm"># terminal executable</span>
swift run CounterApp

<span class="cm"># localhost browser (WebHost)</span>
swift run CounterApp --web

<span class="cm"># static WASI bundle for browser deploy</span>
swift build --swift-sdk wasm32-wasi

<span class="cm"># embed the same Scene inside a native SwiftUI app</span>
<span class="cm">// import SwiftUIHost; SwiftUIHostAppView(app: CounterApp())</span></code></pre>
      </div>
```

- [ ] **Step 2: Bump the `--i` indices on the elements below**

The existing `<ul class="meta ... style="--i:5">` (line 59) and any later `--i:` values must shift by +1. Change `--i:5` on the `<ul class="meta...">` to `--i:6`. There are no later reveal elements in this file, so this is the only bump needed.

- [ ] **Step 3: Verify build and visual**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
bun run --cwd Website check
bun run --cwd Website dev
```

Visit `http://localhost:4321` and confirm:
- A second monospace code block appears below the `Package.swift` block.
- It shows four commands with their captioning comments.
- The reveal animation stagger still feels right (meta block reveals last).
- On mobile (<1080px) the block stacks correctly.

- [ ] **Step 4: Commit**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
git add Website/src/components/Hero.astro
git commit -m "feat(site): add 'four runs, one source' code block under SwiftPM install"
```

---

## Task 1.4: Tighten the hero sub-headline

**Why:** Current sub-headline is technically dense ("seven-phase pipeline", "no global solver", "no virtual DOM"). That phrasing works deeper in the page but loses audiences 1 (SwiftUI devs) and 3 (app developers) above the fold. Lead with the payoff; the pipeline detail moves into a third sentence.

**Files:**
- Modify: `swift-tui-site/Website/src/components/Hero.astro` lines 18–25

**Parallel-safe:** Yes (within Group A), but **must run after 1.3** if both touch `Hero.astro` in the same agent — Group A agents should work serially on Hero changes (1.3 then 1.4) or fan them out to two agents with explicit ordering (1.3 lands first, 1.4 rebases).

- [ ] **Step 1: Replace the lead paragraph**

Replace lines 18–25 with:

```html
      <p class="lead reveal" style="--i:2">
        Author your <span class="mono">App</span> once. Ship it as a terminal
        executable, a static WASI bundle, a localhost WebHost, or embedded
        inside a native SwiftUI surface &mdash; the same
        <span class="mono">View</span> tree, the same
        <span class="mono">@State</span>, the same
        <span class="mono">@FocusState</span>. Under the hood, SwiftTUI lowers
        SwiftUI-shaped views through a strict seven-phase pipeline &mdash; no
        global solver, no virtual DOM, no <span class="mono">curses</span>.
      </p>
```

- [ ] **Step 2: Verify build and visual**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
bun run --cwd Website check
bun run --cwd Website dev
```

Visit `http://localhost:4321` and confirm:
- Sub-headline reads the new copy.
- `App`, `View`, `@State`, `@FocusState`, `curses` are monospaced.
- Reveal animation still triggers.
- No overflow on mobile.

- [ ] **Step 3: Commit**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
git add Website/src/components/Hero.astro
git commit -m "refactor(site): lead hero with payoff, demote pipeline jargon"
```

---

## Task 1.5: Add a competitor comparison component

**Why:** The site lists six differentiators but never positions against the actual competitive set. A small, factual matrix below `WhySwiftTUI` makes the differentiation legible without requiring readers to know other TUI libraries.

**Files:**
- Create: `swift-tui-site/Website/src/components/Comparison.astro`
- Modify: `swift-tui-site/Website/src/pages/index.astro` (insert the new component after `WhySwiftTUI`)

**Parallel-safe:** Yes (within Group A).

- [ ] **Step 1: Create the Comparison component**

Create `swift-tui-site/Website/src/components/Comparison.astro` with:

```astro
---
const rows = [
  {
    name: "SwiftTUI",
    accent: true,
    cells: ["✓", "✓ via SwiftUIHost", "✓ WASI, no emulator", "✓ SwiftTUICharts", "✓ SwiftTUIAnimatedImage"],
  },
  { name: "Bubble Tea (Go)", cells: ["—", "—", "—", "community", "—"] },
  { name: "Textual (Python)", cells: ["—", "—", "via textual-serve", "partial", "—"] },
  { name: "Ratatui (Rust)", cells: ["—", "—", "—", "community", "—"] },
  { name: "Ink (JS/React)", cells: ["partial (JSX)", "—", "—", "community", "—"] },
];
const headers = [
  "SwiftUI-style DSL",
  "Native app embed",
  "Browser deploy w/o emulator",
  "First-party charts",
  "First-party GIF / PNG",
];
---
<section class="compare" id="compare">
  <div class="shell">
    <header class="head">
      <span class="eyebrow"><span class="num">/02</span>Where SwiftTUI sits</span>
      <h2>One author surface. Four hosts. First-party charts and animated images.</h2>
      <p class="lede">
        Compared to other modern TUI frameworks against the things SwiftTUI
        was built to do. Marks reflect the libraries' first-party stories;
        community packages exist in several cells but are not equivalent to
        framework-integrated support.
      </p>
    </header>

    <div class="grid mono" role="table" aria-label="TUI framework comparison">
      <div class="row head-row" role="row">
        <span class="cell name" role="columnheader">framework</span>
        {headers.map((h) => <span class="cell" role="columnheader">{h}</span>)}
      </div>
      {rows.map((r) => (
        <div class={`row ${r.accent ? "accent" : ""}`} role="row">
          <span class="cell name" role="rowheader">{r.name}</span>
          {r.cells.map((c) => (
            <span class="cell" role="cell" data-state={c === "✓" || c.startsWith("✓") ? "yes" : c === "—" ? "no" : "partial"}>{c}</span>
          ))}
        </div>
      ))}
    </div>

    <p class="foot mono">
      Sources: each project's README and official docs as of 2026-05. Corrections
      welcome via the <a href="https://github.com/SwiftTUI/swift-tui-site/issues">site repo</a>.
    </p>
  </div>
</section>

<style>
  .compare {
    padding: 64px 0 40px;
    border-top: 1px solid var(--line);
    margin-top: 48px;
  }
  .head { max-width: 760px; margin-bottom: 36px; }
  .head h2 { margin-top: 16px; }
  .head .lede { margin-top: 14px; max-width: 70ch; }

  .grid {
    border: 1px solid var(--line-strong);
    border-radius: 10px;
    overflow: hidden;
    background: var(--panel);
    font-size: 12px;
  }
  .row {
    display: grid;
    grid-template-columns: 1.2fr repeat(5, 1fr);
    border-bottom: 1px solid var(--line);
  }
  .row:last-child { border-bottom: 0; }
  .row.head-row {
    background: var(--panel-2);
    color: var(--ink-3);
    font-size: 10.5px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }
  .row.accent { background: linear-gradient(180deg, rgba(52,211,153,0.06), rgba(52,211,153,0.02)); }
  .row.accent .name { color: var(--accent); font-weight: 500; }
  .cell {
    padding: 12px 14px;
    border-right: 1px solid var(--line);
    color: var(--ink-2);
  }
  .cell:last-child { border-right: 0; }
  .cell.name { color: var(--ink); }
  .cell[data-state="yes"] { color: var(--accent); }
  .cell[data-state="no"]  { color: var(--ink-4); }
  .cell[data-state="partial"] { color: #f59e0b; }

  .foot { margin-top: 14px; font-size: 11px; color: var(--ink-4); }
  .foot a { color: var(--ink-3); border-bottom: 1px solid var(--line); }
  .foot a:hover { color: var(--accent); }

  @media (max-width: 1080px) {
    .grid { font-size: 11px; }
    .row { grid-template-columns: 1.2fr repeat(5, 1fr); }
    .cell { padding: 10px 8px; }
  }
  @media (max-width: 720px) {
    .grid { overflow-x: auto; }
    .row { min-width: 720px; }
  }
</style>
```

- [ ] **Step 2: Add the component to index.astro**

Edit `swift-tui-site/Website/src/pages/index.astro`. After line 5 (the `import WhySwiftTUI` line), add:

```typescript
import Comparison from "../components/Comparison.astro";
```

After line 94 (the `<WhySwiftTUI />` element), add:

```html
      <Comparison />
```

- [ ] **Step 3: Verify build and visual**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
bun run --cwd Website check
bun run --cwd Website dev
```

Visit `http://localhost:4321#compare` and confirm:
- A 5-row, 6-column matrix renders below `WhySwiftTUI`.
- The SwiftTUI row is accent-tinted; `✓` cells are emerald, `—` cells are dim, `partial`/`community` cells are amber.
- On mobile <720px the grid scrolls horizontally rather than overflowing.

- [ ] **Step 4: Commit**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
git add Website/src/components/Comparison.astro Website/src/pages/index.astro
git commit -m "feat(site): add factual TUI framework comparison matrix"
```

---

## Task 1.6: Match the marketing palette in the standalone web demo

**Why:** The marketing iframe (`?embed=marketing`) uses the warm zinc/emerald palette. The standalone URL `webexample/` reverts to plain dark gradient. Anyone sharing the standalone link sees an off-brand demo.

**Files:**
- Modify: `swift-tui-examples/WebExample/src/index.css` (host page styling)
- Possibly modify: `swift-tui-examples/WebExample/src/app-data.ts` (palette tokens, if defined there) — read it first to confirm

**Parallel-safe:** Yes (within Group B).

- [ ] **Step 1: Read the current standalone styles**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples
cat WebExample/src/index.css
sed -n '1,80p' WebExample/src/app-data.ts
```

Locate the body/background color tokens, the canvas background, and any "marketing" branch already present (search for `embed=marketing` or palette switch). The audit noted `WebHostApp.ts:234` applies a dark gradient — confirm whether the override is in JS or CSS.

- [ ] **Step 2: Adopt the marketing palette as the default**

In `WebExample/src/index.css`, change the body and surface variables to match the site's palette. The site palette (from `swift-tui-site/Website/src/styles/site.css`) is:

- `--bg: #0a0a0a` (warm near-black, not pure black)
- `--ink: #ededed`
- `--ink-2: #b8b8b8`
- `--ink-3: #707070`
- `--ink-4: #404040`
- `--accent: #34d399` (emerald)
- `--panel: rgba(255,255,255,0.02)`
- `--line: rgba(255,255,255,0.06)`

Apply equivalent values:

```css
:root {
  --bg: #0a0a0a;
  --ink: #ededed;
  --ink-2: #b8b8b8;
  --accent: #34d399;
  --panel: rgba(255,255,255,0.02);
}
html, body {
  background: var(--bg);
  color: var(--ink);
  font-family: "Geist Mono", ui-monospace, "SF Mono", Menlo, monospace;
}
canvas {
  background: transparent;
}
```

If `WebHostApp.ts:234` overrides the canvas background with a gradient, set it to `transparent` (or pass through the CSS variable) so the body color shows through. Find the override:

```bash
grep -n "gradient\|background" WebExample/src/*.ts swift-tui-web/packages/web/src/WebHostApp.ts 2>/dev/null
```

Then update that line to use the new palette or render no background, so the host page CSS controls the appearance.

- [ ] **Step 3: Drop the Geist font import in standalone**

Add to the top of `WebExample/src/index.html`'s `<head>` (open the file first to see current content):

```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist+Mono:wght@400;500&display=swap">
```

- [ ] **Step 4: Verify visually**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples/WebExample
bun install
bun dev
```

Open `http://localhost:3000` (or the port `bun dev` reports) and confirm:
- Background is warm near-black `#0a0a0a`, not pure black.
- Headers, controls, and text use the emerald accent for the focused/tint color.
- No regressions in interactivity (cells still toggle on click, drag still paints).

Also test the marketing-embed branch (`?embed=marketing`) and confirm it still looks unchanged from before (since defaults now match it).

Then verify the change still composes with the site iframe via the overlay:

```bash
cd /Users/adamz/Developer/swift-tui-org
mise run -- bazel test //:examples_worktree_gate
```

Expected: PASS. This runs `check_examples.sh` against the live (uncommitted) WebExample tree.

- [ ] **Step 5: Commit**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples
git add WebExample/src/index.css WebExample/src/index.html
# add app-data.ts or WebHostApp.ts updates only if they were actually changed in step 2
git status   # confirm scope
git commit -m "style(WebExample): adopt marketing palette as standalone default"
```

---

# Phase 2: One-week swings (4 tasks)

## Task 2.1: Build a Gallery Tour scene set in WebExample

**Why:** WebExample currently exposes 2 scenes (Game of Life, Demo Details — the latter being plain documentation text). The framework's `GalleryDemoViews` library exposes 18+ tabs covering animations, images, focus, popovers, calculator, todos, forms, navigation, scroll. Lifting 3 more tabs into the WebExample scene list converts the demo from "one toy" to "guided tour."

**Files:**
- Modify: `swift-tui-examples/WebExample/TerminalApp/Sources/WebExampleScenes/WebExampleApp.swift` (the 28-line scene declaration — currently 2 WindowGroups)
- Add: `swift-tui-examples/WebExample/TerminalApp/Tests/WebExampleScenesTests/SceneRosterTests.swift` (verify the scene count and titles)

**Parallel-safe:** Yes (within Group C).

- [ ] **Step 1: Read the gallery exports to confirm tab API**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples
swiftly run swift package --package-path gallery describe 2>/dev/null | head -40
grep -rn "public struct" gallery/Sources/GalleryDemoViews/{AnimationsTab,ImagesTab,CalculatorTab,TodoTab,FocusContextTab,PopoverTab}.swift 2>/dev/null
```

Confirm each tab is `public struct <Name>: View` with a `public init()`. If any is not yet public, do not pick it. From the 18 available, the 3 selected for the tour are:

- `AnimationsTab` — declarative `.animation`, `withAnimation`, `PhaseAnimator`. Visually motion-heavy. Highest wow.
- `ImagesTab` — `SwiftTUIAnimatedImage` GIF playback. The only place where the demo shows the animated-image module.
- `CalculatorTab` — interactive grid of buttons. Familiar, immediate, proves keyboard + click work.

- [ ] **Step 2: Write the failing test**

Create `swift-tui-examples/WebExample/TerminalApp/Tests/WebExampleScenesTests/SceneRosterTests.swift` (create the `Tests/WebExampleScenesTests/` directory if it doesn't exist; add a test target to `Package.swift` if not already present — read `WebExample/TerminalApp/Package.swift` first to determine):

```swift
import Testing
@testable import WebExampleScenes

@Test("WebExampleApp exposes the four-scene gallery tour")
func sceneRosterIncludesFourTourScenes() {
  let app = WebExampleApp()
  let titles = app.sceneTitles  // helper added in step 4
  #expect(titles == ["Game of Life", "Animations", "Images", "Calculator"])
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples/WebExample/TerminalApp
swiftly run swift test --filter SceneRosterTests
```

Expected: FAIL with "no member `sceneTitles`" or "expected 4 titles, got 2".

- [ ] **Step 4: Implement the four-scene roster**

Replace the body of `WebExampleApp.swift` with:

```swift
import GalleryDemoViews
import SharedHostScenes
import SwiftTUIRuntime

public struct WebExampleApp: App {
  public init() {}

  public var body: some Scene {
    WindowGroup("Game of Life") {
      LifeTab()
    }
    WindowGroup("Animations", id: WindowIdentifier("animations")) {
      AnimationsTab()
    }
    WindowGroup("Images", id: WindowIdentifier("images")) {
      ImagesTab()
    }
    WindowGroup("Calculator", id: WindowIdentifier("calculator")) {
      CalculatorTab()
    }
  }

  /// Stable, ordered roster of scene titles for tests and the host picker.
  public var sceneTitles: [String] {
    ["Game of Life", "Animations", "Images", "Calculator"]
  }
}
```

(The "Demo Details" scene is intentionally removed — its content was static text; a tour of three live tabs replaces its purpose.)

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples/WebExample/TerminalApp
swiftly run swift test --filter SceneRosterTests
```

Expected: PASS.

- [ ] **Step 6: Build the wasm and verify the demo loads all four scenes**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples/WebExample
bun dev
```

In a browser at `http://localhost:3000`:
- Click the scene picker (top-right) → confirm four entries: Game of Life, Animations, Images, Calculator.
- Cycle through each → confirm each renders without errors and is interactive.
- If Images tab loads a GIF, confirm playback is smooth.
- If Animations tab has motion, confirm it animates without dropped frames.

If any tab crashes on WASI but works in terminal, note it. Common WASI gaps: `Image(systemName:)` does not resolve under WASI; file I/O paths differ. Substitute the broken tab with another lightweight one (`TodoTab`, `FocusContextTab`, `PopoverTab`) and update the test in step 2 to match.

Then verify the change composes against the site's iframe via worktree overlay:

```bash
cd /Users/adamz/Developer/swift-tui-org
eval "$(mise run overlay -- --print-env all 2>/dev/null)"
bun --cwd swift-tui-site/Website dev
```

Visit the site at `http://localhost:4321` — the iframe should now consume the local WebExample build (via `WEBEXAMPLE_DIR` which the overlay env-exports set). Cycle through the new scene picker entries inside the site embed. Then run the full worktree gate:

```bash
mise run worktree-gates
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples
git add WebExample/TerminalApp/Sources/WebExampleScenes/WebExampleApp.swift WebExample/TerminalApp/Tests/WebExampleScenesTests/SceneRosterTests.swift
# also add Package.swift if test target was added
git status
git commit -m "feat(WebExample): expand demo from 2 scenes to 4-scene gallery tour"
```

---

## Task 2.2: Build a `/showcase/` page

**Why:** The framework has four production-quality example apps (`gifeditor`, `terminal-workspace`, `LayoutsSwiftUI`, `gitviz`) that are completely invisible to site visitors. A single page with one tile per example raises the apparent scope of the framework an order of magnitude.

**Files:**
- Create: `swift-tui-site/Website/src/pages/showcase.astro`
- Add: `swift-tui-site/Website/public/showcase/gifeditor.png`, `terminal-workspace.png`, `layouts-swiftui.png`, `gitviz.png` (placeholders to start; real screenshots come from Task 2.3/2.4 or captured separately)
- Modify: `swift-tui-site/Website/src/components/SiteHeader.astro` (add nav link to `/showcase/`)

**Parallel-safe:** Yes (within Group C). Can start with placeholder screenshots and swap in real ones later.

- [ ] **Step 1: Create placeholder screenshots**

Create four 1200×750 PNG placeholders so the page builds. The simplest approach is one SVG converted per slot, or a single shared placeholder duplicated four times. Run:

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site/Website
mkdir -p public/showcase
for app in gifeditor terminal-workspace layouts-swiftui gitviz; do
  cat > public/showcase/$app.svg <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 750">
  <rect width="1200" height="750" fill="#0a0a0a"/>
  <text x="600" y="375" font-family="Geist Mono, monospace" font-size="36" fill="#34d399" text-anchor="middle">$app</text>
  <text x="600" y="420" font-family="Geist Mono, monospace" font-size="16" fill="#707070" text-anchor="middle">placeholder &middot; capture in 2.3 / 2.4</text>
</svg>
EOF
done
```

Real PNGs from Task 2.3 / 2.4 replace the SVGs at the same paths (or update the `<img src>` paths in the showcase page).

- [ ] **Step 2: Create the showcase page**

Create `swift-tui-site/Website/src/pages/showcase.astro`:

```astro
---
import "../styles/site.css";
import SiteHeader from "../components/SiteHeader.astro";
import SiteFooter from "../components/SiteFooter.astro";
import SiteIcons from "../components/SiteIcons.astro";

const base = import.meta.env.BASE_URL.replace(/\/$/, "");

const tiles = [
  {
    slug: "gifeditor",
    title: "GIF Editor",
    subtitle: "Canvas, layers, timeline, undo/redo &mdash; in the terminal.",
    body: "A full GIF editor written as ordinary SwiftTUI Views. Click tools, paint on a canvas, scrub a timeline, export an animated GIF. Proves that sophisticated desktop-class UX fits inside integer-cell rendering.",
    repo: "https://github.com/SwiftTUI/swift-tui-examples/tree/main/gifeditor",
  },
  {
    slug: "terminal-workspace",
    title: "Terminal Workspace",
    subtitle: "Zellij-style tabs, splits, and a command palette.",
    body: "Multi-pane terminal workspace built on SwiftTUITerminalWorkspace. Persisted layouts, focused chrome, command palette, embedded pty sessions. The framework is large enough to host its own multiplexer.",
    repo: "https://github.com/SwiftTUI/swift-tui-examples/tree/main/terminal-workspace",
  },
  {
    slug: "layouts-swiftui",
    title: "Layouts · side by side",
    subtitle: "Native SwiftUI on the left, SwiftTUI on the right.",
    body: "Visual proof of API parity: identical layout code rendering identical compositions in two substrates. Run the example, drag the split, watch them stay in lockstep as the geometry changes.",
    repo: "https://github.com/SwiftTUI/swift-tui-examples/tree/main/LayoutsSwiftUI",
  },
  {
    slug: "gitviz",
    title: "gitviz",
    subtitle: "Every SwiftTUICharts primitive against a real repo.",
    body: "Thirteen subcommands rendering BarChart, LineChart, StackedBarChart, CalendarHeatmap, Sparkline, BulletChart, ThresholdGauge, Meter, and Timeline against the git history of whatever repo you point it at. Dashboards in a terminal.",
    repo: "https://github.com/SwiftTUI/swift-tui-examples/tree/main/gitviz",
  },
];

const title = "Showcase &middot; SwiftTUI";
const description = "Four production-quality apps built with SwiftTUI: a GIF editor, a terminal workspace, a side-by-side SwiftUI/SwiftTUI layout demo, and a git visualization CLI.";
---
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>{title}</title>
    <meta name="description" content={description} />
    <link rel="canonical" href={`${base}/showcase/`} />
    <SiteIcons />
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@300;400;500;600&family=Geist+Mono:wght@400;500&display=swap" />
  </head>
  <body>
    <div class="ambient" aria-hidden="true"></div>
    <div class="grain" aria-hidden="true"></div>

    <SiteHeader />
    <main>
      <section class="showcase">
        <div class="shell">
          <header class="head">
            <span class="eyebrow"><span class="num">/00</span>Showcase</span>
            <h1>Built with SwiftTUI.</h1>
            <p class="lede">
              The framework already runs production-quality apps. These are
              maintained example apps in <span class="mono">swift-tui-examples</span> &mdash;
              clone the repo and they all build and run with one command.
            </p>
          </header>

          <ol class="grid">
            {tiles.map((t) => (
              <li class="tile">
                <a class="link" href={t.repo} rel="noreferrer noopener">
                  <div class="shot">
                    <img src={`${base}/showcase/${t.slug}.svg`} alt={`${t.title} screenshot`} loading="lazy" />
                  </div>
                  <div class="meta">
                    <h2>{t.title}</h2>
                    <p class="sub" set:html={t.subtitle} />
                    <p class="body">{t.body}</p>
                    <span class="cta">view source &rarr;</span>
                  </div>
                </a>
              </li>
            ))}
          </ol>
        </div>
      </section>
    </main>
    <SiteFooter />
  </body>
</html>

<style>
  .showcase { padding: 72px 0 56px; }
  .head { max-width: 760px; margin-bottom: 48px; }
  .head h1 { font-size: 44px; line-height: 1.05; letter-spacing: -0.02em; margin-top: 14px; }
  .head .lede { margin-top: 18px; max-width: 70ch; color: var(--ink-2); }

  .grid {
    list-style: none;
    margin: 0;
    padding: 0;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 28px;
  }
  .tile { background: var(--panel); border: 1px solid var(--line-strong); border-radius: 12px; overflow: hidden; }
  .tile .link { display: block; color: inherit; text-decoration: none; }
  .shot { aspect-ratio: 1200 / 750; overflow: hidden; background: #060606; }
  .shot img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .meta { padding: 22px 22px 24px; }
  .meta h2 { font-size: 20px; font-weight: 540; letter-spacing: -0.012em; }
  .meta .sub { color: var(--ink-2); font-size: 14px; margin-top: 6px; }
  .meta .body { color: var(--ink-3); font-size: 13.5px; line-height: 1.55; margin-top: 12px; }
  .meta .cta { display: inline-block; margin-top: 14px; font-family: var(--font-mono); font-size: 12px; color: var(--accent); }
  .tile:hover { border-color: var(--accent); }
  .tile:hover .cta { color: #2dd4a3; }

  @media (max-width: 920px) { .grid { grid-template-columns: 1fr; } }
</style>
```

- [ ] **Step 3: Add showcase to the site header nav**

Read `swift-tui-site/Website/src/components/SiteHeader.astro` to locate the nav `<ul>` or array of links. Add a `Showcase` link after `Why` (or wherever the existing nav items live). Concrete edit:

```bash
grep -n "Quickstart\|Pipeline\|nav\|href" swift-tui-site/Website/src/components/SiteHeader.astro | head -20
```

Then add an entry following the pattern already used in that file. If links are defined as an array, add `{ label: "Showcase", href: `${base}/showcase/` }` after the `Why` entry. If links are hardcoded `<a>` tags, insert one matching the existing style.

- [ ] **Step 4: Verify build**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
bun run --cwd Website check
bun run --cwd Website build
bun run --cwd Website dev
```

Visit `http://localhost:4321/showcase/` and confirm:
- Four tiles render in a 2×2 grid (1 column on mobile).
- Each tile shows the placeholder SVG; titles, subtitles, bodies render correctly.
- Header nav has a "Showcase" link that points to `/showcase/`.

- [ ] **Step 5: Commit**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
git add Website/src/pages/showcase.astro Website/src/components/SiteHeader.astro Website/public/showcase/
git commit -m "feat(site): add /showcase/ page with four built-with-SwiftTUI tiles"
```

---

## Task 2.3: Capture capability-proof screenshot strip

**Why:** `WhySwiftTUI` claim #04 ("ANSI, sanitized OSC 8 hyperlinks, Kitty graphics, Sixel, truecolor, mouse reporting … PNG and baseline JPEG decode in pure Swift; GIF playback ships in the AnimatedImage peer product.") makes 6+ specific claims with no visual proof. A single horizontal strip image with six small captures converts the paragraph from a list of assertions into evidence.

**Files:**
- Add: 6 source captures and 1 composed strip image under `swift-tui-site/Website/public/capabilities/`
- Modify: `swift-tui-site/Website/src/components/WhySwiftTUI.astro` (insert strip below card #04)

**Parallel-safe:** Yes (within Group C). Independent of 2.1 / 2.2 / 2.4.

- [ ] **Step 1: Identify a capture source for each cell**

For each of the six capabilities, name the example/test fixture you'll capture from:

| Cell | Capture source |
|---|---|
| Truecolor gradient | `gallery` → `AnimationsTab` or a custom one-shot view using `Color(red:green:blue:)` ramp |
| OSC 8 hyperlink | `gallery` running with OSC 8 enabled; or `swift-tui/Sources/SwiftTUIRuntime/...` test fixture |
| Kitty graphics | `gallery` → `ImagesTab` rendering a PNG in a Kitty-protocol terminal (e.g., `kitty`, `WezTerm`) |
| Sixel image | Same `ImagesTab` rendered in a Sixel-capable terminal (e.g., `xterm -ti vt340`, `mlterm`) |
| PNG (pure Swift) | `ImagesTab` static PNG (any terminal) |
| Animated GIF | `gifcat` running a small GIF, frame midpoint captured |

If any cell has no easy capture (e.g., no Kitty-capable terminal at hand), substitute with another verifiable capability (e.g., "incremental damage" by showing two consecutive frames with only the dirty cells highlighted) and update the alt text accordingly. Do not fake a capability.

- [ ] **Step 2: Capture each cell**

For each capture, produce a 400×200 PNG (or matching aspect):

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples

# Truecolor — run gallery and screenshot the AnimationsTab gradient
swiftly run swift run --package-path gallery GalleryDemo
# In another terminal, capture using OS screen-shot tool, crop to terminal window

# Kitty graphics — open Kitty/WezTerm, then:
swiftly run swift run --package-path gallery GalleryDemo
# Navigate to ImagesTab, capture

# Animated GIF — record a 1-frame still from gifcat
swiftly run swift run --package-path gifcat gifcat <some.gif>
```

Save each capture as `swift-tui-site/Website/public/capabilities/<slug>.png` where slug is one of: `truecolor`, `osc8`, `kitty`, `sixel`, `png`, `gif`.

- [ ] **Step 3: Compose the strip**

Either:
(a) Compose a single 1200×200 horizontal strip image using `sips` (macOS), ImageMagick, or any image tool, with the 6 captures side-by-side at 200×200 each, named `swift-tui-site/Website/public/capabilities/strip.png`; or
(b) Keep them as six separate `<img>` elements styled into a row in CSS (preferred — easier to alt-text individually).

Option (b) requires no new asset beyond the six PNGs already saved.

- [ ] **Step 4: Render the strip in WhySwiftTUI.astro**

Open `swift-tui-site/Website/src/components/WhySwiftTUI.astro` and locate card #04 (the `Capability-aware` card, currently `points[3]` in the array on lines 24–30).

Below the closing `</ol>` of the cards (after line 73), insert:

```html
    <div class="cap-strip" aria-label="Capability examples">
      {[
        { slug: "truecolor", alt: "Truecolor gradient rendered in 24-bit ANSI sequences" },
        { slug: "osc8",      alt: "OSC 8 hyperlink rendered inline" },
        { slug: "kitty",     alt: "PNG image rendered via Kitty graphics protocol" },
        { slug: "sixel",     alt: "Image rendered via Sixel protocol" },
        { slug: "png",       alt: "PNG decoded in pure Swift, rendered as half-cell glyphs" },
        { slug: "gif",       alt: "Animated GIF playback in the terminal" },
      ].map((c) => (
        <figure class="cap">
          <img src={`/capabilities/${c.slug}.png`} alt={c.alt} loading="lazy" />
          <figcaption class="mono">{c.slug}</figcaption>
        </figure>
      ))}
    </div>
```

And add CSS at the end of the existing `<style>` block:

```css
.cap-strip {
  display: grid;
  grid-template-columns: repeat(6, minmax(0, 1fr));
  gap: 12px;
  margin-top: 32px;
  border-top: 1px dashed var(--line);
  padding-top: 24px;
}
.cap { margin: 0; }
.cap img {
  width: 100%;
  aspect-ratio: 2 / 1;
  object-fit: cover;
  border-radius: 8px;
  background: #060606;
  border: 1px solid var(--line);
}
.cap figcaption {
  font-size: 10.5px;
  color: var(--ink-4);
  letter-spacing: 0.06em;
  text-transform: uppercase;
  margin-top: 8px;
  text-align: center;
}
@media (max-width: 920px) {
  .cap-strip { grid-template-columns: repeat(3, 1fr); }
}
@media (max-width: 480px) {
  .cap-strip { grid-template-columns: repeat(2, 1fr); }
}
```

- [ ] **Step 5: Verify visually**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
bun run --cwd Website check
bun run --cwd Website dev
```

Visit `http://localhost:4321#why` and confirm:
- A 6-cell strip appears below the differentiator cards.
- Each cell shows its capture; alt-text validates with browser dev tools.
- On mobile <920px the strip wraps to 3 columns; <480px to 2.

- [ ] **Step 6: Commit**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
git add Website/public/capabilities/ Website/src/components/WhySwiftTUI.astro
git commit -m "feat(site): add capability-proof screenshot strip under Why card #04"
```

---

## Task 2.4: Capture the "same source, three hosts" media

**Why:** This is the single highest-leverage marketing asset. A side-by-side recording of the same `CounterApp.swift` running as (a) terminal `swift run`, (b) embedded in `LayoutsSwiftUI` macOS host, (c) live WASI in the browser — looking visually identical except for the chrome — converts the abstract multi-host claim into immediate proof.

**Files:**
- Add: `swift-tui-examples/three-hosts-demo/` (new minimal example app — see step 1; one `Package.swift` + one `CounterApp.swift`)
- Add: `swift-tui-site/Website/public/three-hosts.gif` (or `.webm`)
- Modify: One of `Hero.astro` or `ExecutionModes.astro` to embed the media (step 5)

**Parallel-safe:** Yes (within Group C). Independent of others; uses the existing `LayoutsSwiftUI` host so no new framework code needed.

**Overlay note:** this task touches *two* submodules together (new example in `swift-tui-examples`, new media reference in `swift-tui-site`). Use `mise run worktree-gates` between steps to validate that the example builds *and* the site references resolve, without committing either change first. Capturing the recording in step 5 should be done against the overlay-built outputs so the recorded artifacts match what will land after pin bumps.

- [ ] **Step 1: Create the minimal three-hosts example app**

Create a new example under `swift-tui-examples/three-hosts-demo/`:

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples
mkdir -p three-hosts-demo/Sources/ThreeHostsDemo
```

Create `swift-tui-examples/three-hosts-demo/Package.swift`:

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "ThreeHostsDemo",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "three-hosts-demo", targets: ["ThreeHostsDemo"]),
    .library(name: "ThreeHostsDemoCore", targets: ["ThreeHostsDemoCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/SwiftTUI/swift-tui", .upToNextMinor(from: "0.0.1")),
  ],
  targets: [
    .target(name: "ThreeHostsDemoCore", dependencies: [
      .product(name: "SwiftTUI", package: "swift-tui"),
    ]),
    .executableTarget(name: "ThreeHostsDemo", dependencies: ["ThreeHostsDemoCore"]),
  ]
)
```

Create `swift-tui-examples/three-hosts-demo/Sources/ThreeHostsDemoCore/CounterApp.swift` (the exact code shown on the marketing site in Task 1.2):

```swift
import SwiftTUI

public struct CounterView: View {
  @State private var count = 0
  @FocusState private var focused: Bool

  public init() {}

  public var body: some View {
    VStack(spacing: 1) {
      Text("Count: \(count)").bold()
      Button("Increment") { count += 1 }
        .focused($focused)
    }
    .onAppear { focused = true }
    .padding(2)
  }
}

public struct CounterApp: App {
  public init() {}

  public var body: some Scene {
    WindowGroup("Counter") {
      CounterView()
    }
  }
}
```

And `swift-tui-examples/three-hosts-demo/Sources/ThreeHostsDemo/main.swift`:

```swift
import ThreeHostsDemoCore
import SwiftTUIRuntime

@main struct Main {
  static func main() {
    TerminalRunner.run(CounterApp())
  }
}
```

- [ ] **Step 2: Build and verify the terminal run**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples/three-hosts-demo
swiftly run swift build
swiftly run swift run three-hosts-demo
```

Confirm a terminal window shows `Count: 0` and `[ Increment ]`, with the button focused. Press Enter / Space to increment. Quit with Ctrl-D.

- [ ] **Step 3: Wire the same target into LayoutsSwiftUI as a third pane**

Open `swift-tui-examples/LayoutsSwiftUI/` and locate the SwiftUI host file (the one that imports SwiftTUI scenes via `SwiftUIHost`). Add a small case/tab that renders `CounterApp()` from `ThreeHostsDemoCore`. If LayoutsSwiftUI doesn't currently support adding an arbitrary scene, instead build a tiny new SwiftUI Xcode/SwiftPM app at `swift-tui-examples/three-hosts-demo/SwiftUIHost/` that just embeds `CounterApp()`:

```swift
// swift-tui-examples/three-hosts-demo/SwiftUIHost/ContentView.swift (or App.swift)
import SwiftUI
import SwiftTUI
import SwiftUIHost
import ThreeHostsDemoCore

@main struct CounterHostApp: SwiftUI.App {
  var body: some SwiftUI.Scene {
    WindowGroup {
      SwiftUIHostAppView(app: CounterApp())
        .frame(minWidth: 320, minHeight: 200)
    }
  }
}
```

Run it and confirm the same Counter UI appears inside a native macOS window.

- [ ] **Step 4: Build the WASI variant and verify it runs in the browser**

Reuse the WebExample build pipeline pattern, but with `ThreeHostsDemoCore`:

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples/three-hosts-demo
swiftly run swift build \
  --triple wasm32-unknown-wasi \
  --swift-sdk swift-6.3.1-RELEASE_wasm \
  -Xswiftc -Osize \
  -Xswiftc -Xfrontend -Xswiftc -disable-llvm-merge-functions-pass
```

(See `swift-tui-examples/WebExample/CLAUDE.md` for the load-bearing build flags — `-Osize` plus `-disable-llvm-merge-functions-pass` are required.)

Serve the resulting wasm via the existing WebExample dev server (point `WEBEXAMPLE_DIR` or copy the artifact into the WebExample pipeline). Confirm the same Counter renders in the browser.

- [ ] **Step 5: Record the three-pane media**

Capture a screen recording or composite three terminal recordings:
- Pane 1: terminal window running `swift run three-hosts-demo`
- Pane 2: macOS native window running the SwiftUI host
- Pane 3: browser window running the WASI build

In each, increment the counter to 3 (or some matching value), and capture ~10s. Compose into a single GIF or WebM (≤2 MB for GIF, ≤4 MB for WebM):

```bash
# example with ffmpeg: combine three 600x400 captures into a 1800x400 horizontal strip GIF
ffmpeg -i terminal.mov -i swiftui.mov -i browser.mov \
  -filter_complex "[0:v]scale=600:400[a];[1:v]scale=600:400[b];[2:v]scale=600:400[c];[a][b][c]hstack=inputs=3,fps=12" \
  -t 10 swift-tui-site/Website/public/three-hosts.gif
```

Save as `swift-tui-site/Website/public/three-hosts.gif` (or `.webm` if size is critical).

- [ ] **Step 6: Embed the media in the site**

Pick one of two placements:

(a) Inline below the new "four runs" install block in `Hero.astro` (good if the file size stays small). After the install block from Task 1.3, add:

```html
      <figure class="three-hosts reveal" style="--i:6" aria-label="The same CounterApp source running in three hosts">
        <img src={`${base}/three-hosts.gif`} alt="Same SwiftTUI source running as a terminal executable, embedded in a native SwiftUI window, and in a browser via WASI." loading="lazy" />
        <figcaption class="mono">terminal &middot; SwiftUI &middot; browser &mdash; same <span class="ty">CounterApp</span> source</figcaption>
      </figure>
```

(b) As a dedicated row inside `ExecutionModes.astro` if the existing four-mode block already lives there.

Choose based on file size and layout — if the GIF is >1 MB, prefer (b) with lazy loading further down the page. Add minimal CSS for the figure (border, rounded corners, captions in monospace), reusing existing variables.

- [ ] **Step 7: Verify**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
bun run --cwd Website check
bun run --cwd Website build
bun run --cwd Website dev
```

Visit the site, confirm the GIF plays and the caption is legible. Confirm `bun run build` total bundle size hasn't ballooned (>500 KB site without the GIF; the GIF itself is the bulk).

- [ ] **Step 8: Commit**

Two commits — one per submodule:

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples
git add three-hosts-demo/
git commit -m "feat(examples): add three-hosts-demo with terminal + SwiftUI + WASI parity"

cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
git add Website/public/three-hosts.gif Website/src/components/Hero.astro  # or ExecutionModes.astro
git commit -m "feat(site): embed three-hosts demo media proving multi-host claim"
```

---

# Phase 3: Integration

## Task 3.1: Validate uncommitted tree, commit children, bump pins, run head-mode gate

**Why:** Until now agents have been editing uncommitted trees and validating with worktree-mode gates. The integration step commits each affected submodule, records the new SHAs in the org root, and verifies the *committed* tree passes the same gate logic that CI uses (`//:org_full`, head mode).

**Files:**
- Commit (per submodule): all working-tree edits made in Phases 1 and 2
- Modify (commit): `/Users/adamz/Developer/swift-tui-org/swift-tui-site`, `swift-tui-examples` (submodule pointer entries)

**Parallel-safe:** No. Runs last.

- [ ] **Step 1: Final worktree-gate sweep before committing anything**

```bash
cd /Users/adamz/Developer/swift-tui-org
git -C swift-tui-site status
git -C swift-tui-examples status
mise run worktree-gates
```

Expected: PASS. Both child working trees should show the full set of marketing edits; the gate should validate the same composition that the pretag head-mode gate will see once committed. If the gate fails here, fix in the appropriate submodule before committing — *do not commit broken edits*.

- [ ] **Step 2: Commit inside each affected submodule**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
git status
git add Website/   # add only intentional paths; double-check nothing extra is staged
git commit -m "feat(site): marketing improvements bundle (hero, authoring, showcase, comparison, capability strip, three-hosts)"

cd /Users/adamz/Developer/swift-tui-org/swift-tui-examples
git status
git add WebExample/ three-hosts-demo/
git commit -m "feat(examples): expand WebExample to 4-scene tour, add three-hosts-demo"
```

Use multiple smaller commits per submodule if the task-by-task history is more readable than the bundle commits shown above — the worktree gate already validated the full composition.

- [ ] **Step 3: Stage submodule pointer updates in the org root**

```bash
cd /Users/adamz/Developer/swift-tui-org
git status
# expect: changes to swift-tui-site and swift-tui-examples submodule pointers, plus the new plan doc
git add swift-tui-site swift-tui-examples docs/plans/2026-05-27-002-marketing-improvements-plan.md
git diff --cached
```

Confirm the diff shows only the submodule SHA pointer updates (plus the plan markdown), no other content.

- [ ] **Step 4: Fetch Bazel external state and run the fast gate**

```bash
cd /Users/adamz/Developer/swift-tui-org
mise exec -- bazel fetch //:org_full
mise exec -- bazel test //:org_fast
```

Expected: PASS. `org_fast` runs cheap registry, workflow, and cleanliness checks against the newly-pinned children.

- [ ] **Step 5: Run the full head-mode gate suite**

```bash
cd /Users/adamz/Developer/swift-tui-org
mise exec -- bazel test //:org_full
```

This runs the site Astro build, the examples gate, and both pretag overlay gates in **head mode** (matching CI byte-for-byte). Expected: PASS. The worktree gate already passed in step 1, so head mode should pass too — unless an untracked-but-uncommitted file was load-bearing (a common cause; check `git status` in each submodule).

- [ ] **Step 6: Commit the integration**

```bash
cd /Users/adamz/Developer/swift-tui-org
git commit -m "chore: bump site + examples pins for marketing improvements"
```

- [ ] **Step 7: Smoke-test the production build of the site**

```bash
cd /Users/adamz/Developer/swift-tui-org/swift-tui-site
bun run --cwd Website build:full   # site + wasm demo + DocC composition
bun run --cwd Website preview
```

Visit the preview URL and click through:
- Hero loads with placeholder behind iframe, fades to live demo
- Sub-headline reads the rewrite
- Authoring snippet is the Counter
- Comparison matrix visible
- Demo embed cycles through 4 scenes
- Showcase page reachable from nav
- Capability strip visible under WhySwiftTUI card #04
- Three-hosts media plays where placed

If anything regresses, open a follow-up task scoped to the specific regression rather than reverting the integration.

---

# Self-review checklist (run after writing, before handoff)

- [ ] Every task has exact file paths under `/Users/adamz/Developer/swift-tui-org/`.
- [ ] Every code/copy block is complete — no `<placeholder>`, no "fill in", no "similar to above".
- [ ] Every Astro task has `bun run check && bun run dev` verification.
- [ ] Every Swift task that adds behavior has a `@Test` with concrete `#expect`.
- [ ] Every change to a submodule is committed inside the submodule before the org-root pin bump.
- [ ] Asset tasks (placeholders, captures) name an exact output path under `Website/public/`.
- [ ] No task depends on a framework code change in `swift-tui/` — all distinctive functionality is already there.
- [ ] Cross-task references (e.g., `CounterApp.swift` in 1.2 ↔ Task 2.4 source) use the same identifiers.

---

# Execution handoff

Two execution options:

**1. Subagent-driven (recommended)** — Dispatch fresh subagents per task; review between tasks; tasks within the same Group (A, B, C) run in parallel. Order: Group A (4 agents) → Group B (2 agents) → Group C (4 agents) → Task 3.1 serially.

**2. Inline execution** — Run tasks in this session sequentially, checkpointing after each group. Useful if the human wants to review copy after every Hero edit.
