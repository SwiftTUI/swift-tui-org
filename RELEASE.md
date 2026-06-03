# Releasing the SwiftTUI org

How to cut a new lockstep release (`swift-tui`, `swift-tui-web`,
`swift-tui-examples`, `swift-tui-site` all move to the same version together).
This is the runbook the `bump_version.sh` tool deliberately stops short of —
everything here is **irreversible / outward-facing** (tags, GitHub releases, npm
publishes) and is the maintainer's to drive.

> Worked example: this doc was written while cutting `0.0.11`. Substitute your
> target version for `0.0.11` throughout.

## Mental model — read this first

Two facts drive the entire procedure:

1. **The version string is denormalized across four repos.** `package.json`
   versions, SwiftPM `exact:`/`upToNextMinor(from:)` pins, the Xcode
   `exactVersion`, GitHub release tarball URLs, `tree`/`blob`/`tag` links, site
   display strings, and the canonical `swift-tui-site/docs/releases.yml` manifest
   all hardcode it. `tools/coordination/bump_version.sh --write` rewrites the
   *authored* occurrences. It never touches generated lockfiles, tags, or
   publishes.

2. **The cross-repo dependency path is the GitHub release tarball, not npm.**
   `swift-tui-examples/WebExample` and `swift-tui-site` install `@swifttui/web`
   and `@swifttui/build` from
   `https://github.com/SwiftTUI/swift-tui-web/releases/download/<ver>/swifttui-<pkg>-<ver>.tgz`.
   **npm publishing alone does nothing for in-org consumers.** The GitHub release
   with the two `.tgz` assets attached is the artifact that unblocks CI. npm is
   for *external* consumers.

### Why `0.0.8` failed CI (the trap this runbook exists to prevent)

For `0.0.8`, the packages were published to npm, but the `swift-tui-web` **git
tag and GitHub release were never created**. Every downstream
`bun install --frozen-lockfile` then hit:

```
error: GET .../releases/download/0.0.8/swifttui-web-0.0.8.tgz - 404
error: command failed (1): bun install --frozen-lockfile   # swift-tui-site gate
```

The fix is always: **create the `swift-tui-web` GitHub release with both `.tgz`
assets** before (or as part of) the release. If the tarball URLs 404, the
examples and site gates fail no matter what npm says.

## Dependency / ordering

Release in this order — each step depends on the previous one being pushed:

```
swift-tui-web  →  swift-tui  →  swift-tui-examples  →  swift-tui-site  →  swift-tui-org (root)
   (leaf artifact)                (consumes web tag + swift-tui tag)        (records pins)
```

## Prerequisites

- `mise trust && mise install` (Bazelisk + Bun pinned via `mise.toml`).
- Swift 6.3.x via `swiftly` (`swift --version` → 6.3.1). Not installed by mise.
- `gh` authenticated (`gh auth status`) with push + release rights on the org.
- An npm **publish** token for the `@swifttui` scope. Never write it into a
  tracked file. Use an isolated userconfig (see step 1g) and delete it after.
- Push access to all five repos over SSH.

## 0. Bump the authored version strings

From the org root:

```sh
mise run bump -- 0.0.11            # preview (dry run)
mise run bump -- 0.0.11 --write    # apply
```

Then review `git -C <submodule> diff` in each child. The bump edits land inside
the submodule working trees plus the root `MODULE.bazel`/`README.md`.

## 1. swift-tui-web (leaf artifact)

```sh
cd swift-tui-web
```

a. **Sync the lockfile's workspace versions.** `bun install` will NOT rewrite
   these on its own when the dependency graph is otherwise unchanged. Edit
   `bun.lock` by hand so both workspace entries read the new version:

   ```jsonc
   "packages/build": { "name": "@swifttui/build", "version": "0.0.11", ... }
   "packages/web":   { "name": "@swifttui/web",   "version": "0.0.11", ... }
   ```

   > **Why this matters:** `bun pm pack` / `bun publish` resolve `workspace:*`
   > against `bun.lock`, not `package.json`. If the lock lags, you publish
   > `@swifttui/build@0.0.11` depending on `@swifttui/web@<old>` — exactly the
   > silent breakage that the `0.0.8` "sync bun.lock workspace versions" fixup
   > commit had to repair after the fact.

b. **Validate** with the exact repo gate:

   ```sh
   bun run ci            # install --frozen-lockfile && test && build:web
   ```

c. **Build the tarballs** into a scratch dir (keep them out of the repo):

   ```sh
   mkdir -p /tmp/swifttui-release/assets
   (cd packages/web   && bun pm pack --destination /tmp/swifttui-release/assets)
   (cd packages/build && bun pm pack --destination /tmp/swifttui-release/assets)
   ```

   Produces `swifttui-web-0.0.11.tgz` and `swifttui-build-0.0.11.tgz` — the exact
   filenames the release URLs reference. Verify the build tarball resolved its
   sibling correctly:

   ```sh
   tar xzO -f /tmp/swifttui-release/assets/swifttui-build-0.0.11.tgz package/package.json | grep swifttui/web
   # → "@swifttui/web": "0.0.11"
   ```

d. **Commit + tag + push** (release commits land directly on `main`; the org
   pins against the trunk):

   ```sh
   git add -A && git commit -m "0.0.11"
   git tag 0.0.11
   git push origin main && git push origin 0.0.11
   ```

e. **Create the GitHub release with both assets** — the step that was missing
   for 0.0.8:

   ```sh
   gh release create 0.0.11 --target main --title 0.0.11 --notes "..." \
     /tmp/swifttui-release/assets/swifttui-web-0.0.11.tgz \
     /tmp/swifttui-release/assets/swifttui-build-0.0.11.tgz
   ```

f. **Verify the tarball URLs resolve** (this is the 0.0.8 failure mode):

   ```sh
   for f in swifttui-web-0.0.11 swifttui-build-0.0.11; do
     curl -sS -o /dev/null -w "$f -> %{http_code}\n" -L \
       "https://github.com/SwiftTUI/swift-tui-web/releases/download/0.0.11/$f.tgz"
   done   # both must be 200
   ```

g. **Publish to npm** using the packed tarballs (so npm and the GitHub release
   are byte-identical), via an isolated userconfig that never touches the repo:

   ```sh
   NPMRC=/tmp/swifttui-release/.npmrc
   printf '//registry.npmjs.org/:_authToken=%s\n' "$NPM_TOKEN" > "$NPMRC"; chmod 600 "$NPMRC"
   npm whoami --userconfig "$NPMRC"        # sanity
   npm publish /tmp/swifttui-release/assets/swifttui-web-0.0.11.tgz   --userconfig "$NPMRC" --access public
   npm publish /tmp/swifttui-release/assets/swifttui-build-0.0.11.tgz --userconfig "$NPMRC" --access public
   rm -f "$NPMRC"                           # shred the token file immediately
   ```

## 2. swift-tui (framework)

Pure metadata bump (no `Sources/` changes). SwiftPM consumers resolve the git
tag, so no lockfile or release assets are needed.

```sh
cd ../swift-tui
git add -A && git commit -m "0.0.11"
git tag 0.0.11
git push origin main && git push origin 0.0.11
```

## 3. swift-tui-examples

Needs **both** lockfiles regenerated now that web's release and swift-tui's tag
exist.

a. **Bun** (web tarballs — required; the gate runs `bun install --frozen-lockfile`):

   ```sh
   cd ../swift-tui-examples
   bun install                      # fetches the 0.0.11 web tarballs, rewrites bun.lock
   bun install --frozen-lockfile    # must pass
   ```

b. **SwiftPM** — regenerate every `Package.resolved` so the pinned revision
   matches the new `swift-tui` tag. The example `Package.swift` files use
   `exact: "0.0.11"`; `swift package resolve` (resolution only, no full compile)
   updates each lock:

   ```sh
   for d in argparse file-previewer gallery gifcat gifeditor gitviz layouts \
            LayoutsSwiftUI minimal SharedHostScenes SwiftUIExample/TerminalApp \
            terminal-runner terminal-workspace three-hosts-demo \
            WebExample/TerminalApp WebHostExample; do
     swift package resolve --package-path "$d"
   done
   ```

   The diffs should touch only `originHash` and the `swift-tui` pin. Also update
   the Xcode-managed lock by hand (it is not driven by `swift package resolve`):
   `SwiftUIExample/SwiftUIExample.xcodeproj/.../swiftpm/Package.resolved` →
   bump the `swift-tui` `revision` (= `git -C ../swift-tui rev-list -n1 0.0.11`)
   and `version`.

   > The repo gate (`Scripts/check_examples.sh`) builds with plain `swift build`,
   > which auto-resolves — so a stale `Package.resolved` won't hard-fail CI, but
   > committing it stale leaves a dirty tree and lies about the pin. Regenerate it.

c. Commit + tag + push:

   ```sh
   git add -A && git commit -m "0.0.11"
   git tag 0.0.11
   git push origin main && git push origin 0.0.11
   ```

## 4. swift-tui-site

The site fetches `swift-tui-examples` at `current.examplesRef` from
`docs/releases.yml` (the bump sets it to `0.0.11`), then builds the WASI example.

```sh
cd ../swift-tui-site
(cd Website && bun install && bun install --frozen-lockfile)
```

**Validate the cross-repo chain cheaply** — `prepare:webexample` is the exact
step that 404'd for 0.0.8, and it doesn't need the heavy wasm compile:

```sh
(cd Website && bun run prepare:webexample)
# → "[prepare-webexample] prepared swift-tui-examples 0.0.11"  with no 404
```

Then commit + tag + push:

```sh
git add -A && git commit -m "0.0.11"
git tag 0.0.11
git push origin main && git push origin 0.0.11
```

## 5. swift-tui-org (root) — record the pins

The submodule working trees now point at the new tagged commits. Record them:

```sh
cd ..
git add MODULE.bazel README.md tools/coordination/bump_version.sh \
        swift-tui swift-tui-web swift-tui-examples swift-tui-site
git commit -m "0.0.11"
git tag 0.0.11
git push origin main && git push origin 0.0.11

bazel fetch //:org_full
bazel test  //:release_candidate     # full org gate (needs native toolchains)
```

## Verification checklist

- [ ] `swift-tui-web` has a `0.0.11` **git tag** and a **GitHub release** whose
      two `.tgz` assets return **HTTP 200**.
- [ ] `npm view @swifttui/web version` and `@swifttui/build` both show `0.0.11`.
- [ ] `swift-tui`, `swift-tui-examples`, `swift-tui-site` each have a `0.0.11` tag.
- [ ] `bun install --frozen-lockfile` passes in `swift-tui-web`,
      `swift-tui-examples`, and `swift-tui-site/Website`.
- [ ] `swift-tui-site` `bun run prepare:webexample` prints
      `prepared swift-tui-examples 0.0.11` with no 404.
- [ ] Root submodule pins recorded; `git submodule status` shows the new SHAs.

## Gotchas & notes

- **Tags are lightweight** here (`git tag 0.0.11`). SwiftPM and the GitHub release
  resolve them fine; `git describe`/`git submodule status` will still report the
  nearest *annotated* tag (e.g. `0.0.7-7-g…`) — cosmetic, not a problem.
- **`bun.lock` workspace version drift** (step 1a) is the most common silent
  failure. Always check it before packing.
- **The GitHub release is mandatory** (step 1e/1f). Skipping it is precisely what
  broke 0.0.8.
- **Root CI:** the org root currently has **no tracked `.github/workflows`** —
  the historical "Org Gate" is absent, so pushes to root do not trigger remote
  org validation. Run `bazel test //:release_candidate` locally instead, and
  consider restoring the gate workflow.
- **Token hygiene:** the npm token is a publish credential. Use it only through a
  throwaway userconfig under `/tmp`, delete it immediately, and rotate it if it
  was ever shared in plaintext (e.g. pasted into a chat).
