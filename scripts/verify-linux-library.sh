#!/usr/bin/env bash
# Checks the packed Linux library binaries a host release ships
# (scripts/build-linux-library.sh): for each architecture, the gzip is intact and
# unpacks to exactly the SHA-256 recorded beside it. The release workflow runs this
# on the binaries the Linux job built before the macOS build bundles them.
# Usage: scripts/verify-linux-library.sh [DIR]   (default remote/host/library)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
directory="${1:-$root/remote/host/library}"
sha256() { if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
for arch in x86_64 aarch64; do
  packed="$directory/linux-$arch/wovenmatter-library.gz"
  record="$directory/linux-$arch/wovenmatter-library.sha256"
  [ -f "$packed" ] && [ -f "$record" ] || { printf 'Missing the %s library binary in %s.\n' "$arch" "$directory" >&2; exit 1; }
  expected="$(cut -d' ' -f1 < "$record")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { printf 'Invalid checksum record %s.\n' "$record" >&2; exit 1; }
  gzip -t "$packed" || { printf 'Corrupt archive %s.\n' "$packed" >&2; exit 1; }
  actual="$(gzip -dc "$packed" | sha256)"
  [ "$actual" = "$expected" ] || { printf 'The %s library binary does not match its recorded checksum.\n' "$arch" >&2; exit 1; }
  printf 'Verified linux-%s/wovenmatter-library.gz (%s bytes)\n' "$arch" "$(wc -c < "$packed" | tr -d ' ')"
done
