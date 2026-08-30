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
  DEVELOPMENT_TEAM="$team_id" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  WOVENMATTER_SOURCE_REVISION="$revision" \
  build

scripts/validate-native-app.sh "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dvv "$app" 2>&1 | grep -F 'Authority=Developer ID Application:' >/dev/null

notarize() {
  local artifact="$1"
  if [ -n "${WOVENMATTER_NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$WOVENMATTER_NOTARY_KEYCHAIN_PROFILE" --wait
  else
    : "${WOVENMATTER_NOTARY_KEY:?WOVENMATTER_NOTARY_KEY is required}"
    : "${WOVENMATTER_NOTARY_KEY_ID:?WOVENMATTER_NOTARY_KEY_ID is required}"
    : "${WOVENMATTER_NOTARY_ISSUER_ID:?WOVENMATTER_NOTARY_ISSUER_ID is required}"
    xcrun notarytool submit "$artifact" \
      --key "$WOVENMATTER_NOTARY_KEY" \
      --key-id "$WOVENMATTER_NOTARY_KEY_ID" \
      --issuer "$WOVENMATTER_NOTARY_ISSUER_ID" \
      --wait
  fi
}

ditto -c -k --keepParent "$app" "$notary_app_zip"
notarize "$notary_app_zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

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
notarize "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

scripts/generate-release-manifest.sh \
  "$version" "$build_number" "$dmg" "$output_dir/latest-mac.json"
(
  cd "$output_dir"
  shasum -a 256 "$asset" latest-mac.json > SHA256SUMS.txt
)
printf 'Release artifacts ready in %s\n' "$output_dir"
