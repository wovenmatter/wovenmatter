#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
agent_root="$repo_root/default-agent"
version=24.18.0
arch="${CURRENT_ARCH:-$(uname -m)}"
if [ "$arch" = undefined_arch ]; then arch="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"; fi
case "$arch" in
  arm64) node_arch=arm64; checksum=e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1 ;;
  x86_64) node_arch=x64; checksum=dfd0dbd3e721503434df7b7205e719f61b3a3a31b2bcf9729b8b91fea240f080 ;;
  *) printf 'Unsupported Built-in architecture: %s\n' "$arch" >&2; exit 1 ;;
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
lock_hash="$(shasum -a 256 "$agent_root/package-lock.json" | cut -d ' ' -f1)-darwin-$node_arch"
# Keep reproducible dependencies outside a possibly cloud-synced checkout.
# Copying node_modules from Desktop can block on File Provider hydration (and
# include conflict copies) even when every package version is already locked.
dependency_root="${TMPDIR:-/tmp}/wovenmatter-agent-dependencies-$lock_hash"
if [ ! -f "$dependency_root/node_modules/.woven-lock" ] || [ "$(cat "$dependency_root/node_modules/.woven-lock")" != "$lock_hash" ]; then
  mkdir -p "$dependency_root"
  cp "$agent_root/package.json" "$agent_root/package-lock.json" "$dependency_root/"
  (
    # npm must see the physical working directory on macOS, where TMPDIR
    # commonly begins with the /var symlink to /private/var.
    cd -P "$dependency_root"
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund --cpu="$node_arch" --os=darwin
  )
  printf '%s' "$lock_hash" > "$dependency_root/node_modules/.woven-lock"
fi
output="${1:-$agent_root}"
if [ "$output" != "$agent_root" ]; then
  mkdir -p "$output"
  rsync -a --delete --exclude=/bin --exclude=/lib --exclude=/node_modules --exclude=/test --exclude=/.build --exclude=.DS_Store "$agent_root/" "$output/"
fi
mkdir -p "$output/node_modules"
rsync -a --delete "$dependency_root/node_modules/" "$output/node_modules/"

# Pi 1.0's shrinkwrap nests dependencies under pi-coding-agent. Cover that
# layout and hoisted dependencies without changing either SDK's locked tree.
for modules in "$output/node_modules" "$output/node_modules/@earendil-works/pi-coding-agent/node_modules"; do
  # Keep pi-tui's JavaScript, but omit unused terminal clipboard/modifier helpers.
  rm -rf "$modules/@earendil-works/pi-tui/native"
  # Built-in disables extensions and uses only Chord's runtime APIs. Its optional
  # plugin compiler, platform executables, and CLI link are not used in the app.
  rm -rf "$modules/esbuild" "$modules/@esbuild"
  rm -f "$modules/.bin/esbuild"
done

claude_binary="$output/node_modules/@anthropic-ai/claude-agent-sdk-darwin-$node_arch/claude"
test -x "$claude_binary"
# Preserve Anthropic's signed, unmodified runtime. Never re-sign or patch it.
codesign --verify --strict "$claude_binary"
mkdir -p "$output/bin"
cp "$cache/bin/node" "$output/bin/node"
cp "$cache/LICENSE" "$output/bin/NODE-LICENSE"
# SDK maintenance runs npm with the signed bundled Node, without relying on a host install.
mkdir -p "$output/lib/npm"
rsync -a --delete "$cache/lib/node_modules/npm/" "$output/lib/npm/"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  timestamp=--timestamp=none
  if [ "${CONFIGURATION:-Debug}" = Release ]; then timestamp=--timestamp; fi
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$timestamp" --entitlements "$repo_root/default-agent/node-entitlements.plist" "$output/bin/node"
fi
