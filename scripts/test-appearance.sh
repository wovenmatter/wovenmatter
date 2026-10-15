#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' 'Skipping native appearance checks outside macOS.'
  exit 0
fi
cache_root="${WOVENMATTER_TEST_CACHE_DIR:-/private/tmp/wovenmatter-validation}/AppearanceTests"
mkdir -p "$cache_root/ModuleCache"
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$cache_root/ModuleCache" \
  "$repo_root/app/App/Views/DashboardColors.swift" \
  "$repo_root/app/App/Views/DashboardHTMLArtifactDocument.swift" \
  "$repo_root/scripts/test-support/DashboardAppearanceTests.swift" \
  -o "$cache_root/DashboardAppearanceTests"
"$cache_root/DashboardAppearanceTests"
