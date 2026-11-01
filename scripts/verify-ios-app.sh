#!/usr/bin/env bash
set -euo pipefail
# Isolated mode: the verifier imports nothing from the artifact or current directory.
exec python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-ios-app.py" "$@"
