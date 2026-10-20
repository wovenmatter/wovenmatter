#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${1:?Usage: scripts/test-ios-embedded-runtime.sh BOOTED_SIMULATOR_UUID}"
simulator="$1"
build="$(mktemp -d "${TMPDIR:-/tmp}/woven-embedded-smoke.XXXXXX")"
app="$build/Smoke.app"
mkdir -p "$app"
cp -R "$root/ios/Sources/EmbeddedExecution/Resources" "$app/EmbeddedResources"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.wovenmatter.embedded-smoke</string><key>CFBundleExecutable</key><string>Smoke</string><key>CFBundleName</key><string>Embedded Python Smoke</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleInfoDictionaryVersion</key><string>6.0</string><key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array><key>MinimumOSVersion</key><string>18.0</string><key>LSRequiresIPhoneOS</key><true/><key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array><key>UILaunchScreen</key><dict/></dict></plist>
PLIST
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
arch="$(uname -m)"
xcrun --sdk iphonesimulator swiftc -swift-version 6 -parse-as-library \
  -target "$arch-apple-ios18.0-simulator" -sdk "$sdk" \
  "$root/ios/Sources/EmbeddedExecution/EmbeddedWorkspace.swift" \
  "$root/ios/Sources/EmbeddedExecution/EmbeddedCommandExecutor.swift" \
  "$root/ios/EmbeddedRuntime/SmokeRunner.swift" \
  "$root/ios/EmbeddedRuntime/SmokeApp.swift" -o "$app/Smoke"
codesign -s - "$app"
xcrun simctl install "$simulator" "$app"
run_id="$(uuidgen)"
SIMCTL_CHILD_WOVEN_EMBEDDED_RUN_ID="$run_id" xcrun simctl launch --terminate-running-process "$simulator" com.wovenmatter.embedded-smoke
container="$(xcrun simctl get_app_container "$simulator" com.wovenmatter.embedded-smoke data)"
python3 - "$container/Documents/report.json" "$run_id" <<'PY'
import json, pathlib, sys, time
report = pathlib.Path(sys.argv[1])
for attempt in range(180):
    try: value = json.loads(report.read_text())
    except (OSError, ValueError): value = {}
    if value.get('runID') == sys.argv[2] and value.get('status') in ('passed','failed'):
        print(json.dumps(value,indent=2))
        if value['status'] != 'passed' or any(value.get(key) is not True for key in ('receiptReplay','sqlitePersistence','cancel','symlinkRejected','interruptedReplayRejected','conflictPreserved','fullOutputSaved','pythonUnitTests','virtualCLIFile','libraryIntoPython','importKeepsConflict')):
            raise SystemExit(1)
        break
    time.sleep(1)
else: raise SystemExit('Timed out waiting for the embedded-runtime smoke report')
PY
