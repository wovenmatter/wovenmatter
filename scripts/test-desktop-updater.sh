#!/usr/bin/env bash
# Exercise the production delegate against the actual pinned framework, offline.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || exit 0
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tools="${WOVENMATTER_TEST_SPARKLE_TOOLS:-$("$root/scripts/prepare-sparkle-tools.sh")}"
cache="${WOVENMATTER_TEST_CACHE_DIR:-/private/tmp/wovenmatter-validation}"
mkdir -p "$cache/ModuleCache"
fixture="$(mktemp -d "$cache/DesktopUpdaterTests.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$cache/ModuleCache" \
  -F "$tools" -framework Sparkle -Xlinker -rpath -Xlinker "$tools" \
  "$root/app/App/Services/DesktopUpdater.swift" "$root/scripts/test-support/DesktopUpdaterTests.swift" \
  -o "$fixture/Probe"
"$fixture/Probe"
