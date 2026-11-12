#!/usr/bin/env bash
# Fails unless the active Xcode is the one recorded in app/xcode-version.json,
# the toolchain the app is developed and released with. Desktop and mobile
# validation and release jobs run it before building, so an Xcode update on the
# owned Mac (or a changed xcode-select or DEVELOPER_DIR) stops the job instead of
# building with another toolchain. Move the record in a maintenance PR.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
record="$root/app/xcode-version.json"
field() { sed -n "s/^ *\"$1\": *\"\([^\"]*\)\",\{0,1\}$/\1/p" "$record"; }
version="$(field xcodeVersion)"; build="$(field xcodeBuild)"
[ -n "$version" ] && [ -n "$build" ] || { echo "Invalid $record" >&2; exit 1; }

actual="$(xcodebuild -version 2>&1)" || { printf '%s\n' "$actual" >&2; echo "::error::Xcode $version ($build) is not available on this machine." >&2; exit 1; }
printf '%s\n' "$actual"
if [ "$(printf '%s\n' "$actual" | sed -n 1p)" != "Xcode $version" ] \
   || [ "$(printf '%s\n' "$actual" | sed -n 2p)" != "Build version $build" ]; then
  echo "::error::Expected Xcode $version ($build) from app/xcode-version.json. Install it on this Mac (or select it with xcode-select), or move the record in a maintenance PR." >&2
  exit 1
fi
