#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${WOVENMATTER_IOS_BUILD_DIR:-${TMPDIR:-/tmp}/wovenmatter-ios-build}"
destination="generic/platform=iOS Simulator"
signing=(CODE_SIGNING_ALLOWED=NO)
if [[ "${1:-}" == "--device" ]]; then
  : "${WOVENMATTER_IOS_DEVICE_ID:?Set WOVENMATTER_IOS_DEVICE_ID to the registered test iPhone identifier}"
  destination="platform=iOS,id=$WOVENMATTER_IOS_DEVICE_ID"
  signing=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
fi
xcodebuild -project "$root/ios/WovenMatterCompanion.xcodeproj" -scheme WovenMatterCompanion \
  -configuration Debug -destination "$destination" -derivedDataPath "$build_dir" \
  "${signing[@]}" build
