# WASI Worker Scheduler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [x]`) syntax for tracking.

**Goal:** Make the static WASI browser runtime honor SwiftTUI timer deadlines
closely enough that the WebExample Game of Life scene advances at the authored
110 ms cadence instead of the observed 230-240 ms median cadence.

**Architecture:** Keep the Swift render pipeline unchanged until the worker
boundary proves it needs Swift changes. Add a browser cadence regression first,
then replace the clock-only `poll_oneoff` patch with a small worker-side WASI
poll scheduler that handles clock, stdin/readiness, and mixed clock+stdin
subscriptions with `SharedArrayBuffer` and `Atomics.wait`.

**Tech Stack:** SwiftTUIWASI, `@bjorn3/browser_wasi_shim`, TypeScript, Bun test,
Playwright, SharedArrayBuffer, Atomics, Swift 6.3.1 via `swiftly`.

---

## Current Evidence

- `gallery-demo --web` uses the native WebHost runner and localhost WebSocket
  transport. Its Game of Life frame cadence measures around 113 ms.
- `https://swifttui.sh/webexample/?embed=marketing` and a local static
  WebExample build both use the WASI worker path. Their frame cadence measures
  around 235 ms.
- Disabling the current clock-only `installEfficientClockPoll(...)` did not
  materially change the cadence, so the fix should target the full WASI
  scheduling boundary rather than tuning the existing single-clock fast path.
- Returning stdin EOF when idle made cadence worse. Idle stdin must remain live;
  the worker should block readiness through `poll_oneoff`, not pretend the
  stream has ended.

## File Structure To Create Or Modify

- Create `swift-tui-web/packages/web/src/wasi/WasiPollScheduler.ts`: worker-side
  WASI poll scheduler and small subscription model.
- Create `swift-tui-web/packages/web/src/wasi/WasiPollScheduler.test.ts`: unit
  tests for clock-only, stdin-only, mixed stdin+clock, timeout, and closed-stdin
  behavior.
- Modify `swift-tui-web/packages/web/src/wasi/SharedInputQueue.ts`: expose
  non-consuming readiness and timed blocking waits for the scheduler.
- Modify `swift-tui-web/packages/web/src/wasi/SharedInputQueue.test.ts`: cover
  readiness wait, timeout, close wakeup, and write wakeup behavior.
- Modify `swift-tui-web/packages/web/src/wasi/WasmSceneWorker.ts`: replace
  `installEfficientClockPoll(...)` with the scheduler install call.
- Create `swift-tui-examples/WebExample/src/frame-cadence.browser.ts`:
  browser integration regression for Game of Life frame cadence.
- Modify `swift-tui-examples/WebExample/package.json`: include the new
  browser cadence test in `test:browser`.
- Modify `swift-tui/docs/HOSTS-AND-PLATFORMS.md`: record that WASI worker
  scheduling is responsible for blocking stdin/timer readiness.
- Modify `swift-tui/docs/RENDER-PIPELINE.md`: add a short note that WASI runs
  the frame tail inline but timer wakeup accuracy is owned by the browser worker
  WASI scheduler.

---

### Task 1: Add A Failing WebExample Cadence Regression

**Files:**
- Create: `swift-tui-examples/WebExample/src/frame-cadence.browser.ts`
- Modify: `swift-tui-examples/WebExample/package.json`

- [x] **Step 1: Write the browser cadence test**

  Create `src/frame-cadence.browser.ts` with a JSON-parse probe that records
  decoded web-surface frame times. The current static WASI worker should fail
  this test with a median delta above 200 ms.

  ```ts
  import { expect, test } from "bun:test";
  import { chromium } from "playwright";

  import { serveBuiltWebExample } from "./built-app-server.ts";

  declare global {
    interface Window {
      __swiftTUIFrameSamples?: number[];
    }
  }

  test("WebExample Game of Life keeps the authored WASI frame cadence", async () => {
    const server = serveBuiltWebExample();
    const browser = await chromium.launch();
    const page = await browser.newPage({
      viewport: {
        width: 1280,
        height: 900,
      },
    });

    await page.addInitScript(() => {
      const originalParse = JSON.parse;
      const samples: number[] = [];
      Object.defineProperty(window, "__swiftTUIFrameSamples", {
        configurable: true,
        value: samples,
      });
      JSON.parse = function patchedJSONParse(
        text: string,
        reviver?: Parameters<typeof JSON.parse>[1]
      ) {
        const value = originalParse.call(this, text, reviver);
        if (isSurfaceFrame(value)) {
          samples.push(performance.now());
        }
        return value;
      };

      function isSurfaceFrame(value: unknown): boolean {
        if (!value || typeof value !== "object") {
          return false;
        }
        const frame = value as {
          width?: unknown;
          height?: unknown;
          rows?: unknown;
        };
        return typeof frame.width === "number"
          && typeof frame.height === "number"
          && Array.isArray(frame.rows);
      }
    });

    try {
      await page.goto(server.url.href, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => globalThis.crossOriginIsolated === true, undefined, {
        timeout: 10_000,
      });
      await page.waitForSelector(".webhost-scene__surface", {
        state: "attached",
        timeout: 30_000,
      });
      await page.waitForFunction(
        () => (window.__swiftTUIFrameSamples?.length ?? 0) >= 40,
        undefined,
        { polling: 100, timeout: 30_000 }
      );

      const samples = await page.evaluate(() => window.__swiftTUIFrameSamples ?? []);
      const deltas = samples.slice(1).map((sample, index) => sample - samples[index]!);
      const steady = deltas.slice(8).filter((delta) => delta > 10);
      const median = percentile(steady, 0.5);
      const p95 = percentile(steady, 0.95);

      expect(steady.length).toBeGreaterThanOrEqual(24);
      expect(median).toBeLessThanOrEqual(150);
      expect(p95).toBeLessThanOrEqual(190);
    } finally {
      await page.close();
      await browser.close();
      server.stop(true);
    }
  }, 120_000);

  function percentile(
    values: number[],
    fraction: number
  ): number {
    const sorted = [...values].sort((lhs, rhs) => lhs - rhs);
    const index = Math.min(
      sorted.length - 1,
      Math.max(0, Math.floor((sorted.length - 1) * fraction))
    );
    return sorted[index] ?? Number.POSITIVE_INFINITY;
  }
  ```

- [x] **Step 2: Include the cadence test in the browser script**

  In `package.json`, change `test:browser` to run all browser integration files:

  ```json
  "test:browser": "playwright install chromium && bun run build && bun test ./src/*.browser.ts --timeout 120000"
  ```

- [x] **Step 3: Run the regression and capture the failure**

  Run:

  ```bash
  bun --cwd swift-tui-examples/WebExample run test:browser
  ```

  Expected now: the existing nonblank canvas test passes and the new cadence
  test fails with `median` above `150`.

- [x] **Step 4: Commit the failing regression**

  ```bash
  git -C swift-tui-examples add WebExample/src/frame-cadence.browser.ts WebExample/package.json
  git -C swift-tui-examples commit -m "test: cover WASI worker frame cadence"
  ```

### Task 2: Add Readiness APIs To The Shared Input Queue

**Files:**
- Modify: `swift-tui-web/packages/web/src/wasi/SharedInputQueue.ts`
- Modify: `swift-tui-web/packages/web/src/wasi/SharedInputQueue.test.ts`

- [x] **Step 1: Add failing queue readiness tests**

  Append these tests to `SharedInputQueue.test.ts`:

  ```ts
  test("shared input queue reports readable bytes without consuming them", () => {
    const queue = createSharedInputQueue(8);
    const writer = new SharedInputQueueWriter(queue);
    const reader = new SharedInputQueueReader(queue);

    expect(reader.availableBytes()).toBe(0);

    writer.write("abc");

    expect(reader.availableBytes()).toBe(3);
    expect(decode(reader.readAvailable(2))).toBe("ab");
    expect(reader.availableBytes()).toBe(1);
  });

  test("shared input queue timed readiness wait wakes on write", () => {
    const queue = createSharedInputQueue(8);
    const writer = new SharedInputQueueWriter(queue);
    const reader = new SharedInputQueueReader(queue);

    setTimeout(() => writer.write("x"), 10);

    expect(reader.waitForReadable(250)).toBe("readable");
    expect(decode(reader.readAvailable(1))).toBe("x");
  });

  test("shared input queue timed readiness wait returns timedOut", () => {
    const queue = createSharedInputQueue(8);
    const reader = new SharedInputQueueReader(queue);

    expect(reader.waitForReadable(1)).toBe("timedOut");
  });

  test("shared input queue readiness wait wakes on close", () => {
    const queue = createSharedInputQueue(8);
    const writer = new SharedInputQueueWriter(queue);
    const reader = new SharedInputQueueReader(queue);

    writer.close();

    expect(reader.waitForReadable(250)).toBe("closed");
  });
  ```

- [x] **Step 2: Run tests and verify they fail**

  ```bash
  bun --cwd swift-tui-web/packages/web test src/wasi/SharedInputQueue.test.ts
  ```

  Expected: FAIL because `availableBytes()` and `waitForReadable(...)` do not
  exist.

- [x] **Step 3: Implement queue readiness without consuming bytes**

  Add this result type and methods to `SharedInputQueue.ts`:

  ```ts
  export type SharedInputReadiness = "readable" | "closed" | "timedOut";
  ```

  ```ts
  availableBytes(): number {
    const readIndex = Atomics.load(this.queue.control, ControlSlot.readIndex);
    const writeIndex = Atomics.load(this.queue.control, ControlSlot.writeIndex);
    return Math.max(0, writeIndex - readIndex);
  }

  waitForReadable(
    timeoutMilliseconds?: number
  ): SharedInputReadiness {
    while (true) {
      if (this.availableBytes() > 0) {
        return "readable";
      }
      if (this.isClosed()) {
        return "closed";
      }

      const writeIndex = Atomics.load(this.queue.control, ControlSlot.writeIndex);
      const result = Atomics.wait(
        this.queue.control,
        ControlSlot.writeIndex,
        writeIndex,
        timeoutMilliseconds
      );
      if (result === "timed-out") {
        return "timedOut";
      }
    }
  }
  ```

- [x] **Step 4: Verify queue tests pass**

  ```bash
  bun --cwd swift-tui-web/packages/web test src/wasi/SharedInputQueue.test.ts
  ```

  Expected: PASS.

- [x] **Step 5: Commit the queue readiness API**

  ```bash
  git -C swift-tui-web add packages/web/src/wasi/SharedInputQueue.ts packages/web/src/wasi/SharedInputQueue.test.ts
  git -C swift-tui-web commit -m "feat: expose WASI stdin readiness"
  ```

### Task 3: Extract A WASI Poll Scheduler

**Files:**
- Create: `swift-tui-web/packages/web/src/wasi/WasiPollScheduler.ts`
- Create: `swift-tui-web/packages/web/src/wasi/WasiPollScheduler.test.ts`

- [x] **Step 1: Write scheduler tests against a fake memory view**

  Create `WasiPollScheduler.test.ts` with tests that construct subscriptions
  through the same `wasi.Subscription` and `wasi.Event` classes the worker uses.
  The tests should assert:

  ```ts
  import { expect, test } from "bun:test";
  import { wasi } from "@bjorn3/browser_wasi_shim";

  import {
    WasiPollScheduler,
    type WasiPollReadableSource,
    writeClockSubscriptionForTesting,
    writeFdReadSubscriptionForTesting,
    readPollEventsForTesting,
  } from "./WasiPollScheduler.ts";
  import {
    SharedInputQueueReader,
    SharedInputQueueWriter,
    createSharedInputQueue,
  } from "./SharedInputQueue.ts";

  test("scheduler completes a relative monotonic clock subscription", () => {
    const memory = new WebAssembly.Memory({ initial: 1 });
    const view = new DataView(memory.buffer);
    writeClockSubscriptionForTesting(view, 0, {
      userdata: 1n,
      timeoutNanoseconds: 1_000_000n,
    });

    const scheduler = new WasiPollScheduler({
      memory: () => memory,
      stdin: closedSource(),
      fallbackPoll: () => wasi.ERRNO_INVAL,
    });

    expect(scheduler.pollOneOff(0, 128, 1)).toBe(wasi.ERRNO_SUCCESS);
    expect(readPollEventsForTesting(view, 128, 1)).toEqual([
      { userdata: 1n, errno: wasi.ERRNO_SUCCESS, eventtype: wasi.EVENTTYPE_CLOCK },
    ]);
  });

  test("scheduler wakes mixed stdin and clock poll on stdin readability", () => {
    const memory = new WebAssembly.Memory({ initial: 1 });
    const view = new DataView(memory.buffer);
    const queue = createSharedInputQueue(8);
    const writer = new SharedInputQueueWriter(queue);
    const reader = new SharedInputQueueReader(queue);

    writeFdReadSubscriptionForTesting(view, 0, { userdata: 10n, fd: 0 });
    writeClockSubscriptionForTesting(view, 48, {
      userdata: 11n,
      timeoutNanoseconds: 500_000_000n,
    });

    setTimeout(() => writer.write("x"), 10);

    const scheduler = new WasiPollScheduler({
      memory: () => memory,
      stdin: reader,
      fallbackPoll: () => wasi.ERRNO_INVAL,
    });

    expect(scheduler.pollOneOff(0, 128, 2)).toBe(wasi.ERRNO_SUCCESS);
    expect(readPollEventsForTesting(view, 128, 2)).toEqual([
      { userdata: 10n, errno: wasi.ERRNO_SUCCESS, eventtype: wasi.EVENTTYPE_FD_READ },
    ]);
  });

  function closedSource(): WasiPollReadableSource {
    return {
      availableBytes: () => 0,
      isClosed: () => true,
      waitForReadable: () => "closed",
    };
  }
  ```

- [x] **Step 2: Run tests and verify they fail**

  ```bash
  bun --cwd swift-tui-web/packages/web test src/wasi/WasiPollScheduler.test.ts
  ```

  Expected: FAIL because `WasiPollScheduler.ts` does not exist.

- [x] **Step 3: Implement the scheduler module**

  Create `WasiPollScheduler.ts` with:

  ```ts
  import { wasi } from "@bjorn3/browser_wasi_shim";
  import type { SharedInputReadiness } from "./SharedInputQueue.ts";

  export interface WasiPollReadableSource {
    availableBytes(): number;
    isClosed(): boolean;
    waitForReadable(timeoutMilliseconds?: number): SharedInputReadiness;
  }

  export interface WasiPollSchedulerOptions {
    memory(): WebAssembly.Memory | undefined;
    stdin: WasiPollReadableSource;
    fallbackPoll(inPtr: number, outPtr: number, nsubscriptions: number): number;
    nowMilliseconds?(): number;
  }

  export class WasiPollScheduler {
    private readonly memory: WasiPollSchedulerOptions["memory"];
    private readonly stdin: WasiPollReadableSource;
    private readonly fallbackPoll: WasiPollSchedulerOptions["fallbackPoll"];
    private readonly nowMilliseconds: () => number;

    constructor(options: WasiPollSchedulerOptions) {
      this.memory = options.memory;
      this.stdin = options.stdin;
      this.fallbackPoll = options.fallbackPoll;
      this.nowMilliseconds = options.nowMilliseconds ?? (() => performance.now());
    }

    pollOneOff(
      inPtr: number,
      outPtr: number,
      nsubscriptions: number
    ): number {
      const memory = this.memory();
      if (!memory || nsubscriptions <= 0) {
        return this.fallbackPoll(inPtr, outPtr, nsubscriptions);
      }

      const view = new DataView(memory.buffer);
      const subscriptions = readSubscriptions(view, inPtr, nsubscriptions);
      if (!subscriptions.every(isSupportedSubscription)) {
        return this.fallbackPoll(inPtr, outPtr, nsubscriptions);
      }

      const timeoutMilliseconds = shortestClockTimeoutMilliseconds(
        subscriptions,
        this.nowMilliseconds()
      );
      if (!hasReadyStdin(subscriptions, this.stdin)) {
        const readiness = this.stdin.waitForReadable(timeoutMilliseconds);
        if (readiness === "timedOut" && timeoutMilliseconds === undefined) {
          return this.fallbackPoll(inPtr, outPtr, nsubscriptions);
        }
      }

      const ready = readySubscriptions(
        subscriptions,
        this.stdin,
        this.nowMilliseconds()
      );
      writeEvents(view, outPtr, ready);
      return wasi.ERRNO_SUCCESS;
    }
  }
  ```

  Keep the helper functions in the same file. `readSubscriptions(...)` should use
  `wasi.Subscription.read_bytes(view, offset)`, advancing by the WASI
  subscription record size used by `browser_wasi_shim`. `writeEvents(...)`
  should write one `wasi.Event` per ready subscription and return success with at
  least one event when a clock expires, stdin becomes readable, or stdin closes.

- [x] **Step 4: Verify scheduler unit tests pass**

  ```bash
  bun --cwd swift-tui-web/packages/web test src/wasi/WasiPollScheduler.test.ts
  ```

  Expected: PASS.

- [x] **Step 5: Commit the scheduler module**

  ```bash
  git -C swift-tui-web add packages/web/src/wasi/WasiPollScheduler.ts packages/web/src/wasi/WasiPollScheduler.test.ts
  git -C swift-tui-web commit -m "feat: schedule WASI clock and stdin polls"
  ```

### Task 4: Install The Scheduler In The WASI Worker

**Files:**
- Modify: `swift-tui-web/packages/web/src/wasi/WasmSceneWorker.ts`

- [x] **Step 1: Replace the old clock-only shim**

  In `WasmSceneWorker.ts`, replace `installEfficientClockPoll(...)` with a
  scheduler install that owns the same import patch:

  ```ts
  import { WasiPollScheduler } from "./WasiPollScheduler.ts";
  ```

  ```ts
  const stdin = new BlockingInputFileDescriptor(message.inputQueue);
  const wasiBridge = new WASI(
    ["app.wasm"],
    Object.entries(message.environment).map(([key, value]) => `${key}=${value}`),
    [
      stdin,
      new ConsoleStdout((chunk) => {
        postWorkerMessage({ type: "stdout", chunk });
      }),
      new ConsoleStdout((chunk) => {
        postWorkerMessage({ type: "stderr", chunk });
      }),
    ]
  );
  installWasiPollScheduler(wasiBridge, stdin);
  ```

  ```ts
  function installWasiPollScheduler(
    wasiBridge: WASI,
    stdin: BlockingInputFileDescriptor
  ): void {
    const originalPoll = wasiBridge.wasiImport.poll_oneoff;
    if (typeof originalPoll !== "function") {
      return;
    }

    const scheduler = new WasiPollScheduler({
      memory: () => wasiBridge.inst?.exports.memory as WebAssembly.Memory | undefined,
      stdin,
      fallbackPoll: (inPtr, outPtr, nsubscriptions) =>
        originalPoll(inPtr, outPtr, nsubscriptions),
    });
    wasiBridge.wasiImport.poll_oneoff = (inPtr, outPtr, nsubscriptions) =>
      scheduler.pollOneOff(inPtr, outPtr, nsubscriptions);
  }
  ```

- [x] **Step 2: Make `BlockingInputFileDescriptor` implement readiness**

  Add these methods:

  ```ts
  availableBytes(): number {
    return this.reader.availableBytes();
  }

  waitForReadable(timeoutMilliseconds?: number) {
    return this.reader.waitForReadable(timeoutMilliseconds);
  }
  ```

  Leave `fd_read(...)` returning `ERRNO_AGAIN` when no data is available and the
  queue is not closed. `poll_oneoff` now blocks for readiness; `fd_read` should
  still be non-blocking when called outside a readiness poll.

- [x] **Step 3: Run worker-adjacent tests**

  ```bash
  bun --cwd swift-tui-web/packages/web test src/wasi
  ```

  Expected: PASS.

- [x] **Step 4: Commit the worker integration**

  ```bash
  git -C swift-tui-web add packages/web/src/wasi/WasmSceneWorker.ts
  git -C swift-tui-web commit -m "fix: use scheduler-backed WASI polling"
  ```

### Task 5: Prove The Static WebExample Cadence Is Fixed

**Files:**
- No new files in this task.

- [x] **Step 1: Run the focused browser regression**

  ```bash
  bun --cwd swift-tui-examples/WebExample run test:browser
  ```

  Expected: PASS. The cadence test should report a steady median below `150 ms`
  and p95 below `190 ms`.

- [x] **Step 2: Run web package tests**

  ```bash
  bun --cwd swift-tui-web/packages/web test
  ```

  Expected: PASS.

- [x] **Step 3: Rebuild the WebExample static bundle**

  ```bash
  bun --cwd swift-tui-examples/WebExample run build
  ```

  Expected: PASS and `WebExample/dist/wasm-scene-worker.js` includes
  the scheduler-backed worker bundle.

- [x] **Step 4: Commit the passing cadence proof**

  ```bash
  git -C swift-tui-examples add WebExample/package.json WebExample/src/frame-cadence.browser.ts
  git -C swift-tui-examples commit -m "test: verify static WASI frame cadence"
  ```

### Task 6: Update Runtime Documentation

**Files:**
- Modify: `swift-tui/docs/HOSTS-AND-PLATFORMS.md`
- Modify: `swift-tui/docs/RENDER-PIPELINE.md`

- [x] **Step 1: Document the worker scheduling contract**

  In `HOSTS-AND-PLATFORMS.md`, add this paragraph under `## The web packages`:

  ```markdown
  The WASI browser worker owns stdin and timer readiness for Swift code compiled
  to WASI. Its `poll_oneoff` adapter blocks on `SharedArrayBuffer`/`Atomics`
  rather than polling from JavaScript, and it must wake for clock deadlines,
  stdin readability, resize/style control messages, and queue closure.
  ```

- [x] **Step 2: Document the WASI inline-tail distinction**

  In `RENDER-PIPELINE.md`, extend the WASI bullet under
  `## Main actor versus frame-tail worker`:

  ```markdown
  On WASI, where there is no background execution, an immediate inline worker
  runs the same stages synchronously. Timer wakeup accuracy for async Swift
  tasks is still owned by the browser worker's WASI scheduler; the render
  pipeline consumes the wakeups after the WASI runtime resumes Swift tasks.
  ```

- [x] **Step 3: Verify docs and package tests**

  ```bash
  git -C swift-tui diff --check
  bun --cwd swift-tui-web/packages/web test
  bun --cwd swift-tui-examples/WebExample run test:browser
  ```

  Expected: all commands pass.

- [x] **Step 4: Commit the documentation**

  ```bash
  git -C swift-tui add docs/HOSTS-AND-PLATFORMS.md docs/RENDER-PIPELINE.md
  git -C swift-tui commit -m "docs: record WASI worker scheduling contract"
  ```
