#!/usr/bin/env bash
# Portable PR feedback; native/mobile/image validation is explicitly requested.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
export PYTHONDONTWRITEBYTECODE=1
changed="$(mktemp)"
trap 'rm -f "$changed"' EXIT
case "${1:-changed}" in
  --files) test "$#" -eq 2; cat "$2" > "$changed" ;;
  --all) git ls-files > "$changed" ;;
  changed)
    base="${WOVENMATTER_TEST_BASE:-origin/main}"
    git diff --name-only "$base"...HEAD > "$changed"
    git diff --name-only >> "$changed"
    git diff --cached --name-only >> "$changed"
    git ls-files --others --exclude-standard >> "$changed"
    ;;
  *) echo 'usage: scripts/test-ci.sh [--all|--files PATH]' >&2; exit 64 ;;
esac

scripts/scan-public-tree.sh
while IFS= read -r -d '' file; do
  [ ! -f "$file" ] || bash -n "$file"
done < <(git ls-files -z -- '*.sh')
python3 - <<'PY'
import ast
from pathlib import Path
for directory in ('scripts', 'remote/security'):
    for path in Path(directory).rglob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
PY
python3 scripts/test-support/test_ci_scopes.py
python3 scripts/test-support/test_ci_runner.py
jq -e '.schemaVersion == 4 and (.harnesses | length == 4)' harnesses/catalog.json >/dev/null

selection="$(python3 scripts/ci-scopes.py < "$changed")"
printf '%s\n' "$selection"
enabled() { printf '%s\n' "$selection" | grep -qx "$1=true"; }
if enabled agent || enabled service || enabled pi; then
  npm ci --prefix default-agent --ignore-scripts --no-audit --no-fund
fi
if enabled agent; then
  npm test --prefix default-agent
  node --test scripts/test-support/native-mcp.test.mjs
fi
if enabled service; then
  npm test --prefix remote
fi
if enabled pi; then
  node scripts/build-ios-pi-runtime.mjs --check
fi
if enabled embedded; then
  node scripts/build-ios-embedded-runtime.mjs --check
fi
if enabled scripts; then
  # These fixtures stub external tools; native fixtures run in manual validation.
  scripts/test-release.sh --portable
  for suite in update_refresh ios_runner dev_build executor_deployment remote_image; do
    python3 "scripts/test-support/test_${suite}.py"
  done
  scripts/test-dev-signing.sh
  scripts/test-remote-workspace.sh
  scripts/test-remote-host.sh
  while IFS= read -r -d '' file; do
    [ ! -f "$file" ] || node --check "$file"
  done < <(git ls-files -z -- 'scripts/*.mjs' 'remote/src/*.mjs' 'remote/test/*.mjs')
fi
echo 'Portable CI passed.'
