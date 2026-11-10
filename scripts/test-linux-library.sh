#!/usr/bin/env bash
# Builds the portable Swift targets for Linux and runs their tests in the pinned
# toolchain image (remote/library/build-version.json). With Docker this runs on
# any host; inside that image (CI) it runs directly. Tests use the distribution's
# SQLite; the shipped binary links the pinned amalgamation (build-linux-library.sh).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
record="$root/remote/library/build-version.json"
field() { sed -n "s/^ *\"$1\": *\"\([^\"]*\)\",\{0,1\}$/\1/p" "$record"; }
swift_version="$(field swiftVersion)"; image="$(field swiftImage)"
cache="${WOVENMATTER_LINUX_TEST_CACHE:-${WOVENMATTER_TEST_CACHE_DIR:-${TMPDIR:-/tmp}/wovenmatter-validation}/Linux}"

if ! { [ "$(uname -s)" = Linux ] && command -v swift >/dev/null && swift --version 2>/dev/null | grep -q "Swift version $swift_version "; }; then
  command -v docker >/dev/null || { echo "Docker or Swift $swift_version on Linux is required." >&2; exit 1; }
  mkdir -p "$cache"
  exec docker run --rm -v "$root:/src:ro" -v "$(cd "$cache" && pwd -P):/cache" -e WOVENMATTER_LINUX_TEST_CACHE=/cache \
    "$image" /src/scripts/test-linux-library.sh
fi

if ! { [ -f /usr/include/sqlite3.h ] || pkg-config --exists sqlite3 2>/dev/null; }; then
  if [ "$(id -u)" = 0 ]; then apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null
  else echo 'Install the SQLite development package (libsqlite3-dev).' >&2; exit 1; fi
fi

# SwiftPM may write package state beside a manifest; test a private copy.
work="$cache/src"
rm -rf "$work"; mkdir -p "$work"
cp -R "$root/app" "$root/shared" "$root/ios" "$root/harnesses" "$work/"
# Client tests compare the Mac session helpers with the Linux host's copies.
mkdir -p "$work/remote/host" && cp -R "$root/remote/host/session-tools" "$work/remote/host/"
# The shared tests check that the Node server's bundled Woven MCP catalog matches Swift's.
mkdir -p "$work/remote/src" && cp "$root/remote/src/woven-mcp-tools.json" "$work/remote/src/"
rm -rf "$work/app/.build" "$work/shared/.build" "$work/ios/.build"

# Darwin pipes never raise SIGPIPE; Linux hosts ignore it process-wide
# (PortablePOSIX.ignoreBrokenPipes), and test runners inherit the same.
trap '' PIPE
swift test --package-path "$work/shared" --scratch-path "$cache/shared"
swift build --package-path "$work/app" --scratch-path "$cache/app" --force-resolved-versions --build-tests
swift test --package-path "$work/app" --scratch-path "$cache/app" --force-resolved-versions --skip-build
echo 'Linux library tests passed.'
