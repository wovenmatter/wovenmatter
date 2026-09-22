#!/usr/bin/env bash
set -euo pipefail
# Manual native UI fixture. Does not launch Dev or access real workspace data.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${WOVENMATTER_TEST_CACHE_DIR:-/private/tmp/wovenmatter-calendar-preview}"
mkdir -p "$cache_root/ModuleCache"
swift build --package-path "$repo_root/app" --scratch-path "$cache_root/SwiftPM"
build_dir="$(swift build --package-path "$repo_root/app" --scratch-path "$cache_root/SwiftPM" --show-bin-path)"
if [ -f "$build_dir/WovenMatterCore.o" ]; then
  module_dir="$build_dir"
  objects=("$build_dir/WovenMatterCore.o" "$build_dir/WovenMatterClient.o" "$build_dir/WovenMatterDashboardStore.o")
else
  module_dir="$build_dir/Modules"
  objects=("$build_dir"/WovenMatterCore.build/*.swift.o "$build_dir"/WovenMatterClient.build/*.swift.o "$build_dir"/WovenMatterDashboardStore.build/*.swift.o)
fi
app_path="$cache_root/CalendarPreview.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources/harnesses"
cp "$repo_root/harnesses/catalog.json" "$app_path/Contents/Resources/harnesses/catalog.json"
xcrun swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos26.0" \
  -module-cache-path "$cache_root/ModuleCache" -I "$module_dir" \
  "$repo_root/app/App/Views/DashboardDesign.swift" \
  "$repo_root/app/App/Views/DashboardCalendarView.swift" \
  "$repo_root/app/App/Views/DashboardCalendarEventSheet.swift" \
  "$repo_root/app/App/Views/DashboardCalendarFormControls.swift" \
  "$repo_root/app/App/Views/DashboardCalendarTaskFields.swift" \
  "$repo_root/scripts/test-support/CalendarUIFixture.swift" \
  "${objects[@]}" -lsqlite3 -framework Security -framework LocalAuthentication \
  -o "$app_path/Contents/MacOS/CalendarPreview"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.wovenmatter.private-calendar-preview</string>
<key>CFBundleExecutable</key><string>CalendarPreview</string>
<key>CFBundleName</key><string>Calendar Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
# Use already-built assets when available; the controls still work without icons.
assets="$cache_root/DerivedData/Build/Products/Debug/Woven Matter Dev.app/Contents/Resources/Assets.car"
if [ -f "$assets" ]; then cp "$assets" "$app_path/Contents/Resources/Assets.car"; fi
open -n "$app_path" --args "$@"
printf 'Calendar preview: %s\n' "$app_path"
