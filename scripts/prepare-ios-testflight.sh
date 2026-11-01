#!/usr/bin/env bash
# Private TestFlight preparation. Nothing here uploads, publishes, signs in,
# changes accounts, or requests provisioning updates. See ios/README.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$root/ios/WovenMatterCompanion.xcodeproj"
team=3M84Q9NAMN
usage() {
  printf '%s\n' 'usage: scripts/prepare-ios-testflight.sh --plan' \
    '       scripts/prepare-ios-testflight.sh --unsigned-build NEW_OUTPUT_DIRECTORY' \
    '       scripts/prepare-ios-testflight.sh --archive NEW_OUTPUT_DIRECTORY --build-number NUMBER' \
    '       scripts/prepare-ios-testflight.sh --verify-export EXPORTED_IPA' >&2
  exit 64
}
setting() {
  local value
  value="$(sed -n "s/^ *$1: *//p" "$root/ios/project.yml" | head -n 1)"
  [[ -n "$value" ]] || { printf 'Missing %s in ios/project.yml\n' "$1" >&2; exit 65; }
  # The generated project must agree; regenerate with xcodegen rather than editing either by hand.
  if grep -q "$1 = " "$project/project.pbxproj" && grep "$1 = " "$project/project.pbxproj" | grep -qv "$1 = $value;"; then
    printf '%s differs between ios/project.yml and the Xcode project. Run xcodegen in ios/.\n' "$1" >&2; exit 65
  fi
  printf '%s' "$value"
}
new_directory() {
  [[ -n "${1:-}" && ! -e "$1" ]] || { printf '%s\n' 'Choose a new output directory; existing artifacts are never overwritten.' >&2; exit 64; }
  mkdir -p "$1"
  (cd "$1" && pwd)
}
distribution_identities() {
  command -v security >/dev/null || { printf '0'; return; }
  security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Apple|iPhone) Distribution: .*\('"$team"'\)"' | wc -l | tr -d ' '
}
version="$(setting MARKETING_VERSION)"
committed_build="$(setting CURRENT_PROJECT_VERSION)"
case "${1:-}" in
  --plan)
    [[ $# == 1 ]] || usage
    printf '%s\n' 'iOS distribution plan (no build, upload, account setup, or publication)' \
      'Scheme: WovenMatterCompanion / Release' \
      'Product: Woven Matter / com.wovenmatter.companion' \
      'Development: Woven Matter Dev / com.wovenmatter.companion.dev' \
      "Version: $version (CFBundleShortVersionString)" \
      "Committed build number: $committed_build. Pass --build-number above every build already uploaded for $version." \
      "Signing: existing Apple team $team assets only; automatic provisioning updates stay off." \
      "Apple Distribution identities for $team in this keychain: $(distribution_identities)" \
      'Compile check: --unsigned-build NEW_OUTPUT_DIRECTORY (unsigned device Release; proves compilation and packaged resources, not signing)' \
      'Archive/export: --archive NEW_OUTPUT_DIRECTORY --build-number NUMBER (export only; verifies the exported IPA)' \
      'Upload, App Store Connect metadata, export compliance and physical-device acceptance remain manual: see ios/README.md.'
    ;;
  --unsigned-build)
    [[ $# == 2 ]] || usage
    output="$(new_directory "$2")"
    xcodebuild -project "$project" -scheme WovenMatterCompanion -configuration Release \
      -destination 'generic/platform=iOS' -onlyUsePackageVersionsFromResolvedFile \
      -derivedDataPath "$output/DerivedData" CODE_SIGNING_ALLOWED=NO build
    "$root/scripts/verify-ios-app.sh" "$output/DerivedData/Build/Products/Release-iphoneos/WovenMatterCompanion.app" distribution
    printf '%s\n' "Unsigned Release build verified at $output. It is not signed and cannot be installed or uploaded."
    ;;
  --archive)
    [[ $# == 4 && "$3" == --build-number ]] || usage
    build="$4"
    [[ "$build" =~ ^[1-9][0-9]*(\.[0-9]+){0,2}$ ]] || { printf '%s\n' 'Use a build number of one to three period-separated integers, such as 19.' >&2; exit 64; }
    [[ "$(distribution_identities)" -gt 0 ]] || {
      printf '%s\n' "No Apple Distribution signing identity for team $team is installed in this keychain." \
        'Install it through your Apple Developer account first (see ios/README.md); this helper never signs in or creates certificates.' >&2
      exit 69
    }
    output="$(new_directory "$2")"
    xcodebuild -project "$project" -scheme WovenMatterCompanion -configuration Release \
      -destination 'generic/platform=iOS' -onlyUsePackageVersionsFromResolvedFile \
      -archivePath "$output/WovenMatter.xcarchive" CURRENT_PROJECT_VERSION="$build" archive
    "$root/scripts/verify-ios-app.sh" "$output/WovenMatter.xcarchive/Products/Applications/WovenMatterCompanion.app" distribution
    xcodebuild -exportArchive -archivePath "$output/WovenMatter.xcarchive" \
      -exportOptionsPlist "$root/ios/Config/ExportOptions.plist" -exportPath "$output/export"
    ipas=("$output"/export/*.ipa)
    [[ ${#ipas[@]} == 1 && -f "${ipas[0]}" ]] || { printf '%s\n' 'Export did not produce exactly one IPA.' >&2; exit 65; }
    "$root/scripts/verify-ios-app.sh" --ipa "${ipas[0]}"
    printf '%s\n' "Private export of Woven Matter $version ($build) verified at ${ipas[0]}. Nothing was uploaded or published."
    ;;
  --verify-export)
    [[ $# == 2 ]] || usage
    "$root/scripts/verify-ios-app.sh" --ipa "$2"
    ;;
  *) usage ;;
esac
