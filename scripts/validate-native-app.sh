#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: validate-native-app.sh /path/to/Woven Matter.app}"
info_plist="${app}/Contents/Info.plist"
test -f "$info_plist"
executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
main_executable="${app}/Contents/MacOS/${executable_name}"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
test -x "$main_executable"
case "$bundle_id" in
  wovenmatter.desktop|wovenmatter.desktop.dev) ;;
  *) printf 'Unexpected bundle identifier: %s\n' "$bundle_id" >&2; exit 1 ;;
esac
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$info_plist")" = true
test ! -e "${app}/Contents/Library/LaunchAgents"
test ! -e "${app}/Contents/MacOS/WovenMatterLocalService"

resources="${app}/Contents/Resources"
test -f "${resources}/harnesses/catalog.json"
test -x "${resources}/harnesses/initialize-workspace.sh"
test -f "${resources}/remote/Dockerfile"
test -f "${resources}/remote/entrypoint.sh"
test -f "${resources}/remote/package.json"
test -f "${resources}/remote/src/server.mjs"
test ! -e "${resources}/catalog.json"
test ! -e "${resources}/initialize-workspace.sh"
test ! -e "${resources}/remote/test"
test ! -e "${resources}/remote/.env.example"
test ! -e "${resources}/remote/compose.yaml"

if nm -j "$main_executable" | grep -Eq \
  'MacPlatform|IsolatedAgent|ServerAgent|WovenMatterLocalService|Containerization'; then
  printf '%s\n' 'Removed runtime architecture symbols found in the app executable.' >&2
  exit 1
fi

printf '%s\n' 'Native app validation passed.'
