#!/usr/bin/env bash
# The runner runs this before (`started`) and after (`completed`) every job, from
# its own install directory, so no workflow or branch can change it. It is the
# boundary that keeps these persistent machines from running untrusted code:
# only collaborator-started jobs (a manual dispatch or a push, which need write
# access) from the allowed workflows of this repository run. Pull requests, which
# a fork can open and whose workflow files a fork can edit, are refused even if
# a workflow file is changed to target this runner.
set -uo pipefail
phase="${1:-}"
repository=wovenmatter/wovenmatter
# Settings come from files beside this script, never from the environment: a
# workflow's `env:` reaches job hooks, and GitHub keeps only GITHUB_* fixed.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workflows='.github/workflows/validation.yml .github/workflows/release.yml'
if [ -f "$here/allowed-workflows" ]; then workflows="$(tr '\n' ' ' < "$here/allowed-workflows")"; fi

refuse() {
  echo "::error::This Woven Matter runner refuses the job: $*" >&2
  exit 1
}

# A release job adds a temporary signing keychain to the user's search list and
# removes it when it ends. If a job was killed first, drop the stale entry so the
# user's own keychains are unaffected. Nothing else in the list is touched.
release_keychain_hygiene() {
  [ "$(uname -s)" = Darwin ] || return 0
  local line keychain stale=0 keep=()
  while IFS= read -r line; do
    keychain="${line#"${line%%[![:space:]]*}"}"
    keychain="${keychain#\"}"; keychain="${keychain%\"}"
    [ -n "$keychain" ] || continue
    if [ "$(basename "$keychain")" = wovenmatter-release.keychain-db ]; then
      stale=1
      security delete-keychain "$keychain" 2>/dev/null || true
    else
      keep+=("$keychain")
    fi
  done < <(security list-keychains -d user)
  if [ "$stale" = 1 ] && [ "${#keep[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${keep[@]}"
  fi
}

case "$phase" in
  started)
    [ "${GITHUB_REPOSITORY:-}" = "$repository" ] || refuse "repository '${GITHUB_REPOSITORY:-unset}' is not $repository."
    case "${GITHUB_EVENT_NAME:-}" in
      push|workflow_dispatch) ;;
      *) refuse "event '${GITHUB_EVENT_NAME:-unset}' is not a collaborator push or manual dispatch." ;;
    esac
    # GITHUB_WORKFLOW_REF: OWNER/REPO/.github/workflows/NAME.yml@REF
    workflow="${GITHUB_WORKFLOW_REF:-}"
    case "$workflow" in "$repository/"*) ;; *) refuse "workflow '${workflow:-unset}' is not from $repository." ;; esac
    workflow="${workflow#"$repository/"}"
    workflow="${workflow%%@*}"
    allowed=0
    for candidate in $workflows; do
      [ "$workflow" = "$candidate" ] && allowed=1
    done
    [ "$allowed" = 1 ] || refuse "workflow '$workflow' may not run here (allowed: $workflows)."
    release_keychain_hygiene
    echo "Woven Matter runner accepted $GITHUB_EVENT_NAME of $workflow on ${GITHUB_REF:-unknown ref}."
    ;;
  completed)
    release_keychain_hygiene
    ;;
  *)
    echo 'usage: runner-guard.sh started|completed' >&2
    exit 64
    ;;
esac
