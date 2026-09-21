#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
case "$mode" in
  run|debug|logs|verify) ;;
  *) printf 'usage: %s [run|debug|logs|verify]\n' "$0" >&2; exit 64 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_root="${repo_root}/app"
cache_root="${WOVENMATTER_DEV_CACHE_DIR:-/private/tmp/wovenmatter-development}"
derived_data="${cache_root}/DerivedData"
package_cache="${cache_root}/SourcePackages"
host_arch="$(uname -m)"
product_name="Woven Matter Dev"
build_overrides=(CODE_SIGNING_ALLOWED=NO)
variant="${WOVENMATTER_DEV_VARIANT:-}"
if [ -n "$variant" ]; then
  case "$variant" in *[!a-zA-Z0-9-]*) printf 'Invalid development variant\n' >&2; exit 64 ;; esac
  variant_id="$(printf '%s' "$variant" | tr '[:upper:]' '[:lower:]')"
  product_name="Woven Matter ${variant} Dev"
  build_overrides+=("WOVENMATTER_DEV_PRODUCT_NAME=$product_name" "WOVENMATTER_DEV_BUNDLE_ID=wovenmatter.desktop.dev.$variant_id")
fi
app="${derived_data}/Build/Products/Debug/${product_name}.app"
executable="${app}/Contents/MacOS/${product_name}"

mkdir -p "$derived_data" "$package_cache"
# A stable certificate-backed identity lets macOS recognize subsequent Dev
# builds. Linker/ad-hoc signatures change identity whenever the binary changes.
# Keep the selected certificate pinned in this build cache; never silently
# downgrade a previously signed build because a Keychain is inaccessible.
identity_file="${cache_root}/signing-identity"
signing_identity="${WOVENMATTER_DEV_SIGNING_IDENTITY:-}"
if [ -z "$signing_identity" ] && [ -f "$identity_file" ]; then
  signing_identity="$(cat "$identity_file")"
fi
if [ -z "$signing_identity" ]; then
  development_identities="$(security find-identity -p codesigning -v | sed -nE '/"Apple Development:/s/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]{40}) .*/\1/p')"
  identity_count="$(printf '%s\n' "$development_identities" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "$identity_count" in
    1) signing_identity="$development_identities" ;;
    0) printf '%s\n' 'No Apple Development identity is available; Dev will use ad-hoc signing. Keychain trust may not survive rebuilds.' >&2 ;;
    *) printf '%s\n' 'Multiple Apple Development identities are available. Set WOVENMATTER_DEV_SIGNING_IDENTITY to the intended certificate fingerprint.' >&2; exit 65 ;;
  esac
fi
if [ -n "$signing_identity" ]; then
  case "$signing_identity" in
    -) ;; # Explicit opt-out for a machine without signing credentials.
    *)
      build_overrides[0]=CODE_SIGNING_ALLOWED=YES
      build_overrides+=(CODE_SIGNING_REQUIRED=YES
        CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$signing_identity"
        OTHER_CODE_SIGN_FLAGS=--timestamp=none)
      ;;
  esac
fi
xcodebuild -quiet \
  -project "${app_root}/WovenMatter.xcodeproj" \
  -scheme WovenMatter \
  -configuration Debug \
  -destination "platform=macOS,arch=${host_arch}" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$package_cache" \
  "${build_overrides[@]}" \
  build
test -x "$executable"
if [ -n "$signing_identity" ] && [ "$signing_identity" != - ]; then
  codesign --verify --deep --strict "$app"
  printf '%s\n' "$signing_identity" > "$identity_file"
fi

stop_dev_app() {
  pkill -TERM -x "$product_name" >/dev/null 2>&1 || true
  # Launch Services can reject a relaunch while the old process is exiting.
  local attempt
  for attempt in {1..100}; do
    if ! pgrep -x "$product_name" >/dev/null; then return 0; fi
    sleep 0.1
  done
  printf 'The development app is still exiting; close it before relaunching.\n' >&2
  return 1
}

launch_app() {
  stop_dev_app
  /usr/bin/open -n "$app"
}

case "$mode" in
  run) launch_app ;;
  debug) stop_dev_app; lldb -- "$executable" ;;
  logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$product_name\""
    ;;
  verify)
    launch_app
    sleep 1
    pgrep -x "$product_name" >/dev/null
    stop_dev_app
    ;;
esac
