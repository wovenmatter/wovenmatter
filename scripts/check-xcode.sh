#!/usr/bin/env bash
# Fails unless the active Xcode is the one recorded in app/xcode-version.json,
# the toolchain the app is developed and released with. Desktop validation,
# release and release-cache jobs run it before building, so a runner image that
# changes or drops that Xcode stops the job instead of building with another one.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
record="$root/app/xcode-version.json"
field() { sed -n "s/^ *\"$1\": *\"\([^\"]*\)\",\{0,1\}$/\1/p" "$record"; }
version="$(field xcodeVersion)"; build="$(field xcodeBuild)"; directory="$(field developerDir)"
[ -n "$version" ] && [ -n "$build" ] && [ -n "$directory" ] || { echo "Invalid $record" >&2; exit 1; }

if [ -n "${GITHUB_ACTIONS:-}" ] && [ "${DEVELOPER_DIR:-}" != "$directory" ]; then
  echo "::error::DEVELOPER_DIR is '${DEVELOPER_DIR:-unset}'; app/xcode-version.json records $directory." >&2
  exit 1
fi
actual="$(xcodebuild -version 2>&1)" || { printf '%s\n' "$actual" >&2; echo "::error::Xcode $version ($build) is not available on this machine." >&2; exit 1; }
printf '%s\n' "$actual"
if [ "$(printf '%s\n' "$actual" | sed -n 1p)" != "Xcode $version" ] \
   || [ "$(printf '%s\n' "$actual" | sed -n 2p)" != "Build version $build" ]; then
  echo "::error::Expected Xcode $version ($build) from app/xcode-version.json. Update the runner or the record in a maintenance PR." >&2
  exit 1
fi
