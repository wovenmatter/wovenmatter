#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'Skipping AppKit termination test outside macOS.'
  exit 0
fi

cache_root="${WOVENMATTER_TEST_CACHE_DIR:-/private/tmp/wovenmatter-validation}"
mkdir -p "$cache_root/ModuleCache"
test_root="$(mktemp -d "${cache_root}/AppTerminationTests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
app="$test_root/TerminationProbe.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>wovenmatter.tests.termination</string>
<key>CFBundleExecutable</key><string>TerminationProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 6 \
  -module-cache-path "$cache_root/ModuleCache" \
  "$repo_root/app/App/WovenMatterLifecycleDelegate.swift" \
  "$repo_root/scripts/test-support/AppTerminationTests.swift" \
  -o "$app/Contents/MacOS/TerminationProbe"
open -n -W "$app" --args "$test_root/result"
if [ "$(cat "$test_root/result")" != PASS ]; then
  cat "$test_root/result" >&2
  exit 1
fi
printf '%s\n' 'AppKit quit from updater task: passed (termination deferred, cleanup once, app exited).'
