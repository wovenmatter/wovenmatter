#!/usr/bin/env bash
set -euo pipefail

: "${WOVENMATTER_API_TOKEN:?WOVENMATTER_API_TOKEN is required}"
/opt/wovenmatter/harnesses/initialize-workspace.sh "${WOVENMATTER_WORKSPACE:-$HOME/.woven-matter}"
exec node /opt/wovenmatter/src/server.mjs
