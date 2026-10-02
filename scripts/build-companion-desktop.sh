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
protected = [home / "Library/Application Support/Woven Matter", home / "Library/Application Support/Woven Matter Dev", home / ".woven-matter"]
if workspace in [pathlib.Path("/"), home] or any(workspace == p.resolve() or p.resolve() in workspace.parents for p in protected):
    sys.exit("Refusing a shared, production, or home workspace.")
print(workspace)
PY
)"
mkdir -p "$cache_root" "$workspace"
# Pin the certificate in this isolated cache so rebuilding the test app keeps
# its Keychain identity. A missing certificate must fail, never downgrade it.
identity_file="${cache_root}/signing-identity"
sign_identity="${WOVENMATTER_COMPANION_SIGN_IDENTITY:-}"
if [ -z "$sign_identity" ] && [ -f "$identity_file" ]; then
  sign_identity="$(cat "$identity_file")"
fi
if [ -z "$sign_identity" ]; then
  development_identities="$(security find-identity -p codesigning -v | sed -nE '/"Apple Development:/s/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]{40}) .*/\1/p')"
  identity_count="$(printf '%s\n' "$development_identities" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "$identity_count" in
    1) sign_identity="$development_identities" ;;
    0) printf '%s\n' 'No Apple Development identity is available for the companion test app.' >&2; exit 65 ;;
    *) printf '%s\n' 'Multiple Apple Development identities are available. Set WOVENMATTER_COMPANION_SIGN_IDENTITY to the intended certificate fingerprint.' >&2; exit 65 ;;
  esac
fi
if [ "$sign_identity" = - ]; then
  printf '%s\n' 'The companion test app requires an Apple Development certificate.' >&2
  exit 65
fi
xcodebuild -quiet -project "${repo_root}/app/WovenMatter.xcodeproj" \
  -scheme WovenMatter -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "${cache_root}/DerivedData" \
  WOVENMATTER_DEV_PRODUCT_NAME="Woven Matter Companion Test" WOVENMATTER_DEV_BUNDLE_ID=com.wovenmatter.macos.companion-test \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=$sign_identity" OTHER_CODE_SIGN_FLAGS=--timestamp=none build
app="${cache_root}/DerivedData/Build/Products/Debug/Woven Matter Companion Test.app"
test -x "${app}/Contents/MacOS/Woven Matter Companion Test"
codesign --verify --deep --strict "$app"
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ "$team" != 3M84Q9NAMN ]; then
  printf 'The test app must be signed by Apple team 3M84Q9NAMN.\n' >&2
  exit 1
fi
printf '%s\n' "$sign_identity" > "$identity_file"
printf '%s\n' "$app"
if [ "$mode" = run ]; then
  /usr/bin/open -n "$app" --args --companion-test-workspace "$workspace"
fi
