#!/usr/bin/env bash
# A refresh is authorized only at the accepted merge that changed its request.
# Re-runs retain github.actor, while a new human dispatch must fail closed.
set -euo pipefail
test "${GITHUB_EVENT_NAME:?}" = workflow_dispatch
test "${GITHUB_ACTOR:?}" = 'github-actions[bot]'
# An ancestor from a merged PR is not itself the accepted main merge. Drain
# rev-list output (no grep -q) so pipefail cannot reject a long valid history.
git rev-list --first-parent origin/main | grep -xF "${GITHUB_SHA:?}" >/dev/null
request_commit="$(git log -1 --first-parent --format=%H "${GITHUB_SHA:?}" -- .github/release-refresh.json)"
test "$request_commit" = "$GITHUB_SHA"
