#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
bash -n "$repo_root/scripts/pi-bot-host.sh" "$repo_root/scripts/prepare-pi-bot.sh" "$repo_root/scripts/update-pi-bot.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$repo_root/scripts/test-support/test_pi_bot_host.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$repo_root/scripts/test-support/test_prepare_pi_bot.py"
node --test "$repo_root/scripts/test-support/pi-bot-selection.test.mjs"
