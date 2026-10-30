#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${WOVENMATTER_IOS_BUILD_DIR:-${TMPDIR:-/tmp}/wovenmatter-ios-build}"
destination="generic/platform=iOS Simulator"
# Let Xcode embed simulated entitlements for Keychain access; no certificate is needed.
signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
if [[ "${1:-}" == "--device-compile" ]]; then
  destination="generic/platform=iOS"
  signing=(CODE_SIGNING_ALLOWED=NO)
elif [[ "${1:-}" == "--device" ]]; then
  : "${WOVENMATTER_IOS_DEVICE_ID:?Set WOVENMATTER_IOS_DEVICE_ID to the registered test iPhone or iPad identifier}"
  destination="platform=iOS,id=$WOVENMATTER_IOS_DEVICE_ID"
  signing=(CODE_SIGNING_ALLOWED=YES) # Use existing local signing assets; account setup is performed by the user.
fi
xcodebuild -project "$root/ios/WovenMatterCompanion.xcodeproj" -scheme WovenMatterCompanion \
  -configuration Debug -destination "$destination" -derivedDataPath "$build_dir" \
  "${signing[@]}" build
