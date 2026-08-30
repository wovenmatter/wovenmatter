#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: generate-release-manifest.sh VERSION BUILD DMG OUTPUT}"
build="${2:?usage: generate-release-manifest.sh VERSION BUILD DMG OUTPUT}"
dmg="${3:?usage: generate-release-manifest.sh VERSION BUILD DMG OUTPUT}"
output="${4:?usage: generate-release-manifest.sh VERSION BUILD DMG OUTPUT}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { printf '%s\n' 'Version must be X.Y.Z.' >&2; exit 64; }
[[ "$build" =~ ^[1-9][0-9]*$ ]] \
  || { printf '%s\n' 'Build must be a positive integer.' >&2; exit 64; }
expected_asset="WovenMatter_${version}_arm64.dmg"
[ "$(basename "$dmg")" = "$expected_asset" ] \
  || { printf 'Expected release asset %s.\n' "$expected_asset" >&2; exit 64; }
[ -f "$dmg" ] || { printf 'Release asset not found: %s\n' "$dmg" >&2; exit 66; }

sha256="$(shasum -a 256 "$dmg" | awk '{print $1}')"
temporary="${output}.tmp"
jq -n \
  --arg version "$version" \
  --argjson build "$build" \
  --arg download_url "https://github.com/wovenmatter/wovenmatter/releases/download/v${version}/${expected_asset}" \
  --arg release_url "https://github.com/wovenmatter/wovenmatter/releases/tag/v${version}" \
  --arg sha256 "$sha256" \
  '{
    schema_version: 1,
    version: $version,
    build: $build,
    architecture: "arm64",
    minimum_macos: "26.0",
    download_url: $download_url,
    release_url: $release_url,
    sha256: $sha256
  }' > "$temporary"
mv "$temporary" "$output"
