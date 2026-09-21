#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
agent_root="$repo_root/default-agent"
version=24.18.0
arch="${CURRENT_ARCH:-$(uname -m)}"
if [ "$arch" = undefined_arch ]; then arch="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"; fi
case "$arch" in
  arm64) node_arch=arm64; checksum=e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1 ;;
  x86_64) node_arch=x64; checksum=dfd0dbd3e721503434df7b7205e719f61b3a3a31b2bcf9729b8b91fea240f080 ;;
  *) printf 'Unsupported Default Agent architecture: %s\n' "$arch" >&2; exit 1 ;;
esac
cache="${TMPDIR:-/tmp}/wovenmatter-node-$version-$node_arch"
if [ ! -x "$cache/bin/node" ]; then
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT
  curl --fail --silent --show-error --location "https://nodejs.org/dist/v$version/node-v$version-darwin-$node_arch.tar.gz" -o "$stage/node.tar.gz"
  printf '%s  %s\n' "$checksum" "$stage/node.tar.gz" | shasum -a 256 -c -
  mkdir -p "$cache"
  tar -xzf "$stage/node.tar.gz" --strip-components=1 -C "$cache"
fi
export PATH="$cache/bin:$PATH"
lock_hash="$(shasum -a 256 "$agent_root/package-lock.json" | cut -d ' ' -f1)"
if [ ! -f "$agent_root/node_modules/.woven-lock" ] || [ "$(cat "$agent_root/node_modules/.woven-lock")" != "$lock_hash" ]; then
  npm ci --prefix "$agent_root" --omit=dev --ignore-scripts --no-audit --no-fund
  printf '%s' "$lock_hash" > "$agent_root/node_modules/.woven-lock"
fi
output="${1:-$agent_root}"
if [ "$output" != "$agent_root" ]; then
  mkdir -p "$output"
  rsync -a --delete --exclude=/bin --exclude=/test --exclude=/.build --exclude=.DS_Store "$agent_root/" "$output/"
fi
mkdir -p "$output/bin"
cp "$cache/bin/node" "$output/bin/node"
cp "$cache/LICENSE" "$output/bin/NODE-LICENSE"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --entitlements "$repo_root/default-agent/node-entitlements.plist" "$output/bin/node"
fi
