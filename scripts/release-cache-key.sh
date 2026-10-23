#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Exact inputs only; no fallback key can cross toolchains or dependency graphs.
{
  xcodebuild -version
  xcrun --sdk macosx --show-sdk-version
  xcrun clang --version
  cmake --version
  uname -m
  git ls-files app/Browser app/Updater default-agent/package.json default-agent/package-lock.json default-agent/.node-version app/Package.resolved app/Package.swift shared/Package.swift app/WovenMatter.xcodeproj/project.pbxproj scripts/prepare-browser.sh scripts/prepare-default-agent.sh scripts/prepare-sparkle-tools.sh scripts/cached-download.py scripts/browser-build-cache.py scripts/prepare-release-cache.sh scripts/release-cache-key.sh scripts/warm-release-compiler.sh | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done
} | shasum -a 256 | awk '{print "key=release-inputs-v1-" $1}'
