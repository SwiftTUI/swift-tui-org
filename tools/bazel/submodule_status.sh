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

expected_repos=(
  "swift-tui"
  "swift-tui-swiftui"
  "swift-tui-web"
  "swift-tui-examples"
  "swift-tui-site"
)

if git submodule status --recursive | grep -E '^-'; then
  echo "One or more submodules are not initialized." >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

for repo in "${expected_repos[@]}"; do
  if [[ ! -d "$repo" ]]; then
    echo "Missing submodule directory: $repo" >&2
    exit 1
  fi

  if [[ ! -f "$repo/MODULE.bazel" ]]; then
    echo "Missing Bazel module metadata: $repo/MODULE.bazel" >&2
    exit 1
  fi

  if [[ ! -f "$repo/BUILD.bazel" ]]; then
    echo "Missing Bazel package metadata: $repo/BUILD.bazel" >&2
    exit 1
  fi
done

git submodule status --recursive
