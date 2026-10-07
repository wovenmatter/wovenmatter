#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: build-release.sh VERSION}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { printf '%s\n' 'Version must be X.Y.Z.' >&2; exit 64; }
[ "$(uname -s)" = Darwin ] \
  || { printf '%s\n' 'Production releases require macOS.' >&2; exit 69; }
[ "$(uname -m)" = arm64 ] \
  || { printf '%s\n' 'Production releases support Apple Silicon only.' >&2; exit 69; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
revision="$(git rev-parse HEAD)"
tag="v${version}"
if [ "${WOVENMATTER_RELEASE_ALLOW_UNTAGGED:-0}" != 1 ]; then
  [ "$(git describe --exact-match --tags HEAD 2>/dev/null || true)" = "$tag" ] \
    || { printf 'HEAD must have exact tag %s.\n' "$tag" >&2; exit 65; }
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] \
  || { printf '%s\n' 'Tracked release sources must be clean.' >&2; exit 65; }

team_id="${WOVENMATTER_TEAM_ID:?WOVENMATTER_TEAM_ID is required}"
signing_identity="${WOVENMATTER_SIGNING_IDENTITY:-Developer ID Application}"
build_number="${WOVENMATTER_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] \
  || { printf '%s\n' 'WOVENMATTER_BUILD_NUMBER must be a positive integer.' >&2; exit 64; }

if ! security find-identity -p codesigning -v \
  | grep -F "Developer ID Application:" >/dev/null; then
  printf '%s\n' 'A Developer ID Application identity is required.' >&2
  exit 69
fi

release_root="${WOVENMATTER_RELEASE_WORK_DIR:-/private/tmp/wovenmatter-release-${version}}"
output_dir="${WOVENMATTER_RELEASE_OUTPUT_DIR:-${repo_root}/dist}"
derived_data="${release_root}/DerivedData"
package_cache="${release_root}/SourcePackages"
notary_app_zip="${release_root}/WovenMatter-${version}-notary.zip"
staging="${release_root}/dmg-root"
app="${derived_data}/Build/Products/Release/Woven Matter.app"
asset="WovenMatter_${version}_arm64.dmg"
dmg="${output_dir}/${asset}"

rm -rf "$release_root"
mkdir -p "$derived_data" "$package_cache" "$staging" "$output_dir"

release_status() {
  local message="[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $1"
  printf '%s\n' "$message"
  if [ "${GITHUB_ACTIONS:-false}" = true ]; then
    printf '::notice title=Release stage::%s\n' "$message"
    printf '%s\n' "$message" >> "${GITHUB_STEP_SUMMARY:?}"
  fi
}

release_status 'Compiling production Release app'
xcodebuild -quiet \
  -project app/WovenMatter.xcodeproj \
  -scheme WovenMatter \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$package_cache" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$signing_identity" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  DEVELOPMENT_TEAM="$team_id" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  WOVENMATTER_SOURCE_REVISION="$revision" \
  build

release_status 'Validating bundled resources and code signatures'
scripts/validate-native-app.sh "$app"
codesign --verify --deep --strict --verbose=2 "$app"
python3 scripts/validate-release-code.py "$app"

notarize() {
  local artifact="$1"
  local response
  response="$(mktemp "${release_root}/notary-response.XXXXXX")"
  local credentials=()
  if [ -n "${WOVENMATTER_NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    credentials=(--keychain-profile "$WOVENMATTER_NOTARY_KEYCHAIN_PROFILE")
  else
    : "${WOVENMATTER_NOTARY_KEY:?WOVENMATTER_NOTARY_KEY is required}"
    : "${WOVENMATTER_NOTARY_KEY_ID:?WOVENMATTER_NOTARY_KEY_ID is required}"
    : "${WOVENMATTER_NOTARY_ISSUER_ID:?WOVENMATTER_NOTARY_ISSUER_ID is required}"
    credentials=(--key "$WOVENMATTER_NOTARY_KEY"
      --key-id "$WOVENMATTER_NOTARY_KEY_ID"
      --issuer "$WOVENMATTER_NOTARY_ISSUER_ID")
  fi
  if ! xcrun notarytool submit "$artifact" "${credentials[@]}" --wait --output-format json > "$response"; then
    cat "$response"
    rm -f "$response"
    return 1
  fi
  cat "$response"
  if ! jq -e '.status == "Accepted"' "$response" >/dev/null; then
    local submission_id
    submission_id="$(jq -r '.id // empty' "$response")"
    if [ -n "$submission_id" ]; then
      xcrun notarytool log "$submission_id" "${credentials[@]}" || true
    fi
    rm -f "$response"
    printf 'Notarization did not accept %s; refusing to staple or package.\n' "$artifact" >&2
    return 65
  fi
  rm -f "$response"
}

ditto -c -k --keepParent "$app" "$notary_app_zip"
release_status 'Submitting app to Apple; waiting for notarization'
notarize "$notary_app_zip"
release_status 'App accepted; stapling and assessing app'
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

release_status 'Creating and signing disk image'
ditto "$app" "$staging/Woven Matter.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create \
  -volname 'Woven Matter' \
  -srcfolder "$staging" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$dmg"
codesign --force --timestamp --sign "$signing_identity" "$dmg"
codesign --verify --verbose=2 "$dmg"
release_status 'Submitting disk image to Apple; waiting for notarization'
notarize "$dmg"
release_status 'Disk image accepted; stapling and assessing image'
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

release_status 'Generating updater manifest and checksums'
scripts/generate-release-manifest.sh \
  "$version" "$build_number" "$dmg" "$output_dir/latest-mac.json"
(
  cd "$output_dir"
  shasum -a 256 "$asset" latest-mac.json > SHA256SUMS.txt
)
release_status 'Distribution artifacts ready'
printf 'Release artifacts ready in %s\n' "$output_dir"
