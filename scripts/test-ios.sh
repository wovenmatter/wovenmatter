#!/usr/bin/env bash
set -euo pipefail
mode="${1:---package}"
case "$mode" in
  --package|--simulator|--ui) ;;
  *) printf '%s\n' 'usage: scripts/test-ios.sh [--package|--simulator|--ui]' >&2; exit 64 ;;
esac
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="${WOVENMATTER_IOS_TEST_CACHE_DIR:-${TMPDIR:-/tmp}/wovenmatter-ios-tests}"
mkdir -p "$cache"
export CLANG_MODULE_CACHE_PATH="$cache/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache/modules"
swift test --package-path "$root/ios" --scratch-path "$cache/package" --disable-sandbox
if [[ "$mode" != "--package" ]]; then
  destination="${WOVENMATTER_IOS_SIMULATOR_DESTINATION:-}"
  owned_simulator=""
  cleanup_simulator() {
    if [[ -n "$owned_simulator" ]]; then
      xcrun simctl shutdown "$owned_simulator" >/dev/null 2>&1 || true
      xcrun simctl delete "$owned_simulator" >/dev/null 2>&1 || true
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
  fi
  xcode_arguments=(-project "$root/ios/WovenMatterCompanion.xcodeproj" -scheme WovenMatterCompanion
    -configuration Debug -destination "$destination" -derivedDataPath "$cache/xcode"
    -destination-timeout 120 -parallel-testing-enabled NO)
  if [[ "$mode" == "--simulator" ]]; then xcode_arguments+=(-only-testing:CompanionAppTests); fi
  xcodebuild "${xcode_arguments[@]}" CODE_SIGNING_ALLOWED=NO test
fi
