#!/usr/bin/env bash
set -euo pipefail
# Run after the app build: exercise its real presentation/state sources without launching Dev.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${WOVENMATTER_TEST_CACHE_DIR:-/private/tmp/wovenmatter-validation}"
products="$cache_root/DerivedData/Build/Products/Debug"
mkdir -p "$cache_root/ConversationState"
xcrun swiftc -parse-as-library -swift-version 6 \
  -I "$products" -module-cache-path "$cache_root/ModuleCache" \
  "$repo_root/app/App/Models/DashboardConversationState.swift" \
  "$repo_root/app/App/Models/ConversationMarkdownDocument.swift" \
  "$repo_root/scripts/test-support/DashboardConversationStateTests.swift" \
  "$products/WovenMatterCore.o" "$products/WovenMatterClient.o" "$products/WovenMatterDashboardStore.o" \
  -lsqlite3 -framework Security -framework LocalAuthentication \
  -o "$cache_root/ConversationState/tests"
"$cache_root/ConversationState/tests"
