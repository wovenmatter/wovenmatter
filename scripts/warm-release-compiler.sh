#!/usr/bin/env bash
# Produce only compiler-cache entries. The unsigned app is never distributed.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${WOVENMATTER_COMPILER_CACHE:?A dedicated compiler cache is required}"
: "${WOVENMATTER_COMPILER_BUILD_ROOT:?A disposable build root is required}"
mkdir -p "$WOVENMATTER_COMPILER_CACHE" "$WOVENMATTER_COMPILER_BUILD_ROOT"
xcodebuild -quiet -showBuildTimingSummary -onlyUsePackageVersionsFromResolvedFile \
  -project app/WovenMatter.xcodeproj -scheme WovenMatter -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$WOVENMATTER_COMPILER_BUILD_ROOT/DerivedData" \
  -clonedSourcePackagesDirPath "${WOVENMATTER_PACKAGE_CACHE:-$WOVENMATTER_COMPILER_BUILD_ROOT/SourcePackages}" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION=0.0.0 CURRENT_PROJECT_VERSION=1 WOVENMATTER_SOURCE_REVISION="$(git rev-parse HEAD)" \
  COMPILATION_CACHE_ENABLE_CACHING="${WOVENMATTER_COMPILATION_CACHE_ENABLED:-YES}" \
  COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES \
  COMPILATION_CACHE_CAS_PATH="$WOVENMATTER_COMPILER_CACHE" \
  build
