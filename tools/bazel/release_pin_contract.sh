#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  script_path="$(realpath "$script_source")"
else
  script_path="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$script_source")"
fi

repo_root="$(git -C "$(dirname "$script_path")" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "$script_path")/../.." && pwd)"
fi

cd "$repo_root"

fail() {
  printf '[release_pin_contract] %s\n' "$1" >&2
  exit 1
}

# Single-sourced from tools/registry/repos.json via the generated bash arrays.
# BAZEL_MODULE_REPOS covers every Bazel-module child (now incl. swift-tui-android,
# which was previously missing from this release-reachability check).
# shellcheck source=tools/registry/repos.generated.sh
source "$repo_root/tools/registry/repos.generated.sh"
repos=("${BAZEL_MODULE_REPOS[@]}")

for repo in "${repos[@]}"; do
  head_commit="$(git -C "$repo" rev-parse --verify HEAD^{commit})"
  reachable_ref=""

  tag_at_head="$(git -C "$repo" tag --points-at "$head_commit" | head -n 1)"
  if [[ -n "$tag_at_head" ]]; then
    printf '[release_pin_contract] %s reachable from tag %s\n' "$repo" "$tag_at_head"
    continue
  fi

  # Reachability is restricted to published release lines: origin/main only.
  # A pin reachable solely from some unrelated remote branch (a draft/feature
  # ref) is NOT a released commit and must not pass.
  for release_ref in "origin/main"; do
    if ! git -C "$repo" rev-parse --verify --quiet "$release_ref^{commit}" >/dev/null; then
      continue
    fi

    if git -C "$repo" merge-base --is-ancestor "$head_commit" "$release_ref"; then
      reachable_ref="$release_ref"
      break
    fi
  done

  if [[ -n "$reachable_ref" ]]; then
    printf '[release_pin_contract] %s reachable from %s\n' "$repo" "$reachable_ref"
    continue
  fi

  fail "$repo pin $head_commit is not reachable from origin/main or an exact tag; fetch the child repo or pin a published commit"
done

printf '[release_pin_contract] ok\n'
