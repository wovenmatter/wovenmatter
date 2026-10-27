#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
output="${1:?usage: prepare-cua.sh OUTPUT_DIRECTORY}"
python3 "$root/scripts/prepare-cua.py" "$output"
