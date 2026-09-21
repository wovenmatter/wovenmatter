#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'Skipping application usage observation tests outside macOS.'
  exit 0
fi
cache_root="${WOVENMATTER_TEST_CACHE_DIR:-/private/tmp/wovenmatter-validation}"
swift_scratch="${cache_root}/SwiftPM"
mkdir -p "$cache_root/ModuleCache"
export CLANG_MODULE_CACHE_PATH="${cache_root}/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="${cache_root}/ModuleCache"
swift build --package-path "$repo_root/app" --scratch-path "$swift_scratch"
build_dir="$(swift build --package-path "$repo_root/app" --scratch-path "$swift_scratch" --show-bin-path)"
# SwiftPM's Swift Build backend emits aggregate objects; the native backend
# keeps per-source objects and a separate Modules directory.
if [ -f "$build_dir/WovenMatterCore.o" ]; then
  module_dir="$build_dir"
  objects=("$build_dir/WovenMatterCore.o" "$build_dir/WovenMatterClient.o" "$build_dir/WovenMatterDashboardStore.o")
else
  module_dir="$build_dir/Modules"
  objects=(
    "$build_dir"/WovenMatterCore.build/*.swift.o
    "$build_dir"/WovenMatterClient.build/*.swift.o
    "$build_dir"/WovenMatterDashboardStore.build/*.swift.o
  )
fi
xcrun swiftc -swift-version 6 -parse-as-library \
  -target "$(uname -m)-apple-macos26.0" \
  -module-cache-path "$cache_root/ModuleCache" -I "$module_dir" \
  "$repo_root/app/App/Models/ApplicationUsageModel.swift" \
  "$repo_root/scripts/test-support/ApplicationUsageModelTests.swift" \
  "${objects[@]}" -lsqlite3 -framework Security -framework LocalAuthentication \
  -o "$cache_root/ApplicationUsageModelTests"
"$cache_root/ApplicationUsageModelTests"
