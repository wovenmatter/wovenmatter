#!/usr/bin/env bash
# TestFlight builds of the iPhone/iPad app. Steps and Apple setup: ios/README.md.
#
# Never signs in interactively, creates accounts or publishes. Only --upload
# sends a build to Apple, and only with an App Store Connect API key. Xcode may
# create or update signing profiles only when that key is supplied.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$root/ios/WovenMatter.xcodeproj"
export_options="$root/ios/Config/ExportOptions.plist"
verify="$root/scripts/verify-ios-app.sh"
scheme=WovenMatter
team=3M84Q9NAMN
product='Woven Matter / com.wovenmatter.wovenmatter'

usage() {
  printf '%s\n' 'usage: scripts/prepare-ios-testflight.sh --plan' \
    '       scripts/prepare-ios-testflight.sh --unsigned-build NEW_OUTPUT_DIRECTORY' \
    '       scripts/prepare-ios-testflight.sh --archive NEW_OUTPUT_DIRECTORY' \
    '       scripts/prepare-ios-testflight.sh --upload NEW_OUTPUT_DIRECTORY' \
    '       scripts/prepare-ios-testflight.sh --verify-export EXPORTED_IPA' >&2
  exit 64
}
fail() { local code="$1"; shift; printf '%s\n' "$@" >&2; exit "$code"; }
step() { printf '\n==> %s\n' "$*"; }

marketing_version() {
  local value
  value="$(sed -n 's/^ *MARKETING_VERSION: *//p' "$root/ios/project.yml" | head -n 1)"
  [[ -n "$value" ]] || fail 65 'Missing MARKETING_VERSION in ios/project.yml.'
  # The generated project must agree; regenerate with xcodegen rather than editing either by hand.
  if grep 'MARKETING_VERSION = ' "$project/project.pbxproj" | grep -qv "MARKETING_VERSION = $value;"; then
    fail 65 'MARKETING_VERSION differs between ios/project.yml and the Xcode project. Run xcodegen in ios/.'
  fi
  printf '%s' "$value"
}

# A unique, increasing build number for every archive, from the UTC clock:
# YYYYMMDD.T, where T = hour*10000 + minute*100 + second (no leading zeros).
# 2026-11-11 18:34:02 UTC -> 20261111.183402; 09:05:07 UTC -> 20261111.90507.
build_number() {
  local stamp
  stamp="$(date -u +%Y%m%d%H%M%S)"
  [[ "$stamp" =~ ^[0-9]{14}$ ]] || fail 70 'Could not read the UTC clock for the build number.'
  printf '%s.%d' "${stamp:0:8}" "$((10#${stamp:8:2} * 10000 + 10#${stamp:10:2} * 100 + 10#${stamp:12:2}))"
}

distribution_identities() {
  command -v security >/dev/null || { printf '0'; return; }
  { security find-identity -v -p codesigning 2>/dev/null || true; } |
    { grep -E '"(Apple|iPhone) Distribution: .*\('"$team"'\)"' || true; } | wc -l | tr -d ' '
}

# App Store Connect API key: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH, or the
# standard ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8. Values not set
# in the environment are read from ~/.appstoreconnect/woven-matter.env (or
# ASC_CONFIG): plain KEY=VALUE lines, parsed here and never sourced or executed.
config_path="${ASC_CONFIG:-${HOME:-~}/.appstoreconnect/woven-matter.env}"
config_value() {
  [[ -f "$config_path" && -r "$config_path" ]] || return 0
  local name value
  while IFS='=' read -r name value || [[ -n "$name" ]]; do
    if [[ "$name" == "$1" ]]; then
      value="${value%$'\r'}"; value="${value#\"}"; value="${value%\"}"
      printf '%s' "$value"
      return 0
    fi
  done < "$config_path"
}
key_id="${ASC_KEY_ID:-$(config_value ASC_KEY_ID)}"
issuer_id="${ASC_ISSUER_ID:-$(config_value ASC_ISSUER_ID)}"
key_path="${ASC_KEY_PATH:-$(config_value ASC_KEY_PATH)}"
if [[ -z "$key_path" && -n "$key_id" ]]; then
  key_path="${HOME:-~}/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
fi
key_problem() {
  if [[ -z "$key_id" && -z "$issuer_id" && -z "${ASC_KEY_PATH:-}" ]]; then
    printf 'not configured (set ASC_KEY_ID and ASC_ISSUER_ID, or save them in %s)' "$config_path"
  elif [[ ! "$key_id" =~ ^[A-Z0-9]{8,16}$ ]]; then
    printf 'ASC_KEY_ID is missing or is not an App Store Connect key ID'
  elif [[ ! "$issuer_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    printf 'ASC_ISSUER_ID is missing or is not an issuer ID'
  elif [[ ! -f "$key_path" || ! -r "$key_path" ]]; then
    printf 'no readable private key at %s' "$key_path"
  fi
}
# Empty unless an API key is in use. Expanded with ${x[@]+...} for bash 3.2 under set -u.
xcode_authentication=()
use_key() {
  xcode_authentication=(-allowProvisioningUpdates -authenticationKeyPath "$key_path"
    -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer_id")
}

require_identity() {
  [[ "$(distribution_identities)" -gt 0 ]] || fail 69 \
    "No Apple Distribution signing identity for team $team is in this Mac's keychain." \
    'Create the certificate and install it with its private key first: ios/README.md, "Apple Distribution certificate".' \
    'This script never creates certificates or signs in.'
}
require_key() {
  local problem
  problem="$(key_problem)"
  [[ -z "$problem" ]] || fail 69 "App Store Connect API key: $problem." \
    'Uploads use only an API key, never an interactive sign-in: ios/README.md, "App Store Connect API key".'
}
new_directory() {
  [[ -n "${1:-}" && ! -e "$1" ]] || fail 64 'Choose a new output directory; existing artifacts are never overwritten.'
  mkdir -p "$1"
  (cd "$1" && pwd)
}
# Runs a long Xcode step with its full log in the output directory.
logged() {
  local log="$1"; shift
  if ! "$@" >"$log" 2>&1; then
    printf '%s\n' "Failed. Last lines of $log:" >&2
    tail -n 40 "$log" >&2
    exit 1
  fi
}

archive_and_export() {
  local output="$1" build="$2" app ipas
  step "Archiving $product $version ($build)"
  logged "$output/archive.log" xcodebuild -project "$project" -scheme "$scheme" -configuration Release \
    -destination 'generic/platform=iOS' -onlyUsePackageVersionsFromResolvedFile \
    -archivePath "$output/WovenMatter.xcarchive" ${xcode_authentication[@]+"${xcode_authentication[@]}"} \
    CURRENT_PROJECT_VERSION="$build" archive
  app="$output/WovenMatter.xcarchive/Products/Applications/WovenMatter.app"
  "$verify" "$app" distribution --version "$version" --build "$build"
  step 'Exporting for App Store Connect'
  logged "$output/export.log" xcodebuild -exportArchive -archivePath "$output/WovenMatter.xcarchive" \
    -exportOptionsPlist "$export_options" -exportPath "$output/export" ${xcode_authentication[@]+"${xcode_authentication[@]}"}
  ipas=("$output"/export/*.ipa)
  [[ ${#ipas[@]} == 1 && -f "${ipas[0]}" ]] || fail 65 'Export did not produce exactly one IPA.'
  step 'Verifying the exported IPA'
  "$verify" --ipa "${ipas[0]}" --version "$version" --build "$build"
  ipa="${ipas[0]}"
}

version="$(marketing_version)"
case "${1:-}" in
  --plan)
    [[ $# == 1 ]] || usage
    problem="$(key_problem)"
    printf '%s\n' 'TestFlight plan (nothing is built, signed or uploaded)' \
      "  Product:        $product (Release)" \
      '  Dev builds:     Woven Matter Dev / com.wovenmatter.wovenmatter.dev (Debug)' \
      "  Version:        $version (MARKETING_VERSION in ios/project.yml)" \
      "  Build number:   stamped from the UTC clock at archive time; now it would be $(build_number)" \
      "  Team:           $team" \
      "  Distribution identities for $team in this keychain: $(distribution_identities)" \
      "  App Store Connect API key: ${problem:-ready ($key_id, $key_path)}" \
      '' \
      'Commands:' \
      '  --unsigned-build DIR  compile and verify an unsigned Release build (no signing assets needed)' \
      '  --archive DIR         archive, export and verify a signed IPA; uploads nothing' \
      '  --upload DIR          the same, then upload the verified IPA with the API key' \
      '  --verify-export IPA   verify an exported IPA' \
      'Each DIR must be new. Setup steps: ios/README.md, "TestFlight".'
    ;;
  --unsigned-build)
    [[ $# == 2 ]] || usage
    output="$(new_directory "$2")"
    step "Building unsigned $product $version for devices"
    logged "$output/build.log" xcodebuild -project "$project" -scheme "$scheme" -configuration Release \
      -destination 'generic/platform=iOS' -onlyUsePackageVersionsFromResolvedFile \
      -derivedDataPath "$output/DerivedData" CODE_SIGNING_ALLOWED=NO build
    step 'Verifying the Release bundle'
    "$verify" "$output/DerivedData/Build/Products/Release-iphoneos/WovenMatter.app" distribution --version "$version"
    printf '\n'; printf '%s\n' "Unsigned Release build verified in $output." \
      'It is not signed and cannot be installed or uploaded.'
    ;;
  --archive)
    [[ $# == 2 ]] || usage
    require_identity
    if [[ -z "$(key_problem)" ]]; then use_key; key_note="Xcode may create or update the App Store profile with API key $key_id."
    else key_note="App Store Connect API key: $(key_problem). Only signing profiles already on this Mac are used."; fi
    output="$(new_directory "$2")"
    build="$(build_number)"
    printf '%s\n' "Build number: $build" "$key_note"
    archive_and_export "$output" "$build"
    printf '\n'; printf '%s\n' "Woven Matter $version ($build) is ready at $ipa." 'Nothing was uploaded.'
    ;;
  --upload)
    [[ $# == 2 ]] || usage
    require_key
    require_identity
    output="$(new_directory "$2")"
    build="$(build_number)"
    use_key
    printf '%s\n' "Build number: $build" "API key: $key_id"
    archive_and_export "$output" "$build"
    step "Uploading Woven Matter $version ($build) to App Store Connect"
    # Upload only the IPA verified above. altool authenticates with the API key alone.
    if ! xcrun altool --upload-package "$ipa" --api-key "$key_id" --api-issuer "$issuer_id" \
        --p8-file-path "$key_path" --output-format normal 2>&1 | tee "$output/upload.log"; then
      fail 1 "Upload failed; see $output/upload.log. The verified IPA is kept at $ipa."
    fi
    printf '\n'; printf '%s\n' "Uploaded Woven Matter $version ($build)." \
      'App Store Connect processes it before it appears under TestFlight; Apple emails when it is ready.'
    ;;
  --verify-export)
    [[ $# == 2 ]] || usage
    "$verify" --ipa "$2" --version "$version"
    ;;
  *) usage ;;
esac
