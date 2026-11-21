#!/usr/bin/env bash
# Builds the iPhone and iPad app for the simulator; --device-compile builds it
# for devices without signing.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${WOVENMATTER_IOS_BUILD_DIR:-${TMPDIR:-/tmp}/wovenmatter-ios-build}"
destination="generic/platform=iOS Simulator"
case "${1:-}" in
  '') ;;
  --device-compile) destination="generic/platform=iOS" ;;
  *) printf '%s\n' 'usage: scripts/build-ios.sh [--device-compile]' >&2; exit 64 ;;
esac
xcodebuild -onlyUsePackageVersionsFromResolvedFile -project "$root/ios/WovenMatter.xcodeproj" -scheme WovenMatter \
  -configuration Debug -destination "$destination" -derivedDataPath "$build_dir" \
  CODE_SIGNING_ALLOWED=NO build
