#!/usr/bin/env bash
# Keep tooling and the embedded framework pinned to the same reviewed version.
set -euo pipefail
cache="${WOVENMATTER_SPARKLE_TOOLS_DIR:-${TMPDIR:-/tmp}/wovenmatter-sparkle-2.10.0}"
expected=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
if [ ! -f "$cache/.verified-$expected" ]; then
  temporary="$(mktemp -d)"
  trap 'rm -rf "$temporary"' EXIT
  curl --fail --location --retry 3 --silent --show-error \
    https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
    -o "$temporary/sparkle.tar.xz"
  test "$(shasum -a 256 "$temporary/sparkle.tar.xz" | awk '{print $1}')" = "$expected"
  mkdir -p "$temporary/tools"
  tar -xf "$temporary/sparkle.tar.xz" -C "$temporary/tools"
  touch "$temporary/tools/.verified-$expected"
  rm -rf "$cache"
  mv "$temporary/tools" "$cache"
fi
printf '%s\n' "$cache"
