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
  printf '[pin_cleanliness] %s\n' "$1" >&2
  exit 1
}

# Single-sourced from tools/registry/repos.json via the generated bash arrays.
# BAZEL_MODULE_REPOS covers every Bazel-module child (now incl. swift-tui-swiftui
# and swift-tui-android, which were previously missing from this check).
# shellcheck source=tools/registry/repos.generated.sh
source "$repo_root/tools/registry/repos.generated.sh"
repos=("${BAZEL_MODULE_REPOS[@]}")

if git submodule status --recursive | grep -E '^-'; then
  fail "one or more submodules are not initialized"
fi

if git submodule status --recursive | grep -E '^\+'; then
  fail "one or more submodules are checked out at a commit different from the root pin"
fi

for repo in "${repos[@]}"; do
  expected_commit="$(git ls-tree HEAD "$repo" | awk '{print $3}')"
  actual_commit="$(git -C "$repo" rev-parse --verify HEAD)"

  if [[ -z "$expected_commit" ]]; then
    fail "root commit does not pin submodule path: $repo"
  fi

  if [[ "$actual_commit" != "$expected_commit" ]]; then
    fail "$repo is at $actual_commit but root pins $expected_commit"
  fi

  status_output="$(git -C "$repo" status --porcelain=v1 --untracked-files=all)"
  if [[ -n "$status_output" ]]; then
    printf '%s\n' "$status_output" >&2
    fail "$repo has uncommitted changes"
  fi
done

printf '[pin_cleanliness] ok\n'
