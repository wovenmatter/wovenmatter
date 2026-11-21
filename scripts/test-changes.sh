#!/usr/bin/env bash
# Runs the test suite: static checks, the Swift packages (protocol, library and
# server, through the server package), on a Mac the server's core built for
# iOS, and the two Node children. No test calls
# a provider. Runs the same on this Mac and on Linux; pull request CI runs
# `--ci` on Linux.
#
#   scripts/test-changes.sh [--all|--ci]
#
# WOVEN_SWIFT_SCRATCH_PATH puts the Swift build somewhere of your own, so
# parallel worktrees and agents never wait on one another's build lock.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

run_static_checks() {
  scripts/scan-public-tree.sh
  local file
  while IFS= read -r -d '' file; do
    [ ! -f "$file" ] || bash -n "$file"
  done < <(git ls-files -z -- '*.sh')
  git ls-files -z -- '*.py' | PYTHONDONTWRITEBYTECODE=1 xargs -0 python3 -c '
import ast, sys
for path in sys.argv[1:]:
    ast.parse(open(path).read(), filename=path)
'
  check_app_imports
  echo 'Static checks passed.'
}

# Swift files under $1 that import module $2.
importers() {
  [ -d "$1" ] || return 0
  grep -rlE "^[[:space:]]*(@testable[[:space:]]+)?(@_exported[[:space:]]+)?import[[:space:]]+$2([[:space:]]|$)" "$1" \
    --include='*.swift' || true
}

# The UI reaches the library only through a server. On a Mac nothing under
# app/ imports the library or the server's core, and only the server entry
# point imports the server. On a device only the in-app host,
# ios/Sources/WovenDevice/, imports the library and the core, and nothing
# imports the machine's server.
check_app_imports() {
  local found
  found="$(importers app WovenServerKit | grep -vx 'app/App/ServerEntry.swift' || true)"
  if [ -n "$found" ]; then
    printf 'Only app/App/ServerEntry.swift may import WovenServerKit:\n%s\n' "$found" >&2
    return 1
  fi
  found="$(importers app WovenLibrary; importers app WovenServerCore)"
  if [ -n "$found" ]; then
    printf 'Nothing under app/ may import WovenLibrary or WovenServerCore:\n%s\n' "$found" >&2
    return 1
  fi
  found="$( (importers ios WovenLibrary; importers ios WovenServerCore) | grep -v '^ios/Sources/WovenDevice/' || true)"
  if [ -n "$found" ]; then
    printf 'Only ios/Sources/WovenDevice/ may import WovenLibrary or WovenServerCore:\n%s\n' "$found" >&2
    return 1
  fi
  found="$(importers ios WovenServerKit)"
  if [ -n "$found" ]; then
    printf 'Nothing under ios/ may import WovenServerKit:\n%s\n' "$found" >&2
    return 1
  fi
}

# Sync, sessions and server-to-server tests for protocol/, library/ and
# server/. They use a stand-in runtime and a stand-in tailnet. The committed
# Package.resolved is used as it is.
run_swift_tests() {
  local scratch=()
  [ -z "${WOVEN_SWIFT_SCRATCH_PATH:-}" ] || scratch=(--scratch-path "$WOVEN_SWIFT_SCRATCH_PATH")
  swift test --package-path server --force-resolved-versions ${scratch[@]+"${scratch[@]}"}
}

# On a Mac, builds the server's core, with the library and the protocol, for
# the iOS Simulator, so a change that breaks the device is caught here.
run_ios_core_build() {
  [ "$(uname -s)" = Darwin ] || return 0
  local derived="${WOVEN_SWIFT_SCRATCH_PATH:-$repo_root/server/.build}/ios-core"
  (cd server && xcodebuild -quiet -scheme WovenServerCore -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived" -onlyUsePackageVersionsFromResolvedFile build)
  echo 'The server core builds for iOS.'
}

# Installs a Node child's committed package graph when node_modules is missing
# or older than the lockfile, then runs its tests with the repository's Node.
run_node_tests() {
  (cd "$1" && {
    [ -f node_modules/.package-lock.json ] && [ ! package-lock.json -nt node_modules/.package-lock.json ] \
      || "$repo_root/scripts/with-pinned-node.sh" npm ci --no-audit --no-fund
  } && "$repo_root/scripts/with-pinned-node.sh" npm test)
}

case "${1:---all}" in
  --all|--ci)
    run_static_checks
    run_swift_tests
    run_ios_core_build
    run_node_tests default-agent
    run_node_tests bots
    ;;
  *)
    echo 'usage: scripts/test-changes.sh [--all|--ci]' >&2
    exit 64
    ;;
esac
