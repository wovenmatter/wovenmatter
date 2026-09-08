#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${WOVENMATTER_TEST_CACHE_DIR:-/private/tmp/wovenmatter-validation}"
products="${cache_root}/DerivedData/Build/Products/Debug"
xcrun swiftc -swift-version 6 -parse-as-library \
  -I "$products" \
  "$products/WovenMatterCore.o" "$products/WovenMatterClient.o" "$products/WovenMatterDashboardStore.o" \
  -lsqlite3 -framework Security -framework LocalAuthentication \
  "$repo_root/app/App/Services/WovenNoteService.swift" \
  "$repo_root/app/App/Services/WovenHistoryService.swift" \
  "$repo_root/scripts/test-support/WovenHistorySocketTests.swift" \
  -o "$cache_root/WovenHistorySocketTests"
"$cache_root/WovenHistorySocketTests"
