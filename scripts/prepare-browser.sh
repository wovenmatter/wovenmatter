#!/usr/bin/env bash
# Xcode build phase: pin, build, bundle and sign the embedded CEF runtime.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
architecture="${ARCHS:-$(uname -m)}"
case "$architecture" in arm64|x86_64) ;; *) echo 'CEF requires a single arm64 or x86_64 build.' >&2; exit 1 ;; esac
cmake="${WOVENMATTER_CMAKE:-$(command -v cmake || true)}"
if [ -z "$cmake" ]; then
  for candidate in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
    if [ -x "$candidate" ]; then cmake="$candidate"; break; fi
  done
fi
if [ ! -x "$cmake" ]; then echo 'Install CMake 3.21+ (brew install cmake), or set WOVENMATTER_CMAKE.' >&2; exit 1; fi
pin="$repo_root/app/Browser/cef-version.json"
version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$pin")"
platform="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archives"][sys.argv[2]]["platform"])' "$pin" "$architecture")"
expected="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archives"][sys.argv[2]]["sha1"])' "$pin" "$architecture")"
cache="${WOVENMATTER_CEF_CACHE_DIR:-$HOME/Library/Caches/WovenMatter/CEF}"
name="cef_binary_${version}_${platform}_minimal"
mkdir -p "$cache"
# Distinct Xcode builds share immutable downloads; atomic directory rename
# prevents a partially extracted SDK becoming visible to another build.
if [ ! -f "$cache/$name/.verified" ]; then
  staging="$(mktemp -d "$cache/.download.XXXXXX")"
  trap 'rm -rf "$staging"' EXIT
  curl --fail --location --retry 3 --silent --show-error \
    "https://cef-builds.spotifycdn.com/$name.tar.bz2" -o "$staging/cef.tar.bz2"
  actual="$(shasum "$staging/cef.tar.bz2" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then echo 'CEF archive checksum mismatch.' >&2; exit 1; fi
  tar -xjf "$staging/cef.tar.bz2" -C "$staging"
  touch "$staging/$name/.verified"
  if [ ! -d "$cache/$name" ]; then
    mv "$staging/$name" "$cache/$name"
  elif [ ! -f "$cache/$name/.verified" ]; then
    echo "Unverified CEF cache exists at $cache/$name. Remove it and rebuild." >&2
    exit 1
  fi
  rm -rf "$staging"
  trap - EXIT
fi
sdk="$cache/$name"
build="${DERIVED_FILE_DIR:?}/cef-$architecture"
products="${BUILT_PRODUCTS_DIR:?}"
mkdir -p "$DERIVED_FILE_DIR" "$products"
"$cmake" -S "$repo_root/app/Browser" -B "$build" -G 'Unix Makefiles' \
  -DCEF_ROOT="$sdk" -DPROJECT_ARCH="$architecture" -DCMAKE_OSX_ARCHITECTURES="$architecture" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DUSE_SANDBOX=ON > "$build-config.log"
"$cmake" --build "$build" --parallel 6 > "$build-build.log" 2>&1 || { tail -100 "$build-build.log"; exit 1; }
cp "$build/libWovenBrowser.a" "$products/libWovenBrowser.a"
cp "$build/libcef_dll_wrapper/libcef_dll_wrapper.a" "$products/libcef_dll_wrapper.a"
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
frameworks="$app/Contents/Frameworks"
mkdir -p "$frameworks" "$app/Contents/Resources/BrowserLicenses"
framework="$frameworks/Chromium Embedded Framework.framework"
# CEF ships a flat framework. Swift/Xcode framework validation expects the
# standard macOS versioned bundle; keep all links within the signed bundle.
if [ -d "$framework" ] && [ ! -d "$framework/Versions" ]; then rm -rf "$framework"; fi
mkdir -p "$framework/Versions/A"
rsync -a --delete "$sdk/Release/Chromium Embedded Framework.framework/" "$framework/Versions/A/"
ln -sfn A "$framework/Versions/Current"
for member in 'Chromium Embedded Framework' Libraries Resources; do
  ln -sfn "Versions/Current/$member" "$framework/$member"
done
cp "$sdk/LICENSE.txt" "$sdk/CREDITS.html" "$app/Contents/Resources/BrowserLicenses/"
identity=-
if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ]; then identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"; fi
sign=(--force --sign "$identity" --options runtime)
if [ "${CONFIGURATION:-Debug}" = Release ] && [ "$identity" != - ]; then sign+=(--timestamp); else sign+=(--timestamp=none); fi
# Sign nested framework libraries first. Do not use --deep to hide omissions.
while IFS= read -r -d '' library; do codesign "${sign[@]}" "$library"; done < <(find "$frameworks/Chromium Embedded Framework.framework" -type f -name '*.dylib' -print0)
codesign "${sign[@]}" "$frameworks/Chromium Embedded Framework.framework"
for suffix in '' ' (GPU)' ' (Renderer)' ' (Plugin)' ' (Alerts)'; do
  helper="${PRODUCT_NAME} Helper${suffix}"
  bundle="$frameworks/$helper.app"
  mkdir -p "$bundle/Contents/MacOS"
  cp "$build/WovenBrowserHelper" "$bundle/Contents/MacOS/$helper"
  python3 - "$bundle/Contents/Info.plist" "$helper" "$PRODUCT_BUNDLE_IDENTIFIER" "$suffix" <<'PLIST'
import plistlib, sys
path, name, identifier, suffix = sys.argv[1:]
role = suffix.strip(' ()').lower() or 'default'
with open(path, 'wb') as out:
    plistlib.dump(dict(CFBundleExecutable=name, CFBundleName=name,
        CFBundleIdentifier=identifier+'.browser-helper.'+role, CFBundlePackageType='APPL',
        CFBundleVersion='1', LSUIElement=True, NSHighResolutionCapable=True), out)
PLIST
  codesign "${sign[@]}" --entitlements "$repo_root/app/Browser/Helper.entitlements" "$bundle"
done
