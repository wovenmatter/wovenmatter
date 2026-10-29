#!/usr/bin/env bash
# Trusted main cache warmer. No production signing credentials or app artifacts.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
downloads="${WOVENMATTER_DOWNLOAD_CACHE:-$HOME/Library/Caches/WovenMatter/Downloads}"
# Prefix fallbacks restore older entries; keep each saved component bounded.
if [ -d "$HOME/.npm" ] && [ "$(du -sk "$HOME/.npm" | awk '{print $1}')" -gt $((1536 * 1024)) ]; then
  rm -rf "$HOME/.npm"
fi
touch "$temporary/started"
export WOVENMATTER_WRITE_BROWSER_CACHE=1
export WOVENMATTER_BROWSER_BUILD_ONLY=1
export DERIVED_FILE_DIR="$temporary/derived"
export BUILT_PRODUCTS_DIR="$temporary/products"
# Use every pinned archive so the download store retains exactly the current set.
WOVENMATTER_CEF_CACHE_DIR="$temporary/cef" scripts/prepare-browser.sh
CODE_SIGNING_ALLOWED=NO scripts/prepare-default-agent.sh "$temporary/agent"
WOVENMATTER_SPARKLE_TOOLS_DIR="$temporary/sparkle" scripts/prepare-sparkle-tools.sh >/dev/null
scripts/prepare-cua.sh "$temporary/cua"
xcodebuild -quiet -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile \
  -project app/WovenMatter.xcodeproj -scheme WovenMatter \
  -clonedSourcePackagesDirPath "$HOME/Library/Caches/WovenMatter/SourcePackages"
if [ "${WOVENMATTER_PRUNE_DOWNLOADS:-0}" = 1 ]; then
  # cached-download.py marks each verified hit; superseded pins are dropped.
  find "$downloads" -maxdepth 1 -type f -name 'sha*-*' ! -newer "$temporary/started" -print -delete
fi
