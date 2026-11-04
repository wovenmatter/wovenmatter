#!/usr/bin/env bash
set -euo pipefail

# Interactive AppKit fixture: opens only its own temporary test app, never Dev.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' 'Skipping native popover motion checks outside macOS.'
  exit 0
fi
cache_root="$(mktemp -d "${TMPDIR:-/tmp}/wovenmatter-popover-tests.XXXXXX")"
app_path="$cache_root/PopoverFixture.app"
mkdir -p "$app_path/Contents/MacOS" "$cache_root/ModuleCache"
xcrun swiftc -module-cache-path "$cache_root/ModuleCache" \
  "$repo_root/app/App/Views/DashboardConversationPopover.swift" \
  "$repo_root/scripts/test-support/DashboardConversationPopoverTests.swift" \
  -o "$app_path/Contents/MacOS/PopoverFixture"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.wovenmatter.private-hover-motion-fixture</string>
<key>CFBundleExecutable</key><string>PopoverFixture</string>
<key>CFBundleName</key><string>Hover Motion Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
open -n -W "$app_path" --stdout "$cache_root/output.log" --stderr "$cache_root/error.log"
cat "$cache_root/output.log" "$cache_root/error.log"
grep -q '^ALL POPOVER LIFECYCLE CHECKS PASSED$' "$cache_root/output.log"
printf 'Popover fixture evidence: %s\n' "$cache_root"
