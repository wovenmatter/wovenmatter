#!/usr/bin/env bash
# Bundles the in-repo bots runtime (bots/) into the app's resources. It runs with
# the Node and npm that prepare-default-agent.sh already placed beside it, so the
# app ships one recorded Node selection. Usage: prepare-bots.sh <Resources>/bots
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source_root="$repo_root/bots"
output="${1:?usage: prepare-bots.sh <output directory>}"
agent="$(dirname "$output")/default-agent"

if [ ! -f "$source_root/package.json" ] || [ ! -f "$source_root/package-lock.json" ] || [ ! -f "$source_root/src/cli.ts" ]; then
  # Until the runtime lands, Debug builds run without bots; a release must include them.
  if [ "${CONFIGURATION:-Debug}" = Release ]; then
    printf 'The bots runtime (bots/package.json, package-lock.json, src/cli.ts) is missing.\n' >&2
    exit 1
  fi
  printf 'warning: bots/ is not in this checkout; building without bots.\n' >&2
  rm -rf "$output"
  exit 0
fi

node="$agent/bin/node"
npm_cli="$agent/lib/npm/bin/npm-cli.js"
if [ ! -x "$node" ] || [ ! -f "$npm_cli" ]; then
  printf 'Run prepare-default-agent.sh first: %s has no bundled Node and npm.\n' "$agent" >&2
  exit 1
fi
arch="${CURRENT_ARCH:-$(uname -m)}"
if [ "$arch" = undefined_arch ]; then arch="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"; fi
case "$arch" in
  arm64) node_arch=arm64 ;;
  x86_64) node_arch=x64 ;;
  *) printf 'Unsupported bots architecture: %s\n' "$arch" >&2; exit 1 ;;
esac

node_version="$("$node" --version)"
lock_hash="$(shasum -a 256 "$source_root/package-lock.json" | cut -d ' ' -f1)-node-$node_version-darwin-$node_arch"
# Keep installed dependencies outside a possibly cloud-synced checkout, keyed by
# the committed lockfile and toolchain, as the default agent's are.
dependency_root="${TMPDIR:-/tmp}/wovenmatter-bots-dependencies-$lock_hash"
if [ ! -f "$dependency_root/node_modules/.woven-lock" ] || [ "$(cat "$dependency_root/node_modules/.woven-lock")" != "$lock_hash" ]; then
  mkdir -p "$dependency_root"
  cp "$source_root/package.json" "$source_root/package-lock.json" "$dependency_root/"
  (
    cd -P "$dependency_root"
    PATH="$(dirname "$node"):$PATH" "$node" "$npm_cli" ci --omit=dev --ignore-scripts --no-audit --no-fund \
      --cpu="$node_arch" --os=darwin
  )
  printf '%s' "$lock_hash" > "$dependency_root/node_modules/.woven-lock"
fi

mkdir -p "$output"
rsync -a --delete --exclude=/node_modules --exclude=/test --exclude=.DS_Store --exclude='*.map' "$source_root/" "$output/"
mkdir -p "$output/node_modules"
rsync -a --delete "$dependency_root/node_modules/" "$output/node_modules/"
find "$output/node_modules" -type f -name '*.map' -delete
