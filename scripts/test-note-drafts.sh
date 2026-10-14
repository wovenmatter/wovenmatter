#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' 'Skipping native note draft behavior tests outside macOS.'
  exit 0
fi
cache_root="${WOVENMATTER_DRAFT_TEST_CACHE_DIR:-/private/tmp/wovenmatter-functional-note-drafts}"
mkdir -p "$cache_root/ModuleCache"
xcrun swiftc \
  -swift-version 6 -parse-as-library -emit-library -emit-module -module-name WovenMatterCompanion \
  -module-cache-path "$cache_root/ModuleCache" -emit-module-path "$cache_root/WovenMatterCompanion.swiftmodule" \
  "$repo_root"/shared/Sources/WovenMatterCompanion/*.swift -o "$cache_root/libWovenMatterCompanion.dylib"
xcrun swiftc \
  -swift-version 6 -parse-as-library -emit-library -emit-module -module-name WovenMatterCore \
  -module-cache-path "$cache_root/ModuleCache" -emit-module-path "$cache_root/WovenMatterCore.swiftmodule" \
  -I "$cache_root" -L "$cache_root" -lWovenMatterCompanion -Xlinker -rpath -Xlinker "$cache_root" \
  "$repo_root"/app/Sources/WovenMatterCore/*.swift -o "$cache_root/libWovenMatterCore.dylib"
xcrun swiftc \
  -swift-version 6 -parse-as-library -module-cache-path "$cache_root/ModuleCache" \
  -I "$cache_root" -L "$cache_root" -lWovenMatterCore -lWovenMatterCompanion \
  -Xlinker -rpath -Xlinker "$cache_root" \
  "$repo_root/app/App/Services/DashboardNoteDrafts.swift" \
  "$repo_root/scripts/test-support/DashboardNoteDraftTests.swift" -o "$cache_root/DashboardNoteDraftTests"
"$cache_root/DashboardNoteDraftTests"
