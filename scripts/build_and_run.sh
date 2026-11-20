#!/usr/bin/env bash
set -euo pipefail

# Builds the app and starts it as a development instance with its own bundle
# identifier and its own data folder. It never reads or changes the data of an
# installed app.
#
# Parse the entire launcher before building: edits made during a long build must
# not change the commands Bash reads when it resumes after xcodebuild.
run_development_build() {

mode=run
instance="${WOVENMATTER_DEV_INSTANCE:-}"
plan_only=false
tailnet_port=
while [ "$#" -gt 0 ]; do
  case "$1" in
    run|debug|logs|verify) mode="$1"; shift ;;
    --debug|--logs|--verify) mode="${1#--}"; shift ;;
    --instance)
      [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$1" >&2; exit 64; }
      instance="$2"; shift 2 ;;
    --plan) plan_only=true; shift ;;
    --port)
      [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$1" >&2; exit 64; }
      tailnet_port="$2"; shift 2 ;;
    --help|-h)
      printf '%s\n' 'usage: scripts/build_and_run.sh [run|debug|logs|verify] --instance name [--port PORT] [--plan]'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_root="${repo_root}/app"
profile="$(python3 "$repo_root/scripts/dev-build.py" --instance "$instance")"
if "$plan_only"; then printf '%s\n' "$profile"; exit 0; fi
field() { printf '%s' "$profile" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
bundle_id="$(field bundle)"
product_name="$(field product)"
support_directory="$(field support)"
# Not under /tmp: macOS marks apps in temporary folders "in-temp-dir" and leaves
# them out of bundle-ID lookups, so System Settings can't list a Dev app there and
# its Accessibility and Screen Recording prompts fail.
cache_base="${WOVENMATTER_DEV_CACHE_DIR:-$HOME/Library/Developer/Woven Matter Dev}"
cache_root="$cache_base/$instance"
derived_data="${cache_root}/DerivedData"
package_cache="${cache_root}/SourcePackages"
host_arch="$(uname -m)"
build_overrides=(CODE_SIGNING_ALLOWED=NO "WOVENMATTER_DEV_PRODUCT_NAME=$product_name"
  "WOVENMATTER_DEV_BUNDLE_ID=$bundle_id" "WOVENMATTER_DEV_INSTANCE=$instance")
app="${derived_data}/Build/Products/Debug/${product_name}.app"
executable="${app}/Contents/MacOS/${product_name}"
printf 'Development instance: %s\nBundle identifier: %s\nData folder: %s\n' "$instance" "$bundle_id" "$support_directory"
mkdir -p "$derived_data" "$package_cache"
# --port puts this instance's server on the tailnet on that port; without it, it stays off.
mkdir -p "$support_directory"
if [ -n "$tailnet_port" ]; then printf '%s\n' "$tailnet_port" > "$support_directory/tailnet-port"
else rm -f "$support_directory/tailnet-port"; fi
build_lock="$cache_root/build.lock"
if ! mkdir "$build_lock" 2>/dev/null; then
  printf 'This instance is already building. If no launcher is running, remove %s.\n' "$build_lock" >&2; exit 75
fi
trap 'rmdir "$build_lock" 2>/dev/null || true' EXIT

# A stable certificate-backed identity lets macOS recognize subsequent Dev
# builds. Linker/ad-hoc signatures change identity whenever the binary changes.
# Keep the selected certificate pinned in this build cache.
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
    0)
      if security find-identity -p codesigning | grep -q '"Apple Development:'; then
        printf '%s\n' 'An Apple Development certificate is installed but macOS does not trust it, usually because Apple'"'"'s WWDR intermediate certificate (G3 or later) is missing. Install it from https://www.apple.com/certificateauthority/ and run this again.' >&2
      else
        printf '%s\n' 'No Apple Development certificate is installed. In Xcode: Settings > Apple Accounts > your account > your team > Manage Certificates > + > Apple Development. Then run this again.' >&2
      fi
      printf '%s\n' 'Without one, permissions reset on every rebuild. To build unsigned anyway, set WOVENMATTER_DEV_SIGNING_IDENTITY=-.' >&2
      exit 65 ;;
    *) printf '%s\n' 'Multiple Apple Development identities are available. Set WOVENMATTER_DEV_SIGNING_IDENTITY to the intended certificate fingerprint.' >&2; exit 65 ;;
  esac
fi
case "$signing_identity" in
  -) ;; # Explicit opt-out for a machine without signing credentials.
  *)
    build_overrides[0]=CODE_SIGNING_ALLOWED=YES
    build_overrides+=(CODE_SIGNING_REQUIRED=YES
      CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$signing_identity"
      OTHER_CODE_SIGN_FLAGS=--timestamp=none)
    ;;
esac
stop_dev_app() {
  swift "$repo_root/scripts/stop-development.swift" "$executable"
}
# Stop before overwriting the executable, and respect graceful termination.
stop_dev_app
# The instance's server is the same program: stop it too. The next launch starts it again.
launchctl bootout "gui/$(id -u)/${bundle_id}.server" 2>/dev/null || true
xcodebuild -quiet -onlyUsePackageVersionsFromResolvedFile \
  -project "${app_root}/WovenMatter.xcodeproj" \
  -scheme WovenMatter \
  -configuration Debug \
  -destination "platform=macOS,arch=${host_arch}" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$package_cache" \
  "${build_overrides[@]}" \
  build
test -x "$executable"
if [ "$signing_identity" != - ]; then
  codesign --verify --deep --strict "$app"
  printf '%s\n' "$signing_identity" > "$identity_file"
fi

launch_app() {
  /usr/bin/open -n "$app"
  if ! swift "$repo_root/scripts/stop-development.swift" "$executable" --wait; then
    printf 'Dev launch failed: %s\n' "$app" >&2
    printf 'Inspect startup errors with: /usr/bin/log show --last 2m --predicate %q\n' "process == \"$product_name\"" >&2
    return 1
  fi
  printf 'Dev app is running: %s\n' "$app"
}

case "$mode" in
  run|verify) launch_app ;;
  debug) stop_dev_app; lldb -- "$executable" ;;
  logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$product_name\""
    ;;
esac

}

run_development_build "$@"
