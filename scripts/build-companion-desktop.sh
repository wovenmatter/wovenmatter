#!/usr/bin/env bash
set -euo pipefail
# Builds a distinct development app and optionally opens one isolated workspace.
# It never quits production or other development apps and never shares their DB.
mode="${1:-build}"
case "$mode" in build|run) ;; *) printf 'usage: %s [build|run]\n' "$0" >&2; exit 64 ;; esac
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${WOVENMATTER_COMPANION_TEST_CACHE:-/private/tmp/wovenmatter-companion-test}"
workspace="${WOVENMATTER_COMPANION_TEST_WORKSPACE:-${HOME}/Library/Application Support/Woven Matter Companion Test}"
workspace="$(python3 - "$workspace" <<'PY'
import pathlib, sys
requested = pathlib.Path(sys.argv[1])
if not requested.is_absolute():
    sys.exit("Test workspace must be absolute.")
workspace = requested.resolve()
home = pathlib.Path.home().resolve()
protected = [home / "Library/Application Support/Woven Matter", home / ".woven-matter"]
if workspace in [pathlib.Path("/"), home] or any(workspace == p.resolve() or p.resolve() in workspace.parents for p in protected):
    sys.exit("Refusing a production or home workspace.")
print(workspace)
PY
)"
mkdir -p "$cache_root" "$workspace"
xcodebuild -quiet -project "${repo_root}/app/WovenMatter.xcodeproj" \
  -scheme WovenMatter -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "${cache_root}/DerivedData" \
  WOVENMATTER_APP_PRODUCT_NAME="Woven Matter Companion Test" WOVENMATTER_APP_BUNDLE_IDENTIFIER=com.wovenmatter.macos.companion-test \
  CODE_SIGNING_ALLOWED=NO build
app="${cache_root}/DerivedData/Build/Products/Debug/Woven Matter Companion Test.app"
test -x "${app}/Contents/MacOS/Woven Matter Companion Test"
# Existing Apple team; signing is for an isolated local development artifact.
sign_identity="${WOVENMATTER_COMPANION_SIGN_IDENTITY:-Apple Development}"
for library in "${app}/Contents/MacOS/"*.dylib; do
  [ -f "$library" ] || continue
  codesign --force --sign "$sign_identity" --options runtime "$library"
done
codesign --force --sign "$sign_identity" --options runtime "$app"
codesign --verify --deep --strict "$app"
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ "$team" != 3M84Q9NAMN ]; then
  printf 'The test app must be signed by Apple team 3M84Q9NAMN.\n' >&2
  exit 1
fi
printf '%s\n' "$app"
if [ "$mode" = run ]; then
  /usr/bin/open -n "$app" --args --companion-test-workspace "$workspace"
fi
