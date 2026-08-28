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
app="${derived_data}/Build/Products/Debug/Woven Matter Dev.app"
executable="${app}/Contents/MacOS/Woven Matter Dev"

mkdir -p "$derived_data" "$package_cache"
xcodebuild -quiet \
  -project "${app_root}/WovenMatter.xcodeproj" \
  -scheme WovenMatter \
  -configuration Debug \
  -destination "platform=macOS,arch=${host_arch}" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$package_cache" \
  CODE_SIGNING_ALLOWED=NO \
  build
test -x "$executable"

stop_dev_app() {
  pkill -TERM -x "Woven Matter Dev" >/dev/null 2>&1 || true
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
    /usr/bin/log stream --info --style compact --predicate 'process == "Woven Matter Dev"'
    ;;
  verify)
    launch_app
    sleep 1
    pgrep -x "Woven Matter Dev" >/dev/null
    stop_dev_app
    ;;
esac
