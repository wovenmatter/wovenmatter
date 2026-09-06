#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' 'Skipping AppKit composer behavior tests outside macOS.'
  exit 0
fi

cache_root="${WOVENMATTER_TEST_CACHE_DIR:-/private/tmp/wovenmatter-validation}"
test_root="${cache_root}/ComposerTextEditorTests"
mkdir -p "$test_root" "${cache_root}/ModuleCache"

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "${cache_root}/ModuleCache" \
  "${repo_root}/app/App/Views/DashboardComposerTextEditor.swift" \
  "${repo_root}/scripts/test-support/DashboardComposerTextEditorTests.swift" \
  -o "${test_root}/DashboardComposerTextEditorTests"

"${test_root}/DashboardComposerTextEditorTests"
