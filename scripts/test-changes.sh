#!/usr/bin/env bash
# Runs the test suite. Suites are added here as the rebuilt parts gain tests.
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
# server/. They use a stand-in runtime and stand-in tailnet.
run_foundation_tests() {
  swift test --package-path server
}

case "${1:---all}" in
  --ci) run_static_checks ;;
  --all)
    run_static_checks
    run_foundation_tests
    ;;
  *)
    echo 'usage: scripts/test-changes.sh [--all|--ci]' >&2
    exit 64
    ;;
esac
