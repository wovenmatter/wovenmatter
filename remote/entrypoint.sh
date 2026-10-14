#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0

: "${WOVENMATTER_API_TOKEN:?WOVENMATTER_API_TOKEN is required}"
mkdir -p "${WOVENMATTER_WORKSPACE:-$HOME/.woven-matter}"
exec node /opt/wovenmatter/src/server.mjs
