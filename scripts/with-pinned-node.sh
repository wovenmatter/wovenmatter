#!/usr/bin/env bash
# Runs a command with the repository's pinned Node (default-agent/.node-version)
# first on PATH. CI selects that release with setup-node; on a Mac whose default
# Node differs, use the checksum-verified copy the app bundle build caches.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pinned="v$(tr -d '[:space:]' < "$root/default-agent/.node-version")"
if [ "$(node --version 2>/dev/null || true)" != "$pinned" ] && [ "$(uname -s)" = Darwin ]; then
  PATH="$("$root/scripts/prepare-default-agent.sh" --print-node-bin):$PATH"
  export PATH
fi
exec "$@"
