#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
agent_root="$repo_root/default-agent"
# One tested Node stable record for this bundle, CI, and the managed adapter runtime.
# Dependency maintenance must update it and the checksums below together.
version="$(tr -d '[:space:]' < "$agent_root/.node-version")"
arch="${CURRENT_ARCH:-$(uname -m)}"
if [ "$arch" = undefined_arch ]; then arch="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"; fi
case "$arch" in
  arm64) node_arch=arm64; checksum=d38bd5e5a2ddce6bbb5ce45e46e208337da4d51fffe611e567fd32073d6439f6 ;;
  x86_64) node_arch=x64; checksum=525c9b29bb0263d687de60a4cec0e2a6db876a8eb032369e5795eca71e7c358e ;;
  *) printf 'Unsupported Built-in architecture: %s\n' "$arch" >&2; exit 1 ;;
esac
cache="${TMPDIR:-/tmp}/wovenmatter-node-$version-$node_arch"
if [ ! -x "$cache/bin/node" ]; then
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT
  archive="$(python3 "$repo_root/scripts/cached-download.py" "https://nodejs.org/dist/v$version/node-v$version-darwin-$node_arch.tar.gz" sha256 "$checksum")"
  mkdir -p "$cache"
  tar -xzf "$archive" --strip-components=1 -C "$cache"
fi
export PATH="$cache/bin:$PATH"
lock_hash="$(shasum -a 256 "$agent_root/package-lock.json" | cut -d ' ' -f1)-node-$version-darwin-$node_arch"
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
  rsync -a --delete --exclude=/bin --exclude=/lib --exclude=/node_modules --exclude=/test --exclude=/.build --exclude=/.node-version --exclude=.DS_Store "$agent_root/" "$output/"
  # The remote bootstrap serves authenticated HTTP MCP inside the workspace.
  # Copy the canonical relay source beside the bundled agent; no CLI is shipped.
  cp "$repo_root/remote/src/mcp-relay.mjs" "$(dirname "$output")/mcp-relay.mjs"
  # Native-host source fingerprints use the same canonical paths in a checkout
  # and in the signed app's resources. These records are not runtime caches.
  cp "$agent_root/.node-version" "$output/.node-version"
  mkdir -p "$(dirname "$output")/scripts"
  cp -p "$repo_root/scripts/remote-host.sh" "$(dirname "$output")/scripts/remote-host.sh"
  rm -f "$(dirname "$output")/wovenmatter" "$(dirname "$output")/wovenmatter-remote.py"
fi
mkdir -p "$output/node_modules"
rsync -a --delete "$dependency_root/node_modules/" "$output/node_modules/"

# The retained coding tools and Durable runtime may nest dependencies. Cover that
# layout and hoisted dependencies without changing either SDK's locked tree.
for modules in "$output/node_modules" "$output/node_modules/@earendil-works/pi-coding-agent/node_modules" "$output/node_modules/@earendil-works/pi-durable/node_modules"; do
  # Keep pi-tui's JavaScript, but omit unused terminal clipboard/modifier helpers.
  rm -rf "$modules/@earendil-works/pi-tui/native"
  # Built-in disables extensions and uses only Chord's runtime APIs. Its optional
  # plugin compiler, platform executables, and CLI link are not used in the app.
  rm -rf "$modules/esbuild" "$modules/@esbuild"
  rm -f "$modules/.bin/esbuild"
done

# Source maps are diagnostic build output; Node executes the original JS/TS.
# Leave executable code, declarations, licenses, and vendor signatures intact.
find "$output/node_modules" -type f -name '*.map' -delete

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
