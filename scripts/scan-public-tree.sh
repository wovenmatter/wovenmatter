#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tracked="$(git ls-files --cached --others --exclude-standard)"
[ -n "$tracked" ] || exit 0

if printf '%s\n' "$tracked" | grep -E '(^|/)[^/]+ [0-9]+(\.[^/]*)?($|/)'; then
  printf '%s\n' 'Conflict-copy filename found.' >&2
  exit 1
fi

if printf '%s\n' "$tracked" | grep -E '(^|/)(\.env|id_rsa|id_ed25519|.*\.p12|.*\.mobileprovision)$'; then
  printf '%s\n' 'Credential-bearing filename found.' >&2
  exit 1
fi

patterns=(
  '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  'github_pat_[A-Za-z0-9_]{30,}'
  'sk-(proj-)?[A-Za-z0-9_-]{24,}'
  'AKIA[0-9A-Z]{16}'
  '/Users/[A-Za-z0-9._-]+/'
  'github-ma[c]agent[0-9]+|ma[c]agent[0-9]+'
)

secret_pattern="$(IFS='|'; printf '%s' "${patterns[*]}")"

while IFS= read -r file; do
  [ -f "$file" ] || continue
  [ "$file" = scripts/scan-public-tree.sh ] && continue
  grep -Iq . "$file" || continue
  if grep -Eq -- "$secret_pattern" "$file"; then
    for pattern in "${patterns[@]}"; do
      if grep -Eq -- "$pattern" "$file"; then
        printf 'Public-tree scan matched %s in %s\n' "$pattern" "$file" >&2
        exit 1
      fi
    done
  fi

  case "$file" in *.svg) continue ;; esac
  if grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$file" | \
      grep -Ev '^(127\.0\.0\.1|0\.0\.0\.0)$' >/dev/null; then
    printf 'Public-tree scan found a non-loopback IPv4 address in %s\n' "$file" >&2
    exit 1
  fi
done <<< "$tracked"

printf '%s\n' 'Public-tree secret and privacy scan passed.'
