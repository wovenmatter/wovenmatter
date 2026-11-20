#!/usr/bin/env bash
# Runs the test suite: static checks, the Swift packages (protocol, library and
# server, through the server package) and the two Node children. No test calls
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

# The UI reaches the library only through a server: nothing under app/
# imports the library, and only the server entry point imports the server.
check_app_imports() {
  local found
  found="$(grep -rlE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+WovenServerKit([[:space:]]|$)' app \
    --include='*.swift' | grep -vx 'app/App/ServerEntry.swift' || true)"
  if [ -n "$found" ]; then
    printf 'Only app/App/ServerEntry.swift may import WovenServerKit:\n%s\n' "$found" >&2
    return 1
  fi
  found="$(grep -rlE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+WovenLibrary([[:space:]]|$)' app --include='*.swift' || true)"
  if [ -n "$found" ]; then
    printf 'Nothing under app/ may import WovenLibrary:\n%s\n' "$found" >&2
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
    run_node_tests default-agent
    run_node_tests bots
    ;;
  *)
    echo 'usage: scripts/test-changes.sh [--all|--ci]' >&2
    exit 64
    ;;
esac
