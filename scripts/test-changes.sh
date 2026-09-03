#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
if [ "$(uname -s)" = "Darwin" ]; then
  default_cache_root="/private/tmp/wovenmatter-validation"
else
  default_cache_root="${TMPDIR:-/tmp}/wovenmatter-validation"
fi
cache_root="${WOVENMATTER_TEST_CACHE_DIR:-$default_cache_root}"
swift_scratch="${cache_root}/SwiftPM"
derived_data="${cache_root}/DerivedData"
host_arch="$(uname -m)"
mkdir -p "$swift_scratch" "$derived_data"

run_static_checks() {
  local file
  for file in harnesses/initialize-workspace.sh remote/entrypoint.sh scripts/*.sh; do
    bash -n "$file"
  done
  scripts/test-usage-scroll-contract.sh
  scripts/test-sidebar-page-contract.sh
  scripts/test-release.sh
  scripts/test-remote-workspace.sh
  for file in remote/src/*.mjs remote/test/*.test.mjs; do
    node --check "$file"
  done
  jq -e '.schemaVersion == 4 and (.harnesses | length == 8)' harnesses/catalog.json >/dev/null
  scripts/scan-public-tree.sh
}

run_package_tests() {
  env \
    CLANG_MODULE_CACHE_PATH="${cache_root}/ModuleCache" \
    SWIFTPM_MODULECACHE_OVERRIDE="${cache_root}/ModuleCache" \
    swift test --package-path app --scratch-path "$swift_scratch"
}

run_remote_tests() {
  npm test --prefix remote
}

run_app_build() {
  xcodebuild -quiet \
    -project app/WovenMatter.xcodeproj \
    -scheme WovenMatter \
    -configuration Debug \
    -destination "platform=macOS,arch=${host_arch}" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build
  scripts/validate-native-app.sh \
    "${derived_data}/Build/Products/Debug/Woven Matter Dev.app"
}

run_all() {
  run_static_checks
  run_remote_tests
  run_package_tests
  run_app_build
}

run_macos() {
  run_static_checks
  run_package_tests
  run_app_build
}

run_remote() {
  run_static_checks
  run_remote_tests
}

mode="${1:-changed}"
case "$mode" in
  --all) run_all; exit ;;
  --macos) run_macos; exit ;;
  --remote) run_remote; exit ;;
  changed) ;;
  *)
    printf '%s\n' 'usage: scripts/test-changes.sh [--all|--macos|--remote]' >&2
    exit 64
    ;;
esac

base="${WOVENMATTER_TEST_BASE:-origin/main}"
changed="$(
  git diff --name-only "$base"...HEAD
  git diff --name-only
  git ls-files --others --exclude-standard
)"
changed="$(printf '%s\n' "$changed" | sort -u)"
if [ -z "$changed" ]; then
  printf 'No changes relative to %s.\n' "$base"
elif printf '%s\n' "$changed" | grep -Eq '^(remote/|harnesses/|scripts/|\.github/|\.dockerignore$|app/Package|app/WovenMatter\.xcodeproj)'; then
  run_all
elif printf '%s\n' "$changed" | grep -Eq '^app/(Sources|Tests)/'; then
  run_package_tests
else
  run_static_checks
  run_app_build
fi
