#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:---plan}" in
  --plan)
    printf '%s\n' 'iOS distribution plan (no build, upload, account setup, or publication)' \
      'Scheme: WovenMatterCompanion / Release' \
      'Product: Woven Matter / com.wovenmatter.companion' \
      'Development: Woven Matter Dev / com.wovenmatter.companion.dev' \
      'Signing: existing Apple team 3M84Q9NAMN assets only' \
      'Archive/export: explicit --archive NEW_OUTPUT_DIRECTORY' \
      'Before uploading: verify signing/App Store Connect access, export compliance, beta metadata, and physical iPhone acceptance.'
    ;;
  --archive)
    [[ $# == 2 && ! -e "$2" ]] || { printf '%s\n' 'Choose a new output directory; existing artifacts are never overwritten.' >&2; exit 64; }
    mkdir -p "$2"
    output="$(cd "$2" && pwd)"
    xcodebuild -project "$root/ios/WovenMatterCompanion.xcodeproj" -scheme WovenMatterCompanion \
      -configuration Release -destination 'generic/platform=iOS' -onlyUsePackageVersionsFromResolvedFile \
      -archivePath "$output/WovenMatter.xcarchive" archive
    "$root/scripts/verify-ios-app.sh" "$output/WovenMatter.xcarchive/Products/Applications/WovenMatterCompanion.app" distribution
    xcodebuild -exportArchive -archivePath "$output/WovenMatter.xcarchive" \
      -exportOptionsPlist "$root/ios/Config/ExportOptions.plist" -exportPath "$output/export"
    printf '%s\n' "Private archive/export prepared at $output. Nothing was uploaded or published."
    ;;
  *) printf '%s\n' 'usage: scripts/prepare-ios-testflight.sh [--plan|--archive NEW_OUTPUT_DIRECTORY]' >&2; exit 64 ;;
esac
