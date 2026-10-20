#!/usr/bin/env bash
set -euo pipefail
mode="${1:---package}"
case "$mode" in
  --package|--simulator|--ui|--all-devices) ;;
  *) printf '%s\n' 'usage: scripts/test-ios.sh [--package|--simulator|--ui|--all-devices]' >&2; exit 64 ;;
esac
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$mode" == "--all-devices" ]]; then
  "$root/scripts/test-ios.sh" --ui
  WOVENMATTER_IOS_SIMULATOR_DESTINATION="" \
    WOVENMATTER_IOS_SIMULATOR_DEVICE_TYPE="${WOVENMATTER_IOS_TABLET_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB}" \
    "$root/scripts/test-ios.sh" --ui
  exit 0
fi
cache="${WOVENMATTER_IOS_TEST_CACHE_DIR:-${TMPDIR:-/tmp}/wovenmatter-ios-tests}"
mkdir -p "$cache"
export CLANG_MODULE_CACHE_PATH="$cache/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache/modules"
swift test --package-path "$root/ios" --scratch-path "$cache/package" --disable-sandbox
if [[ "$mode" != "--package" ]]; then
  destination="${WOVENMATTER_IOS_SIMULATOR_DESTINATION:-}"
  owned_simulator=""
  simulator_pid=""
  results="$(mktemp -d "$cache/results.XXXXXX")"
  cleanup_simulator() {
    if [[ -n "$owned_simulator" ]]; then
      xcrun simctl shutdown "$owned_simulator" >/dev/null 2>&1 || true
      xcrun simctl delete "$owned_simulator" >/dev/null 2>&1 || true
    fi
    if [[ -n "$simulator_pid" ]]; then
      kill "$simulator_pid" >/dev/null 2>&1 || true
      wait "$simulator_pid" 2>/dev/null || true
    fi
  }
  trap cleanup_simulator EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ -z "$destination" ]]; then
    # Never run app-hosted tests in a paired development simulator by default.
    device_type="${WOVENMATTER_IOS_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
    create_arguments=(simctl create "Woven Matter Tests $$" "$device_type")
    if [[ -n "${WOVENMATTER_IOS_SIMULATOR_RUNTIME:-}" ]]; then
      create_arguments+=("$WOVENMATTER_IOS_SIMULATOR_RUNTIME")
    fi
    owned_simulator="$(xcrun "${create_arguments[@]}")"
    destination="platform=iOS Simulator,id=$owned_simulator"
    # Complete first-boot services before XCTest installs or launches its host.
    # Opening this disposable device gives UIKit a display before UI hit testing.
    xcrun simctl boot "$owned_simulator"
    xcrun simctl bootstatus "$owned_simulator" -b
    # Launch an owned process from the selected Xcode. `open --args` would
    # silently ignore the UDID when the user's Simulator is already running.
    simctl_path="$(xcrun --find simctl)"
    simulator_executable="${simctl_path%/usr/bin/simctl}/Applications/Simulator.app/Contents/MacOS/Simulator"
    if [[ -x "$simulator_executable" ]]; then
      "$simulator_executable" -CurrentDeviceUDID "$owned_simulator" >"$results/simulator.log" 2>&1 &
      simulator_pid=$!
    else
      # Xcode 27 replaces standalone Simulator with Device Hub. Let XCTest
      # manage its display on that toolchain; do not pass it unsupported args.
      printf 'No standalone Simulator in selected Xcode; testing the booted device through XCTest.\n'
    fi
  fi
  xcode_arguments=(-project "$root/ios/WovenMatterCompanion.xcodeproj" -scheme WovenMatterCompanion
    -configuration Debug -destination "$destination" -derivedDataPath "$cache/xcode"
    -destination-timeout 120 -parallel-testing-enabled NO
    -resultBundlePath "$results/TestResults.xcresult"
    -collect-test-diagnostics "${WOVENMATTER_IOS_TEST_DIAGNOSTICS:-never}")
  if [[ "$mode" == "--simulator" ]]; then xcode_arguments+=(-only-testing:CompanionAppTests); fi
  if [[ -n "${WOVENMATTER_IOS_TEST_ONLY:-}" ]]; then xcode_arguments+=("-only-testing:$WOVENMATTER_IOS_TEST_ONLY"); fi
  xcodebuild "${xcode_arguments[@]}" CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$results/xcodebuild.log"
fi
