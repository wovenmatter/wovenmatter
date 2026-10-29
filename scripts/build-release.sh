#!/usr/bin/env bash
set -euo pipefail

usage='usage: build-release.sh VERSION [all|compile|seal|notarize-app|package|notarize-dmg|feed]'
[ "$#" -le 2 ] || { printf '%s\n' "$usage" >&2; exit 64; }
version="${1:?$usage}"
requested="${2-all}"
phases=(compile seal notarize-app package notarize-dmg feed)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { printf '%s\n' 'Version must be X.Y.Z.' >&2; exit 64; }
# Exactly one known phase name; anything else must never exit successfully.
case "$requested" in
  all|compile|seal|notarize-app|package|notarize-dmg|feed) ;;
  *) printf '%s\n' "$usage" >&2; exit 64 ;;
esac
[ "$(uname -s)" = Darwin ] \
  || { printf '%s\n' 'Production releases require macOS.' >&2; exit 69; }
[ "$(uname -m)" = arm64 ] \
  || { printf '%s\n' 'Production releases support Apple Silicon only.' >&2; exit 69; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
# Every phase repeats these source checks; phase state is bound to their result.
revision="$(git rev-parse HEAD)"
tag="v${version}"
if [ "${WOVENMATTER_RELEASE_ALLOW_UNTAGGED:-0}" != 1 ]; then
  [ "$(git describe --exact-match --tags HEAD 2>/dev/null || true)" = "$tag" ] \
    || { printf 'HEAD must have exact tag %s.\n' "$tag" >&2; exit 65; }
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] \
  || { printf '%s\n' 'Tracked release sources must be clean.' >&2; exit 65; }

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
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
derived_data="${release_root}/DerivedData"
package_cache="${WOVENMATTER_PACKAGE_CACHE:-${release_root}/SourcePackages}"
notary_app_zip="${release_root}/WovenMatter-${version}-notary.zip"
staging="${release_root}/dmg-root"
app="${derived_data}/Build/Products/Release/Woven Matter.app"
asset="WovenMatter_${version}_arm64.dmg"
dmg="${output_dir}/${asset}"
# One line binds the work directory to this source, the resolved output
# directory and the signing identity; completed phases follow it.
state="${release_root}/release-phases"
identity="${version} ${build_number} ${revision} ${output_dir} ${signing_identity}"
timings="${release_root}/release-timings.jsonl"

release_status() {
  local message="[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $1"
  printf '%s\n' "$message"
  if [ "${GITHUB_ACTIONS:-false}" = true ]; then
    printf '::notice title=Release stage::%s\n' "$message"
    printf '%s\n\n' "$message" >> "${GITHUB_STEP_SUMMARY:?}"
  fi
}

current_phase=''
phase_started=0
record_timing() {
  local result="$1" seconds=$((SECONDS - phase_started))
  local line
  line="$(printf '{"phase":"%s","result":"%s","seconds":%d,"finished":"%s","version":"%s","build":%d,"revision":"%s"}' \
    "$current_phase" "$result" "$seconds" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$version" "$build_number" "$revision")"
  if [ -d "$release_root" ]; then printf '%s\n' "$line" >> "$timings"; fi
  printf 'release-timing %s\n' "$line"
  release_status "Phase ${current_phase} ${result} after $((seconds / 60))m $((seconds % 60))s"
}
on_exit() {
  local status=$?
  if [ -n "$current_phase" ]; then
    # Exiting inside a phase is always a failure; some shells report an
    # expansion error such as a missing required variable as status 0 here.
    if [ "$status" -eq 0 ]; then status=1; fi
    # A partial phase is never resumed or built upon; only a fresh compile clears this.
    if [ -f "$state" ]; then printf 'failed %s\n' "$current_phase" >> "$state"; fi
    record_timing failed
  fi
  exit "$status"
}
trap on_exit EXIT

compile_release() {
  xcodebuild -quiet -showBuildTimingSummary -onlyUsePackageVersionsFromResolvedFile \
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
  "$@" \
  build
}

phase_compile() {
  team_id="${WOVENMATTER_TEAM_ID:?WOVENMATTER_TEAM_ID is required}"
  release_status 'Compiling production Release app'
  if [ -n "${WOVENMATTER_COMPILER_CACHE:-}" ]; then
    if ! compile_release COMPILATION_CACHE_ENABLE_CACHING=YES \
        COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES \
        "COMPILATION_CACHE_CAS_PATH=$WOVENMATTER_COMPILER_CACHE"; then
      # A cache/toolchain failure must never bypass a build or release check.
      # Retry once from fresh intermediates without compilation caching.
      release_status 'Cached compilation failed; retrying a clean uncached build'
      rm -rf "$derived_data"
      compile_release COMPILATION_CACHE_ENABLE_CACHING=NO
    fi
  else
    compile_release COMPILATION_CACHE_ENABLE_CACHING=NO
  fi
}

phase_seal() {
  release_status 'Signing nested updater helpers and sealing the app'
  scripts/sign-release-updater.sh "$app" "$signing_identity"
  release_status 'Validating bundled resources and code signatures'
  python3 scripts/validate-release-metadata.py verify "$version" "$build_number" "$revision" \
    --plist "$app/Contents/Info.plist"
  scripts/validate-native-app.sh "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  python3 scripts/validate-release-code.py "$app"
}

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

phase_notarize_app() {
  rm -f "$notary_app_zip"
  ditto -c -k --keepParent "$app" "$notary_app_zip"
  release_status 'Submitting app to Apple; waiting for notarization'
  notarize "$notary_app_zip"
  release_status 'App accepted; stapling and assessing app'
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
}

phase_package() {
  release_status 'Creating and signing disk image'
  rm -rf "$staging"
  mkdir -p "$staging"
  ditto "$app" "$staging/Woven Matter.app"
  ln -s /Applications "$staging/Applications"
  rm -f "$dmg"
  scripts/create-release-dmg.sh "$staging" "$dmg"
  codesign --force --timestamp --sign "$signing_identity" "$dmg"
  codesign --verify --verbose=2 "$dmg"
}

phase_notarize_dmg() {
  release_status 'Submitting disk image to Apple; waiting for notarization'
  notarize "$dmg"
  release_status 'Disk image accepted; stapling and assessing image'
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
}

phase_feed() {
  release_status 'Generating updater manifest and checksums'
  scripts/generate-release-manifest.sh \
    "$version" "$build_number" "$dmg" "$output_dir/latest-mac.json"
  release_status 'Generating signed full-only update feed'
  scripts/generate-update-feed.sh "$version" "$build_number" "$dmg" "$output_dir"
  release_status 'Distribution artifacts ready'
  printf 'Release artifacts ready in %s\n' "$output_dir"
}

run_phase() {
  local name="$1" previous="$2"
  if [ "$name" = compile ]; then
    # A clean build always starts from fresh intermediates.
    rm -rf "$release_root"
    mkdir -p "$derived_data" "$package_cache" "$output_dir"
    printf '%s\n' "$identity" > "$state"
  else
    # Later phases consume only the work of the immediately preceding phase,
    # completed in this work directory for this exact version, build and source.
    if [ ! -f "$state" ] || [ "$(head -n 1 "$state")" != "$identity" ] \
      || [ "$(tail -n 1 "$state")" != "$previous" ]; then
      printf 'Release phase %s requires completed phase %s for %s.\n' "$name" "$previous" "$identity" >&2
      exit 65
    fi
  fi
  current_phase="$name"
  phase_started=$SECONDS
  "phase_${name//-/_}"
  printf '%s\n' "$name" >> "$state"
  record_timing ok
  current_phase=''
}

previous=''
for name in "${phases[@]}"; do
  if [ "$requested" = all ] || [ "$requested" = "$name" ]; then
    run_phase "$name" "$previous"
  fi
  previous="$name"
done
