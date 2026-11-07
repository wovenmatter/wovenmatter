#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 0 ] || { echo 'usage: scripts/update-pi-bot.sh' >&2; exit 64; }
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
# Maintenance resolves main explicitly; builds consume only the accepted SHA.
origin="$(git -C "$repo_root" remote get-url origin)"
case "$origin" in
  git@*:wovenmatter/wovenmatter.git) remote="${origin%wovenmatter.git}pi-bot.git" ;;
  *) echo 'Pi Bot maintenance requires the repository-configured GitHub SSH identity.' >&2; exit 65 ;;
esac
commit="$(git ls-remote "$remote" refs/heads/main | cut -f1)"
[[ "$commit" =~ ^[a-f0-9]{40}$ ]] || { echo 'Could not resolve Pi Bot origin/main using existing SSH access.' >&2; exit 1; }
node - "$repo_root/pi-bot/selection.json" "$commit" <<'JS'
const fs = require('node:fs');
const file = process.argv[2], record = JSON.parse(fs.readFileSync(file));
record.commit = process.argv[3];
fs.writeFileSync(file, JSON.stringify(record, null, 2) + '\n');
console.log('Selected Pi Bot ' + record.commit + '; validate packaging and the host before accepting this record.');
JS
