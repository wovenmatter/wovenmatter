#!/usr/bin/env bash
# Runs the ios/ package's tests, then the app's UI tests on a simulator:
# WOVENMATTER_IOS_SIMULATOR_DESTINATION when set, else a simulator made for
# this run and deleted afterwards. --package runs only the package's tests.
set -euo pipefail
mode="${1:-}"
case "$mode" in
  ''|--package) ;;
  *) printf '%s\n' 'usage: scripts/test-ios.sh [--package]' >&2; exit 64 ;;
esac
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="${WOVENMATTER_IOS_TEST_CACHE_DIR:-${TMPDIR:-/tmp}/wovenmatter-ios-tests}"
mkdir -p "$cache"

swift test --package-path "$root/ios" --scratch-path "$cache/package" --disable-sandbox
[[ "$mode" == --package ]] && exit 0

destination="${WOVENMATTER_IOS_SIMULATOR_DESTINATION:-}"
owned=""
cleanup() { if [[ -n "$owned" ]]; then xcrun simctl delete "$owned" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT
if [[ -z "$destination" ]]; then
  # Never a simulator someone uses for a connected development app.
  owned="$(xcrun simctl create "Woven Matter Tests $$" "${WOVENMATTER_IOS_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}")"
  xcrun simctl boot "$owned"
  xcrun simctl bootstatus "$owned" -b
  destination="platform=iOS Simulator,id=$owned"
fi
xcodebuild -onlyUsePackageVersionsFromResolvedFile -project "$root/ios/WovenMatter.xcodeproj" -scheme WovenMatter -configuration Debug \
  -destination "$destination" -derivedDataPath "$cache/xcode" -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
