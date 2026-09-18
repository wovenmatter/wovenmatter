#!/usr/bin/env bash
set -euo pipefail

# Read-only preflight. Never repair authentication or launch a browser here.
export GH_PROMPT_DISABLED=1
export GH_BROWSER=/usr/bin/false

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

fetch_remote="$(git remote get-url origin)"
push_remote="$(git remote get-url --push origin)"
[[ "$fetch_remote" =~ ^git@github-([^:]+):wovenmatter/wovenmatter\.git$ ]] \
  || { printf '%s\n' 'origin must use the repository-specific GitHub SSH identity.' >&2; exit 65; }
remote_actor="${BASH_REMATCH[1]}"
test "$push_remote" = "$fetch_remote" \
  || { printf '%s\n' 'origin push URL must match its fetch URL.' >&2; exit 65; }

if ! actor="$(gh api --hostname github.com user --jq .login)"; then
  cat >&2 <<'MESSAGE'
Cannot verify existing GitHub CLI access in this execution environment.
This does not prove that the credential is missing, expired, or invalid.
A macOS sandbox can block Keychain or network access. Retry only this read-only
check through the approved execution permission path. If it still fails, stop
and report the blocker to the user. Never initiate login, device authorization,
browser authentication, account switching, or credential recovery.
MESSAGE
  exit 77
fi
test "$actor" = "$remote_actor" \
  || { printf 'GitHub CLI account %s does not match SSH identity %s; stop and report, never switch or log in.\n' "$actor" "$remote_actor" >&2; exit 77; }

printf 'Existing GitHub API access verified as %s; SSH remote matches.\n' "$actor"
