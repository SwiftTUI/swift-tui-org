#!/usr/bin/env bash
set -euo pipefail

# Smoke-tests for the coordination overlay scripts (materialize + open_overlay).
# Cheap regression check that exercises both source modes, the --print-env
# scope conditional, and the bad-mode error path WITHOUT invoking the native
# toolchains (SwiftPM, Bun) that the pretag/worktree gates run.
#
# Must be tagged `exclusive` in BUILD.bazel: the worktree-mode check places a
# temporary marker file in swift-tui/ to demonstrate that worktree mode copies
# uncommitted edits, and pin_cleanliness.sh fails on any untracked file in
# any submodule. The trap on EXIT/INT/TERM/HUP removes the marker before the
# test process returns, even on failure.

script_source="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  script_path="$(realpath "$script_source")"
else
  script_path="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$script_source")"
fi
script_dir="$(cd "$(dirname "$script_path")" && pwd)"

if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  repo_root="$BUILD_WORKSPACE_DIRECTORY"
else
  repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    repo_root="$(cd "$script_dir/../.." && pwd)"
  fi
fi

tmpdir="${TEST_TMPDIR:-$(mktemp -d -t swifttui-overlay-smoke.XXXXXX)}"
marker=""
fail_count=0

ok()   { printf '[smoke] ok: %s\n' "$1"; }
err()  { printf '[smoke] FAIL: %s\n' "$1" >&2; fail_count=$((fail_count + 1)); }
info() { printf '[smoke] %s\n' "$1"; }

cleanup() {
  if [[ -n "$marker" && -f "$marker" ]]; then
    rm -f "$marker"
  fi
  if [[ -z "${TEST_TMPDIR:-}" && -d "$tmpdir" ]]; then
    rm -rf "$tmpdir"
  fi
}
trap cleanup EXIT INT TERM HUP

mat="$repo_root/tools/coordination/materialize_pretag_overlay.sh"
open_overlay="$repo_root/tools/coordination/open_overlay.sh"

# ─── worktree mode materializes uncommitted edits, with rewrites applied ────
info "worktree-mode materialization (places marker, then runs rsync)"
marker="$repo_root/swift-tui/.swifttui-org-smoke-marker"
printf 'swifttui-org overlay smoke %s\n' "$$" > "$marker"

worktree_overlay="$tmpdir/worktree"
"$mat" --source-mode worktree --output "$worktree_overlay" examples >/dev/null

if [[ -f "$worktree_overlay/swift-tui/.swifttui-org-smoke-marker" ]]; then
  ok "worktree mode copied the uncommitted marker into the overlay"
else
  err "worktree mode did NOT copy the uncommitted marker"
fi

# Rewrites run after copy and are mode-independent — verifying once is enough.
# Enumerate EVERY Package.swift at full depth (not a maxdepth-2 sample) and assert
# both (a) the localization actually applied and (b) NO manifest still carries an
# un-localized public SwiftTUI sibling pin. (b) mirrors the materializer's own
# fail-loud guard, re-checked here so the smoke test still catches a regression if
# that internal guard is ever weakened.
rewritten_count=0
unlocalized=()
while IFS= read -r -d '' pkg; do
  if grep -q '"swift-tui", path:' "$pkg"; then
    rewritten_count=$((rewritten_count + 1))
  fi
  if grep -Eq 'url:[[:space:]]*"https://github\.com/SwiftTUI/swift-tui(-swiftui)?(\.git)?"' "$pkg"; then
    unlocalized+=("${pkg#$worktree_overlay/}")
  fi
done < <(find "$worktree_overlay" -name Package.swift -print0)
if [[ "$rewritten_count" -ge 1 ]]; then
  ok "examples Package.swift rewrites applied to $rewritten_count file(s) (full-depth scan)"
else
  err "no examples Package.swift rewrites found"
fi
if [[ "${#unlocalized[@]}" -eq 0 ]]; then
  ok "no un-localized SwiftTUI sibling pins remain in the overlay"
else
  err "un-localized SwiftTUI sibling pins remain: ${unlocalized[*]}"
fi

# Web localization is now a structured edit to the examples ROOT package.json (not
# per-file regex rewrites): the two local web packages are added as workspace
# members and @swifttui/{web,build} are redirected to them via overrides:workspace:*.
examples_package="$worktree_overlay/swift-tui-examples/package.json"
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); ov=d.get('overrides',{}); ws=d.get('workspaces',[]); sys.exit(0 if ov.get('@swifttui/web')=='workspace:*' and ov.get('@swifttui/build')=='workspace:*' and '../swift-tui-web/packages/web' in ws else 1)" "$examples_package"; then
  ok "examples package.json localizes @swifttui/{web,build} to local workspace members"
else
  err "examples package.json did not localize @swifttui web packages to workspace members"
fi

# ...and that WebExample/package.json is left UNTOUCHED (the root override reaches
# it; we no longer rewrite a child file the root does not own).
webexample_package="$worktree_overlay/swift-tui-examples/WebExample/package.json"
if grep -q 'releases/download/.*swifttui-web' "$webexample_package"; then
  ok "WebExample package.json left untouched (root override localizes it, no per-file rewrite)"
else
  err "WebExample package.json was unexpectedly modified (should keep its released tarball deps)"
fi

# ─── open_overlay --print-env examples: emits exports, head mode skips marker ─
info "open_overlay --print-env examples (head mode, marker still in tree)"
env_overlay_ex="$tmpdir/env-examples"
env_out_ex="$("$open_overlay" --source-mode head --output "$env_overlay_ex" --print-env examples 2>/dev/null)"

for var in SWIFTTUI_CHECKOUT SWIFTTUI_WEB_CHECKOUT SWIFTTUI_EXAMPLES_CHECKOUT; do
  if printf '%s\n' "$env_out_ex" | grep -q "^export $var="; then
    ok "examples scope: --print-env emitted $var"
  else
    err "examples scope: --print-env missing $var"
  fi
done

if printf '%s\n' "$env_out_ex" | grep -q "^export WEBEXAMPLE_DIR="; then
  err "examples scope: --print-env unexpectedly included WEBEXAMPLE_DIR"
else
  ok "examples scope: --print-env correctly omits WEBEXAMPLE_DIR"
fi

if [[ -f "$env_overlay_ex/swift-tui/.swifttui-org-smoke-marker" ]]; then
  err "head mode unexpectedly copied the uncommitted marker into the overlay"
else
  ok "head mode correctly skipped the uncommitted marker"
fi

# ─── open_overlay --print-env all: includes WEBEXAMPLE_DIR ──────────────────
info "open_overlay --print-env all (head mode)"
env_overlay_all="$tmpdir/env-all"
env_out_all="$("$open_overlay" --source-mode head --output "$env_overlay_all" --print-env all 2>/dev/null)"

if printf '%s\n' "$env_out_all" | grep -q "^export WEBEXAMPLE_DIR="; then
  ok "all scope: --print-env includes WEBEXAMPLE_DIR"
else
  err "all scope: --print-env missing WEBEXAMPLE_DIR"
fi

# Marker no longer needed; clear early so the trap is a no-op if the rest fails.
rm -f "$marker"
marker=""

# ─── invalid --source-mode is rejected with non-zero exit ───────────────────
info "invalid --source-mode rejected"
if "$mat" --source-mode banana --output "$tmpdir/should-not-exist" examples >/dev/null 2>&1; then
  err "materializer accepted --source-mode banana"
else
  ok "materializer rejected --source-mode banana"
fi

if "$open_overlay" --source-mode banana --output "$tmpdir/should-not-exist" examples >/dev/null 2>&1; then
  err "open_overlay accepted --source-mode banana"
else
  ok "open_overlay rejected --source-mode banana"
fi

# ─── result ─────────────────────────────────────────────────────────────────
if [[ "$fail_count" -gt 0 ]]; then
  printf '\n[smoke] %d failure(s)\n' "$fail_count" >&2
  exit 1
fi
printf '\n[smoke] all checks passed\n'
