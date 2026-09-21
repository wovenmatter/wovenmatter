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
  "$repo_root/app/App/Models/ConversationMarkdownDocument.swift" \
  "$repo_root/app/App/Models/ConversationMessageLayout.swift" \
  "$repo_root/scripts/test-support/ConversationMessageLayoutTests.swift" \
  -o "$cache_root/ConversationMessageLayoutTests"
"$cache_root/ConversationMessageLayoutTests"
