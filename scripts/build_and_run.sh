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
build_overrides=()
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
# Bash 3.2 treats an empty array as unset under nounset; preserve each override
# as one argument while expanding to no arguments for the default dev build.
xcodebuild -quiet \
  -project "${app_root}/WovenMatter.xcodeproj" \
  -scheme WovenMatter \
  -configuration Debug \
  -destination "platform=macOS,arch=${host_arch}" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$package_cache" \
  CODE_SIGNING_ALLOWED=NO \
  ${build_overrides[@]+"${build_overrides[@]}"} \
  build
test -x "$executable"

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
