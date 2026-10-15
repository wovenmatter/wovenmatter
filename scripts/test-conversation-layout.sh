#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' 'Skipping native Markdown presentation checks outside macOS.'
  exit 0
fi
cache_root="${WOVENMATTER_CONVERSATION_TEST_CACHE_DIR:-/private/tmp/wovenmatter-conversation-layout-tests}"
mkdir -p "$cache_root/ModuleCache"
xcrun swiftc -parse-as-library -module-cache-path "$cache_root/ModuleCache" \
  "$repo_root/app/App/Models/ConversationMessageLayout.swift" \
  "$repo_root/scripts/test-support/ConversationMessageLayoutTests.swift" \
  -o "$cache_root/ConversationMessageLayoutTests"
"$cache_root/ConversationMessageLayoutTests"

xcrun swiftc -parse-as-library -module-cache-path "$cache_root/ModuleCache" \
  "$repo_root/app/App/Models/ConversationMarkdownDocument.swift" \
  "$repo_root/app/App/Views/DashboardColors.swift" \
  "$repo_root/app/App/Views/ConversationResponse.swift" \
  "$repo_root/scripts/test-support/ConversationResponseTests.swift" \
  -o "$cache_root/ConversationResponseTests"
"$cache_root/ConversationResponseTests"

# Shared presentation code must also compile with the installed iOS SDK.
# Catch AppKit/new-SDK-only symbols before the full desktop and simulator builds.
ios_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -typecheck -parse-as-library \
  -target "$(uname -m)-apple-ios18.0-simulator" -sdk "$ios_sdk" \
  -module-cache-path "$cache_root/UIKitModuleCache" \
  "$repo_root/app/App/Models/ConversationMarkdownDocument.swift" \
  "$repo_root/app/App/Views/DashboardColors.swift" \
  "$repo_root/app/App/Views/ConversationResponse.swift" \
  "$repo_root/scripts/test-support/ConversationResponseTests.swift"
