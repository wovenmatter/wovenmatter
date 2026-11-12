#!/usr/bin/env bash
# Prints the persistent cache locations a job on an owned runner uses, for
# "$GITHUB_ENV". Each purpose has its own root, apart from the caches of the
# user's own dev builds: validation of any branch never writes a cache that a
# release build reads, and release caches are written only by release builds of
# accepted main source. Every consumer still verifies what it takes from them.
set -euo pipefail
purpose="${1:-}"
case "$purpose" in validation|release) ;; *) echo 'usage: cache-env.sh validation|release' >&2; exit 64 ;; esac
if [ "$(uname -s)" = Darwin ]; then
  base="$HOME/Library/Caches/WovenMatterCI"
else
  base="${XDG_CACHE_HOME:-$HOME/.cache}/wovenmatter-ci"
fi
root="$base/$purpose"
mkdir -p "$root"
# Xcode's compilation cache only grows; start it over past the limit.
limit_kb=$(( ${WOVENMATTER_COMPILER_CACHE_LIMIT_MB:-6144} * 1024 ))
if [ -d "$root/Compiler" ] && [ "$(du -sk "$root/Compiler" | awk '{print $1}')" -gt "$limit_kb" ]; then
  rm -rf "$root/Compiler"
  echo "Removed the $purpose compiler cache over ${WOVENMATTER_COMPILER_CACHE_LIMIT_MB:-6144} MB." >&2
fi
cat <<EOF
WOVENMATTER_CI_CACHE_ROOT=$root
WOVENMATTER_DOWNLOAD_CACHE=$root/Downloads
WOVENMATTER_BROWSER_CACHE=$root/BrowserBuilds
WOVENMATTER_CEF_CACHE_DIR=$root/CEF
WOVENMATTER_PACKAGE_CACHE=$root/SourcePackages
WOVENMATTER_COMPILER_CACHE=$root/Compiler
WOVENMATTER_RELEASE_ARTIFACT_CACHE=$root/ReleaseArtifacts
WOVENMATTER_LIBRARY_BUILD_CACHE=$root/LinuxLibrary
WOVENMATTER_TEST_CACHE_DIR=$root/Tests
npm_config_cache=$root/npm
EOF
