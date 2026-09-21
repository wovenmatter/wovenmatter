#!/usr/bin/env bash
set -euo pipefail

# Build an offline, disposable copy of the real app. The fixture hooks never
# enter the shipping target. Optional ref permits the same fixture on main.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workload="${1:-light}"
case "$workload" in light|heavy) ;; *) echo 'usage: scripts/profile-workspace.sh [light|heavy] [git-ref]' >&2; exit 64 ;; esac
profile_root="${WOVENMATTER_PERFORMANCE_DIR:-/private/tmp/wovenmatter-performance}"
mkdir -p "$profile_root"
staging="$(mktemp -d "$profile_root/source.XXXXXX")"
if [ -n "${2:-}" ]; then
  git -C "$repo_root" archive "$2" | tar -x -C "$staging"
else
  rsync -a --exclude .git --exclude .build --exclude .DS_Store "$repo_root/" "$staging/"
fi
python3 "$repo_root/scripts/performance-support/prepare-fixture.py" "$staging" "$repo_root" "$workload"
printf 'Offline fixture source: %s\n' "$staging"
WOVENMATTER_DEV_VARIANT=Performance \
WOVENMATTER_DEV_CACHE_DIR="$profile_root/build" \
  "$staging/scripts/build_and_run.sh"
