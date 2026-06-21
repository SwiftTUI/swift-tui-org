# Releasing the SwiftTUI org

How to cut a new lockstep release (`swift-tui`, `swift-tui-swiftui`,
`swift-tui-web`, `swift-tui-android`, `swift-tui-examples`, `swift-tui-site` all
move to the same version together).
This is the runbook the `bump_version.sh` tool deliberately stops short of —
everything here is **irreversible / outward-facing** (tags, GitHub releases, npm
publishes) and is the maintainer's to drive.

> Worked example: this doc was written while cutting `0.0.13`. Substitute your
> target version for `0.0.13` throughout.

## Mental model — read this first

Two facts drive the entire procedure:

1. **The version string is denormalized across child repos.** `package.json`
   versions, SwiftPM `exact:`/`upToNextMinor(from:)` pins (including
   **swift-tui-swiftui**'s `exact:` on swift-tui in `swift-tui-swiftui/Package.swift`
   plus its `MODULE.bazel` `version`), the Xcode `exactVersion` (which pins
   **both** swift-tui and swift-tui-swiftui), Android Gradle plugin/AAR coordinates,
   GitHub release tarball URLs, `tree`/`blob`/`tag` links, site display strings, and
   the canonical `swift-tui-site/docs/releases.yml` manifest all hardcode it.
   `tools/coordination/bump_version.sh --write` rewrites the *authored*
   occurrences. It never touches generated lockfiles, tags, or publishes.

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
swift-tui-web  →  swift-tui  →  swift-tui-swiftui  →  swift-tui-android  →  swift-tui-examples  →  swift-tui-site  →  swift-tui-org
   (web tgz)       (Swift tag)     (SwiftUI host tag)    (Gradle artifacts)       (consumes all four)        (site)          (pins)
```

## Prerequisites

- `mise trust && mise install` (Bazelisk + Bun pinned via `mise.toml`).
- Swift 6.3.x via `swiftly` (`swift --version` → 6.3.1). Not installed by mise.
- `gh` authenticated (`gh auth status`) with push + release rights on the org.
- An npm **publish** token for the `@swifttui` scope. Never write it into a
  tracked file. Use an isolated userconfig (see step 1g) and delete it after.
- Push access to all **six** publishable repos over SSH (`swift-tui-web`,
  `swift-tui`, `swift-tui-swiftui`, `swift-tui-android`, `swift-tui-examples`,
  `swift-tui-site`).
- A **JDK** and the **Android SDK** for step 4's `./gradlew` publish. The SDK
  dir is read from `ANDROID_HOME`/`ANDROID_SDK_ROOT` (falling back to
  `~/Library/Android/sdk`). The release publish runs the JVM-only
  `testDebugUnitTest` and does **not** need the NDK — the native JNI build is
  gated on NDK presence (`ndkVersion 27.3.13750724`), so a maintainer without it
  can still publish.
- **Every child repo's own CI is green on `main` at the commit you are about
  to tag.** For `swift-tui` that means the Repo Gate workflow (or a local
  `bun run test`), *plus* a wasm cross-build check
  (`swiftly run swift build --swift-sdk swift-6.3.1-RELEASE_wasm --target
  SwiftTUIRuntime`) — the site gate compiles swift-tui for wasm32-wasi, so a
  WASI-only compile break in swift-tui surfaces as a *site* CI failure after
  everything is already tagged. Tagging on top of a red gate forces a
  tag-move cascade (swift-tui → examples lock re-pins → root pins), and
  moved tags additionally trip SwiftPM's fingerprint tamper check
  (`~/.swiftpm/security/fingerprints`) on any machine that resolved the old
  tag. Check first; it was learned the hard way cutting `0.0.19`.

## 0. Bump the authored version strings

From the org root:

```sh
mise run bump -- 0.0.13            # preview (dry run)
mise run bump -- 0.0.13 --write    # apply
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
   "packages/build": { "name": "@swifttui/build", "version": "0.0.13", ... }
   "packages/web":   { "name": "@swifttui/web",   "version": "0.0.13", ... }
   ```

   > **Why this matters:** `bun pm pack` / `bun publish` resolve `workspace:*`
   > against `bun.lock`, not `package.json`. If the lock lags, you publish
   > `@swifttui/build@0.0.13` depending on `@swifttui/web@<old>` — exactly the
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

   Produces `swifttui-web-0.0.13.tgz` and `swifttui-build-0.0.13.tgz` — the exact
   filenames the release URLs reference. Verify the build tarball resolved its
   sibling correctly:

   ```sh
   tar xzO -f /tmp/swifttui-release/assets/swifttui-build-0.0.13.tgz package/package.json | grep swifttui/web
   # → "@swifttui/web": "0.0.13"
   ```

d. **Commit + tag + push** (release commits land directly on `main`; the org
   pins against the trunk):

   ```sh
   git add -A && git commit -m "0.0.13"
   git tag 0.0.13
   git push origin main && git push origin 0.0.13
   ```

e. **Create the GitHub release with both assets** — the step that was missing
   for 0.0.8:

   ```sh
   gh release create 0.0.13 --target main --title 0.0.13 --notes "..." \
     /tmp/swifttui-release/assets/swifttui-web-0.0.13.tgz \
     /tmp/swifttui-release/assets/swifttui-build-0.0.13.tgz
   ```

f. **Verify the tarball URLs resolve** (this is the 0.0.8 failure mode):

   ```sh
   for f in swifttui-web-0.0.13 swifttui-build-0.0.13; do
     curl -sS -o /dev/null -w "$f -> %{http_code}\n" -L \
       "https://github.com/SwiftTUI/swift-tui-web/releases/download/0.0.13/$f.tgz"
   done   # both must be 200
   ```

g. **Publish to npm** using the packed tarballs (so npm and the GitHub release
   are byte-identical), via an isolated userconfig that never touches the repo:

   ```sh
   NPMRC=/tmp/swifttui-release/.npmrc
   printf '//registry.npmjs.org/:_authToken=%s\n' "$NPM_TOKEN" > "$NPMRC"; chmod 600 "$NPMRC"
   npm whoami --userconfig "$NPMRC"        # sanity
   npm publish /tmp/swifttui-release/assets/swifttui-web-0.0.13.tgz   --userconfig "$NPMRC" --access public
   npm publish /tmp/swifttui-release/assets/swifttui-build-0.0.13.tgz --userconfig "$NPMRC" --access public
   rm -f "$NPMRC"                           # shred the token file immediately
   ```

## 2. swift-tui (framework)

Pure metadata bump (no `Sources/` changes). SwiftPM consumers resolve the git
tag, so no lockfile or release assets are needed.

```sh
cd ../swift-tui
git add -A && git commit -m "0.0.13"
git tag 0.0.13
git push origin main && git push origin 0.0.13
```

## 3. swift-tui-swiftui (SwiftUI host)

The Apple-platform SwiftUI host. Pure metadata bump (no `Sources/` changes): it
pins `swift-tui` via `exact:` and is itself consumed by the `LayoutsSwiftUI` and
`three-hosts-demo` examples (and the `SwiftUIExample` Xcode lock) via `exact:`, so
it must be tagged **after** `swift-tui` and **before** `swift-tui-examples`.
`Package.resolved` is gitignored here (libraries don't commit it), so the release
commit is metadata only (`MODULE.bazel` + `Package.swift` + `README.md`); `mise
run bump` already rewrote the authored `exact:` string.

```sh
cd ../swift-tui-swiftui
swift package resolve            # refresh the (gitignored) lock against the new swift-tui tag
git add -A && git commit -m "0.0.13"
git tag 0.0.13
git push origin main && git push origin 0.0.13
```

## 4. swift-tui-android

The Android repo publishes **two** modules into the GitHub Pages Maven repo
(`build/github-pages-repo`, served at `https://swifttui.github.io/swift-tui-android`):
the AAR `sh.swifttui:android-host` (from `:swift-tui-host`) and the Gradle plugin
marker `sh.swifttui.android` (from `:android-plugin`).
`publishAllPublicationsToGithubPagesRepository` emits both at once — one
`gradlew` invocation, not one per module.

```sh
cd ../swift-tui-android
./gradlew :swift-tui-host:testDebugUnitTest publishAllPublicationsToGithubPagesRepository
git add -A && git commit -m "0.0.13"
git tag 0.0.13
git push origin main && git push origin 0.0.13
```

Publish the generated `build/github-pages-repo` to the `gh-pages` branch
**before** updating examples (`AndroidGallery` resolves `sh.swifttui.android` and
`sh.swifttui:android-host` from this static Maven repo). The Gradle task above
writes the repo into `build/github-pages-repo`; serve it via a gh-pages worktree
so the publish is a plain commit:

```sh
WT=/tmp/swifttui-ghpages
git fetch origin gh-pages
git worktree add -B gh-pages "$WT" origin/gh-pages
rsync -a build/github-pages-repo/ "$WT"/
git -C "$WT" add -A
git -C "$WT" commit -m "Publish 0.0.13 Android artifacts"
git -C "$WT" push origin gh-pages
git worktree remove "$WT"
```

> **Do not `rm -rf build/` first.** The merged `maven-metadata.xml` is correct
> only because the local `build/github-pages-repo` retains every prior version,
> so Gradle regenerates a `<versions>` list spanning all releases. A clean build
> dir would publish a metadata file that lists only the new version and drops the
> older ones.

Then confirm the artifacts are actually served over GitHub Pages (the Android
analogue of step 1f — a not-yet-pushed gh-pages or a stale Pages build 404s here,
and examples won't surface it until the examples step):

```sh
for u in \
  "sh/swifttui/android-host/0.0.13/android-host-0.0.13.aar" \
  "sh/swifttui/android-host/maven-metadata.xml"; do
  curl -sS -o /dev/null -w "$u -> %{http_code}\n" -L \
    "https://swifttui.github.io/swift-tui-android/$u"
done   # both must be 200 (gh-pages can lag a minute after push)
```

## 5. swift-tui-examples

Needs **both** lockfiles regenerated now that web's release, swift-tui's tag,
and the Android Maven artifacts exist. Two examples (`LayoutsSwiftUI`,
`three-hosts-demo`) and the `SwiftUIExample` Xcode lock additionally pin
`swift-tui-swiftui` exact:0.0.13, so the swift-tui-swiftui tag must already be
pushed before this step (it is released after swift-tui, before examples).

a. **Bun** (web tarballs — required; the gate runs `bun install --frozen-lockfile`):

   ```sh
   cd ../swift-tui-examples
   bun install                      # fetches the 0.0.13 web tarballs, rewrites bun.lock
   bun install --frozen-lockfile    # must pass
   ```

b. **SwiftPM** — regenerate every `Package.resolved` so the pinned revision
   matches the new `swift-tui` tag. The example `Package.swift` files use
   `exact: "0.0.13"`; `swift package resolve` (resolution only, no full compile)
   updates each lock:

   ```sh
   # Resolve EVERY example package (dynamic — a hardcoded list rots; it
   # previously missed equatable-demo and AndroidGallery/SwiftPackage):
   find . -name Package.swift -not -path '*/.build/*' -not -path '*/Tests/*' \
     -print0 | while IFS= read -r -d '' m; do
       swift package resolve --package-path "$(dirname "$m")"
   done
   # As of 0.0.13 this resolves 18 packages.
   ```

   The diffs should touch only `originHash` and the SwiftTUI pins. Also update
   the Xcode-managed lock by hand (it is not driven by `swift package resolve`):
   `SwiftUIExample/SwiftUIExample.xcodeproj/.../swiftpm/Package.resolved` pins
   **both** SwiftTUI packages — bump `swift-tui` *and* `swift-tui-swiftui`,
   setting each one's `revision` and `version`:

   ```sh
   git -C ../swift-tui          rev-list -n1 0.0.13   # → swift-tui revision
   git -C ../swift-tui-swiftui  rev-list -n1 0.0.13   # → swift-tui-swiftui revision
   ```

   Set both `version` strings to `0.0.13`. (swift-tui-swiftui must already be
   tagged — see step 3 — because `LayoutsSwiftUI`/`three-hosts-demo` also pin
   it exact:0.0.13 and their resolve above fetches that tag.)

   > The repo gate (`Scripts/check_examples.sh`) builds with plain `swift build`,
   > which auto-resolves — so a stale `Package.resolved` won't hard-fail CI, but
   > committing it stale leaves a dirty tree and lies about the pin. Regenerate it.

c. Commit + tag + push:

   ```sh
   git add -A && git commit -m "0.0.13"
   git tag 0.0.13
   git push origin main && git push origin 0.0.13
   ```

## 6. swift-tui-site

The site fetches `swift-tui-examples` at `current.examplesRef` from
`docs/releases.yml` (the bump sets it to `0.0.13`), then builds the WASI example.

```sh
cd ../swift-tui-site
(cd Website && bun install && bun install --frozen-lockfile)
```

**Validate the cross-repo chain cheaply** — `prepare:webexample` is the exact
step that 404'd for 0.0.8, and it doesn't need the heavy wasm compile:

```sh
(cd Website && bun run prepare:webexample)
# → "[prepare-webexample] prepared swift-tui-examples 0.0.13"  with no 404
```

Then commit + tag + push:

```sh
git add -A && git commit -m "0.0.13"
git tag 0.0.13
git push origin main && git push origin 0.0.13
```

## 7. swift-tui-org (root) — record the pins

The submodule working trees now point at the new tagged commits. Record them:

```sh
cd ..
git add MODULE.bazel README.md tools/coordination/bump_version.sh \
        swift-tui swift-tui-swiftui swift-tui-web swift-tui-android \
        swift-tui-examples swift-tui-site
git commit -m "0.0.13"
git tag 0.0.13
git push origin main && git push origin 0.0.13

bazel fetch //:org_full
bazel test  //:release_candidate     # full org gate (needs native toolchains)
```

> The six lockstep submodules are `swift-tui`, `swift-tui-swiftui`,
> `swift-tui-web`, `swift-tui-android`, `swift-tui-examples`, `swift-tui-site`.
> Cross-check the `git add` list against `git submodule status` before
> committing — it is hand-maintained and rots when a submodule joins the
> lockstep. **Exclude `github/`** (the `.github` org-profile submodule): it is
> docs-only/pinning-only and never carries a release tag.

## Verification checklist

- [ ] `swift-tui-web` has a `0.0.13` **git tag** and a **GitHub release** whose
      two `.tgz` assets return **HTTP 200**.
- [ ] `npm view @swifttui/web version` and `@swifttui/build` both show `0.0.13`.
- [ ] `swift-tui`, `swift-tui-swiftui`, `swift-tui-android`,
      `swift-tui-examples`, `swift-tui-site` each have a `0.0.13` tag.
- [ ] `swift-tui-android` published `sh.swifttui.android` and
      `sh.swifttui:android-host` to the GitHub Pages Maven repository.
- [ ] The published Android AAR is reachable:
      `curl -sS -o /dev/null -w "%{http_code}\n" -L https://swifttui.github.io/swift-tui-android/sh/swifttui/android-host/0.0.13/android-host-0.0.13.aar`
      returns **200** (gh-pages can lag a minute after push).
- [ ] The Xcode-managed `SwiftUIExample/.../swiftpm/Package.resolved` has its
      `swift-tui` **and** `swift-tui-swiftui` `revision`+`version` both bumped to
      `0.0.13` (= `git -C <repo> rev-list -n1 0.0.13`); it pins both and is not
      driven by `swift package resolve`.
- [ ] `bun install --frozen-lockfile` passes in `swift-tui-web`,
      `swift-tui-examples`, and `swift-tui-site/Website`.
- [ ] `swift-tui-site` `bun run prepare:webexample` prints
      `prepared swift-tui-examples 0.0.13` with no 404.
- [ ] Root submodule pins recorded — including **swift-tui-swiftui**;
      `git submodule status` shows the new SHAs for all six child repos
      (`swift-tui`, `swift-tui-swiftui`, `swift-tui-web`, `swift-tui-android`,
      `swift-tui-examples`, `swift-tui-site`).

## Gotchas & notes

- **Tags are lightweight** here (`git tag 0.0.13`). SwiftPM and the GitHub release
  resolve them fine; `git describe`/`git submodule status` will still report the
  nearest *annotated* tag (e.g. `0.0.7-7-g…`) — cosmetic, not a problem.
- **`bun.lock` workspace version drift** (step 1a) is the most common silent
  failure. Always check it before packing.
- **The GitHub release is mandatory** (step 1e/1f). Skipping it is precisely what
  broke 0.0.8.
- **The live site does not auto-deploy on push.** `swift-tui-site`'s Cloudflare
  Pages deploy workflow (`.github/workflows/cloudflare-pages.yml`) is
  `workflow_dispatch:`-only — pushing the `swift-tui-site` release commit/tag
  runs only the test gate, not the deploy. To publish the updated site, manually
  dispatch the **Deploy Website to Cloudflare Pages** workflow on `main`
  (`gh workflow run cloudflare-pages.yml --ref main`) after the site step.
- **`MODULE.bazel.lock` is tracked, not ignored.** It can regenerate (e.g.
  after `bazel fetch //:org_full`) and surface as a modified/untracked change at
  root or in a child. The curated step-7 `git add` list omits it; a blanket
  `git add -A` will sweep it into the release commit. Either is fine — just
  commit it deliberately rather than leaving the tree dirty.
- **ssh-agent signing warnings on push are cosmetic.** When git signs with an
  ED25519 ssh key, `git push` may print `error: communication with agent
  failed` (or similar signing warnings) yet still land the push. Confirm with
  `git ls-remote origin <ref>` rather than re-pushing on the warning alone.
- **Root CI:** the org root currently has **no tracked `.github/workflows`** —
  the historical "Org Gate" is absent, so pushes to root do not trigger remote
  org validation. Run `bazel test //:release_candidate` locally instead, and
  consider restoring the gate workflow.
- **Token hygiene:** the npm token is a publish credential. Use it only through a
  throwaway userconfig under `/tmp`, delete it immediately, and rotate it if it
  was ever shared in plaintext (e.g. pasted into a chat).
