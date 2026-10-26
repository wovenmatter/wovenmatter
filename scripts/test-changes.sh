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
  for file in remote/build-image.sh remote/entrypoint.sh remote/executor-deploy.sh scripts/*.sh; do
    bash -n "$file"
  done
  scripts/test-release.sh
  python3 scripts/test-support/test_update_refresh.py
  python3 scripts/test-support/test_ci_scopes.py
  python3 scripts/test-support/test_ios_runner.py
  bash scripts/test-dev-signing.sh
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-support/test_dev_build.py
  scripts/test-app-termination.sh
  scripts/test-composer-text-editor.sh
  scripts/test-conversation-layout.sh
  scripts/test-appearance.sh
  scripts/test-note-editor.sh
  scripts/test-note-drafts.sh
  python3 scripts/test-support/test_executor_deployment.py
  node --test scripts/test-support/native-mcp.test.mjs
  scripts/test-remote-workspace.sh
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-support/test_remote_image.py
  for file in remote/src/*.mjs remote/test/*.test.mjs; do
    node --check "$file"
  done
  jq -e '.schemaVersion == 4 and (.harnesses | length == 4)' harnesses/catalog.json >/dev/null
  scripts/scan-public-tree.sh
}

run_package_tests() {
  local suite
  local process_suites=(
    ACPSessionPermissionTests
    ACPSessionRoutingTests
    ClosedLidProtectionTests
    DefaultAgentSDKControlTests
    RemoteAttachmentStagingTests
    RemoteBrowserViewerTests
    WorkspaceAgentToolsServiceTests
    ConversationHTMLWebKitTests
    NativeHarnessArchiveTests
    NativeFramePrivacyTests
    NativeJSONSearchProjectionTests
    WorkspaceNativeRunArchiveTests
  )
  local isolated_filter
  printf -v isolated_filter '%s|' "${process_suites[@]}"
  isolated_filter="${isolated_filter%|}"
  local test_command=(env
    "CLANG_MODULE_CACHE_PATH=${cache_root}/ModuleCache"
    "SWIFTPM_MODULECACHE_OVERRIDE=${cache_root}/ModuleCache"
    swift test --build-system "${WOVENMATTER_SWIFT_BUILD_SYSTEM:-swiftbuild}" --force-resolved-versions --package-path app --scratch-path "$swift_scratch")
  # Process/socket and browser-feed fixtures measure startup, leases, deadlines,
  # and reaping; the SDK suite also
  # deliberately saturates the shared dispatch pool. Large archive fixtures
  # stream/hash more than 64 MiB and exercise long SQLite exports. Isolate these
  # resource-heavy suites so they cannot consume unrelated IPC timing budgets on
  # toolchains that combine every test target in one parallel runner. Every
  # excluded suite runs below with its original bounds and explicit concurrency
  # tests intact, using the same compiled test artifacts.
  "${test_command[@]}" --skip "$isolated_filter"
  for suite in "${process_suites[@]}"; do
    "${test_command[@]}" --skip-build --filter "$suite"
  done
  WOVENMATTER_TEST_CACHE_DIR="$cache_root" scripts/test-application-usage.sh
  WOVENMATTER_TEST_CACHE_DIR="$cache_root" scripts/test-backend-process.sh
}

run_default_agent_tests() {
  npm ci --prefix default-agent --ignore-scripts --no-audit --no-fund
  # Serialize test files that spawn SDK processes; their own concurrency tests
  # retain their original bounds and parallel operations.
  npm test --prefix default-agent
  node scripts/build-ios-pi-runtime.mjs --check
  node scripts/build-ios-embedded-runtime.mjs --check
  scripts/test-embedded-runtime-macos.sh
}

run_remote_tests() {
  npm test --prefix remote
}

run_app_build() {
  xcodebuild -quiet -onlyUsePackageVersionsFromResolvedFile \
    -project app/WovenMatter.xcodeproj \
    -scheme WovenMatter \
    -configuration Debug \
    -destination "platform=macOS,arch=${host_arch}" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build
  scripts/validate-native-app.sh \
    "${derived_data}/Build/Products/Debug/Woven Matter Dev.app"
  env WOVENMATTER_HTML_TEST_BUNDLE="${derived_data}/Build/Products/Debug/Woven Matter Dev.app" \
    CLANG_MODULE_CACHE_PATH="${cache_root}/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="${cache_root}/ModuleCache" \
    swift test --force-resolved-versions --package-path app --scratch-path "$swift_scratch" \
      --skip-build --filter packagedHTMLToolsWorkAcrossHarnesses
  # The fixture substitutes CEF entry points; it does not launch Chromium.
  local browser_build="${derived_data}/Build/Intermediates.noindex/WovenMatter.build/Debug/WovenMatter.build/DerivedSources/cef-${host_arch}"
  make -C "$browser_build" WovenBrowserLifecycleTests >/dev/null
  "$browser_build/WovenBrowserLifecycleTests"
}

run_companion() {
  local ios_mode="${1:---simulator}"
  env \
    CLANG_MODULE_CACHE_PATH="${cache_root}/ModuleCache" \
    SWIFTPM_MODULECACHE_OVERRIDE="${cache_root}/ModuleCache" \
    swift test --build-system "${WOVENMATTER_SWIFT_BUILD_SYSTEM:-swiftbuild}" --package-path shared --scratch-path "${cache_root}/SharedSwiftPM"
  if [ "$ios_mode" != --desktop-only ]; then
    env WOVENMATTER_IOS_TEST_CACHE_DIR="${cache_root}/IOS" \
      scripts/test-ios.sh "$ios_mode"
  fi
  env WOVENMATTER_INTEGRATION_TEST_CACHE_DIR="${cache_root}/Integration" \
    scripts/test-companion-integration.sh
}

run_all() {
  run_static_checks
  run_default_agent_tests
  run_remote_tests
  run_package_tests
  run_app_build
  run_companion --all-devices
}

run_desktop() {
  run_static_checks
  run_default_agent_tests
  run_package_tests
  run_app_build
}

run_macos() {
  run_desktop
  run_companion --simulator
}

run_remote() {
  run_static_checks
  run_default_agent_tests
  run_remote_tests
}

mode="${1:-changed}"
case "$mode" in
  --all) run_all; exit ;;
  --desktop) run_desktop; exit ;;
  --macos) run_macos; exit ;;
  --companion) run_companion --simulator; exit ;;
  --companion-desktop) run_companion --desktop-only; exit ;;
  --remote) run_remote; exit ;;
  changed) ;;
  *)
    printf '%s\n' 'usage: scripts/test-changes.sh [--all|--desktop|--macos|--companion|--companion-desktop|--remote]' >&2
    exit 64
    ;;
esac

base="${WOVENMATTER_TEST_BASE:-origin/main}"
changed="$(
  git diff --name-only "$base"...HEAD
  git diff --name-only
  git diff --cached --name-only
  git ls-files --others --exclude-standard
)"
changed="$(printf '%s\n' "$changed" | sort -u)"
if [ -z "$changed" ]; then
  printf 'No changes relative to %s.\n' "$base"
elif printf '%s\n' "$changed" | grep -Eq '^(default-agent/|shared/|ios/|integration/|remote/|harnesses/|scripts/|\.github/|\.dockerignore$|app/Package|app/WovenMatter\.xcodeproj)'; then
  run_all
elif printf '%s\n' "$changed" | grep -Eq '^app/App/' \
  && printf '%s\n' "$changed" | grep -Eq '^app/(Sources|Tests)/'; then
  run_macos
elif printf '%s\n' "$changed" | grep -Eq '^app/(Sources|Tests)/'; then
  run_package_tests
else
  run_static_checks
  run_app_build
fi
