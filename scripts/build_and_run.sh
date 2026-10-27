#!/usr/bin/env bash
set -euo pipefail

# Parse the entire launcher before building: edits made during a long build must
# not change the commands Bash reads when it resumes after xcodebuild.
run_development_build() {

mode=run
data_mode="${WOVENMATTER_DEV_MODE:-auto}"
instance="${WOVENMATTER_DEV_INSTANCE:-${WOVENMATTER_DEV_VARIANT:-}}"
source_directory="${WOVENMATTER_DEV_SNAPSHOT_SOURCE:-$HOME/Library/Application Support/Woven Matter}"
plan_only=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    run|debug|logs|verify) mode="$1"; shift ;;
    --debug|--logs|--verify) mode="${1#--}"; shift ;;
    --mode|--instance|--source)
      [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$1" >&2; exit 64; }
      case "$1" in --mode) data_mode="$2" ;; --instance) instance="$2" ;; --source) source_directory="$2" ;; esac
      shift 2 ;;
    --plan) plan_only=true; shift ;;
    --help|-h)
      printf '%s\n' 'usage: scripts/build_and_run.sh [run|debug|logs|verify] [--mode auto|client|snapshot|live] [--instance name] [--source directory] [--plan]'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done
case "$mode" in
  run|debug|logs|verify) ;;
  *) printf 'usage: %s [run|debug|logs|verify]\n' "$0" >&2; exit 64 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_root="${repo_root}/app"
profile_args=(profile --root "$repo_root" --mode "$data_mode")
if [ -n "$instance" ]; then profile_args+=(--instance "$instance"); fi
profile="$(python3 "$repo_root/scripts/dev-build.py" "${profile_args[@]}")"
if "$plan_only"; then printf '%s\n' "$profile"; exit 0; fi
instance="$(printf '%s' "$profile" | python3 -c 'import json,sys; print(json.load(sys.stdin)["instance"])')"
data_mode="$(printf '%s' "$profile" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mode"])')"
support_directory="$(printf '%s' "$profile" | python3 -c 'import json,sys; print(json.load(sys.stdin)["support"])')"
cache_base="${WOVENMATTER_DEV_CACHE_DIR:-/private/tmp/wovenmatter-development}"
cache_root="$cache_base/$instance/$data_mode"
derived_data="${cache_root}/DerivedData"
package_cache="${cache_root}/SourcePackages"
host_arch="$(uname -m)"
product_name="Woven Matter $instance $data_mode Dev"
build_overrides=(CODE_SIGNING_ALLOWED=NO "WOVENMATTER_DEV_PRODUCT_NAME=$product_name"
  "WOVENMATTER_DEV_BUNDLE_ID=wovenmatter.desktop.dev.$instance.$data_mode"
  "WOVENMATTER_DEV_MODE=$data_mode" "WOVENMATTER_DEV_INSTANCE=$instance")
app="${derived_data}/Build/Products/Debug/${product_name}.app"
executable="${app}/Contents/MacOS/${product_name}"
printf 'Development instance: %s\nData mode: %s\nLocal storage: %s\n' "$instance" "$data_mode" "$support_directory"
if [ "$data_mode" = live ]; then
  printf '%s\n' 'Live host: uses production data directly. Stop the current host (including background execution) before launching; the app enforces exclusive ownership.'
fi
mkdir -p "$derived_data" "$package_cache"
# Serialize both snapshot creation and builds of this exact profile.
build_lock="$cache_root/build.lock"
if ! mkdir "$build_lock" 2>/dev/null; then
  printf 'This instance is already building. If no launcher is running, remove %s.\n' "$build_lock" >&2; exit 75
fi
trap 'rmdir "$build_lock" 2>/dev/null || true' EXIT
if [ "$data_mode" = snapshot ] && [ ! -e "$support_directory" ]; then
  python3 "$repo_root/scripts/dev-build.py" snapshot --source "$source_directory" --destination "$support_directory"
fi
if [ "$data_mode" = snapshot ] && [ ! -f "$support_directory/development-snapshot.json" ]; then
  printf '%s\n' 'This snapshot is not initialized. Use a new instance name.' >&2; exit 65
fi

# Replacing the executable of an active execution owner can interrupt sessions.
# Its lifetime is independent of the UI; stop it from Background Server settings
# before rebuilding so active work uses the normal cancellation path.
backend_running="$(python3 "$repo_root/scripts/dev-build.py" backend-running --executable "$executable")"
if [ "$backend_running" = true ]; then
  printf '%s\n' 'Stop the server in this Dev app’s Background Server settings before rebuilding.' >&2
  exit 75
fi

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
stop_dev_app() {
  swift "$repo_root/scripts/stop-development.swift" "$executable"
}
# Stop before overwriting the executable, and respect graceful termination.
stop_dev_app
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
if [ -n "$signing_identity" ] && [ "$signing_identity" != - ]; then
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
  run) launch_app ;;
  debug) stop_dev_app; lldb -- "$executable" ;;
  logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$product_name\""
    ;;
  verify)
    launch_app
    # Leave the verified app open for interactive testing.
    ;;
esac

}

run_development_build "$@"
