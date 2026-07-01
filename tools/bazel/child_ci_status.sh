#!/usr/bin/env bash
set -euo pipefail

# Fails when any pinned child commit has a FAILING GitHub CI check.
#
# The org root records child revisions as submodule pins; nothing else verifies
# that the pinned commits were green in their own repos. Without this contract a
# pin bump can silently ship a child whose required gate is red (this happened:
# org 96a4f4d and b08c94a both pinned swift-tui SHAs with failing Repo Gates —
# see docs/reports/2026-07-01-001-architecture-safety-performance-survey.md F01).
#
# Policy per pinned submodule commit:
#   - any completed check run concluded `failure`/`timed_out`  -> FAIL
#   - check runs still queued/in progress                      -> WARN (pass)
#   - no check runs at all (repo without CI, e.g. `github`)    -> pass
#   - GitHub API unreachable: WARN + skip locally, FAIL when $CI is set
#
# Auth: uses GITHUB_TOKEN / GH_TOKEN when present (passed through by .bazelrc
# `--test_env`), else a logged-in `gh` CLI, else unauthenticated (7 requests
# per run stays far below the anonymous rate limit).

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

# Single-sourced from tools/registry/repos.json via the generated bash arrays.
# shellcheck source=tools/registry/repos.generated.sh
source "$repo_root/tools/registry/repos.generated.sh"

token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
  token="$(gh auth token 2>/dev/null || true)"
fi
auth_args=()
if [[ -n "$token" ]]; then
  auth_args=(-H "Authorization: Bearer $token")
fi

skip_offline() {
  echo "WARN: cannot reach the GitHub API ($1) — skipping the child-CI contract." >&2
  echo "      Re-run online before pushing a pin bump." >&2
  exit 0
}

failures=0
for i in "${!ALL_SUBMODULE_REPOS[@]}"; do
  repo="${ALL_SUBMODULE_REPOS[$i]}"
  url="${ALL_SUBMODULE_URLS[$i]}"
  slug="${url#git@github.com:}"
  slug="${slug%.git}"

  sha="$(git ls-tree HEAD "$repo" | awk '$2 == "commit" {print $3}')"
  if [[ -z "$sha" ]]; then
    echo "No submodule gitlink recorded for $repo" >&2
    exit 1
  fi

  if ! response="$(
    curl -fsS --max-time 15 \
      -H "Accept: application/vnd.github+json" \
      ${auth_args[@]+"${auth_args[@]}"} \
      "https://api.github.com/repos/$slug/commits/$sha/check-runs?per_page=100"
  )"; then
    if [[ -n "${CI:-}" ]]; then
      echo "GitHub check-runs query failed for $slug@$sha" >&2
      exit 1
    fi
    skip_offline "$slug@$sha"
  fi

  verdicts="$(
    printf '%s' "$response" | python3 -c '
import json
import sys

runs = json.load(sys.stdin).get("check_runs", [])
for run in runs:
    name = run.get("name", "?")
    if run.get("status") != "completed":
        print(f"PENDING\t{name}")
    elif run.get("conclusion") in ("failure", "timed_out"):
        link = run.get("html_url", "")
        print(f"BAD\t{name}\t{link}")
'
  )"

  short_sha="${sha:0:10}"
  if [[ -z "$verdicts" ]]; then
    echo "OK       $repo @ $short_sha (no failing or pending checks)"
    continue
  fi
  while IFS=$'\t' read -r verdict name link; do
    case "$verdict" in
      BAD)
        echo "RED      $repo @ $short_sha — failing check '$name' $link" >&2
        failures=$((failures + 1))
        ;;
      PENDING)
        echo "PENDING  $repo @ $short_sha — check '$name' still running (not blocking)"
        ;;
    esac
  done <<<"$verdicts"
done

if ((failures > 0)); then
  echo >&2
  echo "One or more pinned child commits have failing CI checks." >&2
  echo "Fix the child repo (or pin a green commit) before bumping pins." >&2
  exit 1
fi
