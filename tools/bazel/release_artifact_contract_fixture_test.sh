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

tmpdir="${TEST_TMPDIR:-$(mktemp -d -t swifttui-release-artifacts-fixture.XXXXXX)}"
cleanup_tmp=0
if [[ -z "${TEST_TMPDIR:-}" ]]; then
  cleanup_tmp=1
fi
if [[ "$cleanup_tmp" -eq 1 ]]; then
  trap 'rm -rf "$tmpdir"' EXIT
fi

version="9.9.9"
web_base="$tmpdir/web-releases"
android_base="$tmpdir/android-maven"
bin_dir="$tmpdir/bin"
mkdir -p "$web_base/$version" "$android_base" "$bin_dir"

make_tarball() {
  local package_name=$1
  local package_version=$2
  local dependency_version=$3
  local output=$4
  local package_dir="$tmpdir/package-${package_name##*/}"
  rm -rf "$package_dir"
  mkdir -p "$package_dir/package"
  if [[ -n "$dependency_version" ]]; then
    cat >"$package_dir/package/package.json" <<EOF
{
  "name": "$package_name",
  "version": "$package_version",
  "dependencies": {
    "@swifttui/web": "$dependency_version"
  }
}
EOF
  else
    cat >"$package_dir/package/package.json" <<EOF
{
  "name": "$package_name",
  "version": "$package_version"
}
EOF
  fi
  tar -czf "$output" -C "$package_dir" package
}

write_maven_fixture() {
  mkdir -p \
    "$android_base/sh/swifttui/android-host/$version" \
    "$android_base/sh/swifttui/android-host" \
    "$android_base/sh/swifttui/android/sh.swifttui.android.gradle.plugin/$version" \
    "$android_base/sh/swifttui/android/sh.swifttui.android.gradle.plugin" \
    "$android_base/sh/swifttui/android-plugin/$version" \
    "$android_base/sh/swifttui/android-plugin"

  printf 'aar' >"$android_base/sh/swifttui/android-host/$version/android-host-$version.aar"
  printf 'jar' >"$android_base/sh/swifttui/android-plugin/$version/android-plugin-$version.jar"
  for metadata in \
    "$android_base/sh/swifttui/android-host/maven-metadata.xml" \
    "$android_base/sh/swifttui/android/sh.swifttui.android.gradle.plugin/maven-metadata.xml" \
    "$android_base/sh/swifttui/android-plugin/maven-metadata.xml"; do
    cat >"$metadata" <<EOF
<metadata>
  <versioning>
    <versions>
      <version>$version</version>
    </versions>
  </versioning>
</metadata>
EOF
  done
  cat >"$android_base/sh/swifttui/android/sh.swifttui.android.gradle.plugin/$version/sh.swifttui.android.gradle.plugin-$version.pom" <<EOF
<project>
  <version>$version</version>
  <dependencies>
    <dependency>
      <groupId>sh.swifttui</groupId>
      <artifactId>android-plugin</artifactId>
      <version>$version</version>
    </dependency>
  </dependencies>
</project>
EOF
}

write_fake_tools() {
  cat >"$bin_dir/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "view @swifttui/web@9.9.9 version --json"|"view @swifttui/build@9.9.9 version --json")
    printf '"9.9.9"\n'
    ;;
  *)
    printf 'unexpected npm invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/npm"

  cat >"$bin_dir/bun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "install" ]]; then
  exit 0
fi
printf 'unexpected bun invocation: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "$bin_dir/bun"
}

run_contract() {
  env \
    PATH="$bin_dir:$PATH" \
    SWIFTTUI_RELEASE_ARTIFACT_VERSION="$version" \
    SWIFTTUI_RELEASE_WEB_BASE_URL="file://$web_base" \
    SWIFTTUI_RELEASE_ANDROID_MAVEN_BASE_URL="file://$android_base" \
    SWIFTTUI_RELEASE_ARTIFACT_SKIP_TAGS=1 \
    "$repo_root/tools/bazel/release_artifact_contract.sh"
}

make_tarball "@swifttui/web" "$version" "" "$web_base/$version/swifttui-web-$version.tgz"
make_tarball "@swifttui/build" "$version" "$version" "$web_base/$version/swifttui-build-$version.tgz"
write_maven_fixture
write_fake_tools

run_contract >"$tmpdir/success.log"
grep -Fq "[release_artifact_contract] ok" "$tmpdir/success.log"

make_tarball "@swifttui/build" "$version" "9.9.8" "$web_base/$version/swifttui-build-$version.tgz"
if run_contract >"$tmpdir/failure.log" 2>&1; then
  printf 'expected mismatched build tarball dependency to fail\n' >&2
  cat "$tmpdir/failure.log" >&2
  exit 1
fi
grep -Fq "@swifttui/web dependency '9.9.8' != '9.9.9'" "$tmpdir/failure.log"

printf '[release_artifact_contract_fixture_test] ok\n'
