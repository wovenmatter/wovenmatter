#!/usr/bin/env bash
# Independent keys, so one component change (for example Node) keeps the others.
# Every restored entry is still checked by its consumer: pinned archive digests,
# exact browser-product manifests, resolved Swift revisions, npm lockfile
# integrity, and Xcode's per-compilation CAS keys.
set -euo pipefail
cd "$(dirname "$0")/.."
digest() { shasum -a 256 | awk '{print $1}'; }
files() { git ls-files -- "$@" | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done; }
# Assignments, not printf arguments, so any failed input aborts instead of
# producing a shared constant key.
toolchain="$({
  xcodebuild -version
  xcrun --sdk macosx --show-sdk-version
  xcrun clang --version
  uname -m
} | digest)"
# Content-addressed archives, each verified against its source pin on every use.
downloads="$(files app/Browser/cef-version.json default-agent/.node-version \
  scripts/prepare-default-agent.sh app/Updater/sparkle-version.json app/Automation/cua-version.json \
  scripts/cached-download.py | digest)"
# The browser cache's own exact key, computed as prepare-browser.sh computes it.
sdk="$(xcrun --sdk macosx --show-sdk-path)"
cmake="$(command -v cmake)"
browser="$(SDKROOT="$sdk" MACOSX_DEPLOYMENT_TARGET=26.0 python3 scripts/browser-build-cache.py key "$(uname -m)" "$cmake")"
swiftpm="$(files app/Package.resolved | digest)"
npm="$(files default-agent/package-lock.json | digest)"
# Exact toolchain always; the native graph selects the closest entry. Xcode keys
# each compilation by its full inputs, so a fallback can only skip identical work.
native="$(files app/Package.resolved app/Package.swift shared/Package.swift \
  app/WovenMatter.xcodeproj/project.pbxproj scripts/build-release.sh scripts/warm-release-compiler.sh | digest)"
[[ "$browser" =~ ^[0-9a-f]{64}$ ]] || { printf '%s\n' 'Invalid browser cache key.' >&2; exit 1; }
printf 'downloads=release-downloads-v2-%s\n' "$downloads"
printf 'downloads_fallback=release-downloads-v2-\n'
printf 'browser=release-browser-v2-%s\n' "$browser"
printf 'swiftpm=release-swiftpm-v2-%s\n' "$swiftpm"
printf 'swiftpm_fallback=release-swiftpm-v2-\n'
printf 'npm=release-npm-v2-%s\n' "$npm"
printf 'npm_fallback=release-npm-v2-\n'
printf 'compiler=release-compiler-v2-%s-%s-\n' "$toolchain" "$native"
printf 'compiler_fallback=release-compiler-v2-%s-\n' "$toolchain"
