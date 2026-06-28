#!/usr/bin/env bash
set -euo pipefail

# bump_version.sh — org-wide version bump helper for the SwiftTUI coordination
# repo.
#
# This is a COORDINATION tool. It rewrites the denormalized version string that
# every child repo hardcodes (package.json versions, SwiftPM `exact:`/`from:`
# pins, GitHub release tarball URLs, tree/blob/tag links, site display strings,
# and the canonical docs/releases.yml manifest) so a maintainer does not have to
# hand-edit dozens of files across four repos.
#
# It deliberately STOPS short of anything irreversible or repo-owning:
#   * it never commits, tags, pushes, or publishes;
#   * it never touches generated lockfiles (Package.resolved, bun.lock) because
#     those encode the new tag's git SHA / integrity hashes, which do not exist
#     until AFTER you tag and publish — those are regenerated, not string-edited;
#   * edits land INSIDE each submodule working tree, matching the repo rule that
#     child code is changed in the child, then the root records the new pin.
#
# Default mode is a dry run: it prints a unified diff of every change and a
# regeneration / release runbook, and mutates nothing. Pass --write to apply.

script_source="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  script_path="$(realpath "$script_source")"
else
  script_path="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$script_source")"
fi
script_dir="$(cd "$(dirname "$script_path")" && pwd)"

# Resolution order mirrors the other coordination scripts: $BUILD_WORKSPACE_DIRECTORY
# (set by `bazel run`), then `git rev-parse`, then a structural fallback.
if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  repo_root="$BUILD_WORKSPACE_DIRECTORY"
else
  repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    repo_root="$(cd "$script_dir/../.." && pwd)"
  fi
fi

cd "$repo_root"

# Submodules whose working trees carry version strings, in release dependency
# order (web is the leaf others consume via release artifacts; examples consume
# the Android artifact, and site consumes the examples). The root "." is scanned
# too for its README coordination prose.
child_repos=(
  "swift-tui-web"
  "swift-tui"
  "swift-tui-swiftui"
  "swift-tui-android"
  "swift-tui-examples"
  "swift-tui-site"
)
scan_repos=("." "${child_repos[@]}")

releases_manifest="swift-tui-site/docs/releases.yml"

old_version=""
new_version=""
mode="dry-run" # dry-run | write

fail() {
  printf '[bump_version] %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: tools/coordination/bump_version.sh [options] <new-version>

Preview (default) or apply an org-wide version bump across every SwiftTUI child
repo's authored version sites. Lockstep: swiftTUI, web, and examplesRef all move
to <new-version> together (the model the org ships under today).

Arguments:
  <new-version>   Target semver, e.g. 0.0.13 (also accepts pre-release suffixes,
                  e.g. 0.1.0-rc.1).

Options:
  --from VERSION  Override the detected current version. By default the current
                  version is read from swift-tui-site/docs/releases.yml
                  (current.swiftTUI).
  --write         Apply the edits in place. Without this flag the tool only
                  prints a unified diff and a runbook and mutates nothing.
  -h, --help      Show this help.

What it rewrites (authored files):
  * package.json "version" fields (framework, web packages, site, examples)
  * SwiftPM pins:  exact: "X", .upToNextMinor(from: "X")
  * Xcode pins:    kind = exactVersion; version = X;
  * release tarball URLs:  .../releases/download/X/...-X.tgz
  * GitHub source links:   tree/X, blob/X, /tag/X, vX, "X pre-release"
  * the canonical manifest: docs/releases.yml + docs/docc-repos.yml

What it never touches (you regenerate / publish these yourself):
  * Package.resolved, bun.lock, package-lock.json  -> regenerated after tagging
  * git tags, commits, pushes, npm/GitHub releases  -> done by the maintainer
  * dated history under docs/plans, docs/reports, docs/proposals, VISION*.md,
    docs/PUBLIC-REPO-READINESS.md  -> reported as skipped, never rewritten

Examples:
  mise run bump -- 0.0.13                 # preview the full diff
  mise run bump -- 0.0.13 --write         # apply, then review `git diff` per repo
  bazel run //:bump_version -- 0.0.13     # same, via Bazel
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --from)
      [[ "$#" -ge 2 ]] || fail "--from requires a version"
      old_version=$2
      shift 2
      ;;
    --write)
      mode="write"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1 (try --help)"
      ;;
    *)
      [[ -z "$new_version" ]] || fail "unexpected extra argument: $1"
      new_version=$1
      shift
      ;;
  esac
done

[[ -n "$new_version" ]] || { usage >&2; fail "missing <new-version>"; }

semver_re='^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$'
[[ "$new_version" =~ $semver_re ]] || fail "new version '$new_version' is not a valid semver"

# Discover the current version from the canonical manifest unless overridden.
if [[ -z "$old_version" ]]; then
  [[ -f "$releases_manifest" ]] || fail "cannot find $releases_manifest; pass --from <current-version>"
  old_version="$(awk -F': *' '/^[[:space:]]*swiftTUI:[[:space:]]*/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$releases_manifest")"
  [[ -n "$old_version" ]] || fail "could not read current.swiftTUI from $releases_manifest; pass --from <current-version>"
fi

[[ "$new_version" != "$old_version" ]] || fail "new version equals current version ($old_version); nothing to do"

lowest="$(printf '%s\n%s\n' "$old_version" "$new_version" | sort -V | head -n 1)"
if [[ "$lowest" == "$new_version" ]]; then
  printf '[bump_version] WARNING: %s is not greater than current %s (downgrade?).\n' "$new_version" "$old_version" >&2
fi

# Classification helpers -----------------------------------------------------

# Generated lockfiles: encode resolved SHAs / integrity hashes, and routinely
# contain unrelated third-party versions that coincidentally match (e.g.
# MODULE.bazel.lock pins platforms/0.0.7 and rules_license/0.0.7). They must be
# regenerated by their own toolchain, never string-edited.
is_generated() {
  case "$(basename "$1")" in
    Package.resolved|bun.lock|package-lock.json|MODULE.bazel.lock) return 0 ;;
    *) return 1 ;;
  esac
}

# Dated records and narrative history: reference the version as a fact about the
# past. Surfaced as skipped so a human decides, never rewritten automatically.
is_history() {
  case "$1" in
    docs/README.md) return 0 ;;
    RELEASE.md) return 0 ;;
    docs/plans/*|docs/reports/*|docs/proposals/*) return 0 ;;
    docs/PUBLIC-REPO-READINESS.md) return 0 ;;
    */docs/README.md) return 0 ;;
    */RELEASE.md) return 0 ;;
    */docs/PUBLIC-REPO-READINESS.md) return 0 ;;
    */docs/plans/*|*/docs/reports/*|*/docs/proposals/*) return 0 ;;
    */docs/VISION*.md|*/CHANGELOG.md|CHANGELOG.md) return 0 ;;
    *) return 1 ;;
  esac
}

# Boundary-aware token rewrite: replaces the whole version token only.
#   (?<![0-9.])   not preceded by a digit/dot  -> skips 10.0.7, 1.0.0.7
#   (?![0-9])     not followed by a digit       -> skips 0.0.70
#   (?!\.[0-9])   not followed by .<digit>      -> skips a 4th version segment
# but still matches v0.0.7 (letter prefix) and swifttui-web-0.0.7.tgz (dot/ext
# suffix). Old/new pass via env to dodge shell quoting; \Q..\E literal-quotes
# the version inside the regex.
version_re_pre='(?<![0-9.])'
version_re_post='(?![0-9])(?!\.[0-9])'
transform_to_stdout() {
  OLD="$old_version" NEW="$new_version" PRE="$version_re_pre" POST="$version_re_post" \
    perl -pe 's/$ENV{PRE}\Q$ENV{OLD}\E$ENV{POST}/$ENV{NEW}/g' "$1"
}

rewrite_files=()
generated_files=()
history_files=()
resolve_dirs=()
bunlock_dirs=()
bazel_lock_seen=0

# Gather candidates: tracked files in each repo that contain the old version.
for r in "${scan_repos[@]}"; do
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ "$r" == "." ]]; then rel="$f"; else rel="$r/$f"; fi

    if is_generated "$rel"; then
      generated_files+=("$rel")
      case "$(basename "$rel")" in
        Package.resolved) resolve_dirs+=("$(dirname "$rel")") ;;
        bun.lock) bunlock_dirs+=("$(dirname "$rel")") ;;
        MODULE.bazel.lock) bazel_lock_seen=1 ;;
      esac
      continue
    fi

    if is_history "$rel"; then
      history_files+=("$rel")
      continue
    fi

    # Only treat as a rewrite target if a boundary-aware match actually changes
    # the file (filters partial matches like a coincidental 0.0.70).
    if ! diff -q "$rel" <(transform_to_stdout "$rel") >/dev/null 2>&1; then
      rewrite_files+=("$rel")
    fi
  done < <(git -C "$r" grep -lI -F -e "$old_version" -- . 2>/dev/null || true)
done

# De-duplicate the directory lists.
mapfile -t resolve_dirs < <(printf '%s\n' "${resolve_dirs[@]:-}" | sort -u | sed '/^$/d')
mapfile -t bunlock_dirs < <(printf '%s\n' "${bunlock_dirs[@]:-}" | sort -u | sed '/^$/d')

printf '[bump_version] %s -> %s  (mode: %s)\n\n' "$old_version" "$new_version" "$mode"

if [[ "${#rewrite_files[@]}" -eq 0 ]]; then
  fail "found no authored files containing $old_version; is --from correct?"
fi

# Apply or preview ------------------------------------------------------------

total_hunks=0
for rel in $(printf '%s\n' "${rewrite_files[@]}" | sort); do
  count="$(grep -o -F "$old_version" "$rel" | wc -l | tr -d ' ')"
  total_hunks=$((total_hunks + count))
  if [[ "$mode" == "write" ]]; then
    OLD="$old_version" NEW="$new_version" PRE="$version_re_pre" POST="$version_re_post" \
      perl -i -pe 's/$ENV{PRE}\Q$ENV{OLD}\E$ENV{POST}/$ENV{NEW}/g' "$rel"
    printf '  updated %s (%s occurrence(s))\n' "$rel" "$count"
  else
    printf '%s\n' "===== $rel ($count occurrence(s)) ====="
    diff -u --label "a/$rel" --label "b/$rel" "$rel" <(transform_to_stdout "$rel") || true
    printf '\n'
  fi
done

# Summary ---------------------------------------------------------------------

printf '\n[bump_version] summary\n'
printf '  rewrite targets : %s file(s), %s occurrence(s)\n' "${#rewrite_files[@]}" "$total_hunks"
printf '  generated (skip): %s file(s) — regenerate after tagging\n' "${#generated_files[@]}"
printf '  history  (skip) : %s file(s) — left as historical record\n' "${#history_files[@]}"

if [[ "${#history_files[@]}" -gt 0 ]]; then
  printf '\n[bump_version] history/narrative files left untouched (review by hand if intended):\n'
  printf '%s\n' "${history_files[@]}" | sort | sed 's/^/  /'
fi

# Regeneration runbook --------------------------------------------------------

printf '\n[bump_version] generated lockfiles to regenerate AFTER the new tags are published:\n'
if [[ "${#resolve_dirs[@]}" -gt 0 ]]; then
  printf '  SwiftPM (run once swift-tui %s is tagged & pushed):\n' "$new_version"
  for d in "${resolve_dirs[@]}"; do
    printf '    (cd %s && swift package resolve)\n' "$d"
  done
fi
if [[ "${#bunlock_dirs[@]}" -gt 0 ]]; then
  printf '  Bun (run after bumping the package.json versions / tarball URLs):\n'
  for d in "${bunlock_dirs[@]}"; do
    printf '    (cd %s && bun install)\n' "$d"
  done
fi
if [[ "$bazel_lock_seen" -eq 1 ]]; then
  printf '  Bazel module lock (MODULE.bazel.lock — left untouched; it pins\n'
  printf '    unrelated registry modules at coincidental versions):\n'
  printf '    bazel mod deps --lockfile_mode=update   # or: bazel fetch //:org_full\n'
fi

# Release runbook -------------------------------------------------------------

cat <<EOF

[bump_version] release runbook (the tool does NOT do these — they are yours):
  Dependency order matters: web is the artifact leaf; examples consume SwiftTUI,
  web, and Android artifacts; site consumes examples.

  1. swift-tui-web : commit the bump, run \`bun install\`, tag $new_version,
                     push; the tag-triggered Publish workflow creates the
                     GitHub release tarballs and publishes npm packages.
  2. swift-tui     : commit the bump, tag $new_version, push.
  3. swift-tui-android : commit the bump, tag $new_version, publish the Gradle
                     plugin/AAR artifacts, push.
  4. swift-tui-examples : after swift-tui $new_version is tagged, regenerate the
                     Package.resolved files (above) + \`bun install\`, commit,
                     tag $new_version, push.
  5. swift-tui-site: \`bun install\` under Website/, commit, tag $new_version, push.
  6. THIS repo     : record the new submodule pins, then validate:
                       git add swift-tui swift-tui-swiftui swift-tui-web swift-tui-android swift-tui-examples swift-tui-site
                       git commit -m "chore: bump org to $new_version"
                       bazel fetch //:org_full
                       bazel test  //:release_candidate

  See README.md "Updating Submodule Pins" and docs/PUBLIC-REPO-READINESS.md.
EOF

if [[ "$mode" == "dry-run" ]]; then
  printf '\n[bump_version] dry run only — no files changed. Re-run with --write to apply.\n'
else
  printf '\n[bump_version] edits applied. Review with: git -C <submodule> diff\n'
fi
