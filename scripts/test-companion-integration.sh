#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' 'Skipping canonical Mac/mobile companion integration tests outside macOS.'
  exit 0
fi
cache_root="${WOVENMATTER_INTEGRATION_TEST_CACHE_DIR:-/private/tmp/wovenmatter-companion-integration}"
mkdir -p "$cache_root/ModuleCache" "$cache_root/Cache"
env CLANG_MODULE_CACHE_PATH="$cache_root/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/ModuleCache" \
  swift test --disable-sandbox --package-path "$repo_root/integration" --scratch-path "$cache_root/SwiftPM" --cache-path "$cache_root/Cache"
