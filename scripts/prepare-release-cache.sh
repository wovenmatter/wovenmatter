#!/usr/bin/env bash
# Trusted main cache warmer. No production signing credentials or app artifacts.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
export WOVENMATTER_WRITE_BROWSER_CACHE=1
export WOVENMATTER_BROWSER_BUILD_ONLY=1
export DERIVED_FILE_DIR="$temporary/derived"
export BUILT_PRODUCTS_DIR="$temporary/products"
scripts/prepare-browser.sh
CODE_SIGNING_ALLOWED=NO scripts/prepare-default-agent.sh "$temporary/agent"
scripts/prepare-sparkle-tools.sh >/dev/null
xcodebuild -quiet -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile \
  -project app/WovenMatter.xcodeproj -scheme WovenMatter \
  -clonedSourcePackagesDirPath "$HOME/Library/Caches/WovenMatter/SourcePackages"
