#!/usr/bin/env bash
set -euo pipefail
version="${1:?VERSION BUILD DMG OUTPUT HISTORY}"
build="${2:?}"
dmg="${3:?}"
output="${4:?}"
history="${5:?}"
: "${WOVENMATTER_SPARKLE_PRIVATE_KEY:?Delta updates require a release signing key file}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tools="$("$repo_root/scripts/prepare-sparkle-tools.sh")"
archives="$(mktemp -d)"
trap 'rm -rf "$archives"' EXIT
# Published signed apps are the delta bases. Never patch/re-sign an old bundle.
find "$history" -maxdepth 1 -name '*.dmg' -exec cp {} "$archives/" \;
asset="WovenMatter_${version}_${build}_arm64.dmg"
cp "$dmg" "$archives/$asset"
"$tools/bin/generate_appcast" --ed-key-file "$WOVENMATTER_SPARKLE_PRIVATE_KEY" \
  --download-url-prefix "https://github.com/wovenmatter/wovenmatter/releases/download/v${version}/" \
  --maximum-versions 1 --maximum-deltas 5 --versions "$build" \
  --full-release-notes-url "https://github.com/wovenmatter/wovenmatter/releases/tag/v${version}" \
  -o "$archives/appcast.xml" "$archives"
python3 "$repo_root/scripts/normalize-update-feed.py" "$archives" "$version" "$build"
"$tools/bin/sign_update" --ed-key-file "$WOVENMATTER_SPARKLE_PRIVATE_KEY" "$archives/appcast.xml"
"$tools/bin/sign_update" --verify --ed-key-file "$WOVENMATTER_SPARKLE_PRIVATE_KEY" "$archives/appcast.xml"
cp "$archives/$asset" "$archives/appcast.xml" "$output/"
find "$archives" -maxdepth 1 -name '*.delta' -exec cp {} "$output/" \;
swift "$repo_root/scripts/verify-update-signatures.swift" "$output"
python3 "$repo_root/scripts/release-assets.py" prepare "$output" "$version" "$(git -C "$repo_root" rev-parse HEAD)" --build "$build" --history "$history"

python3 "$repo_root/scripts/verify-update-paths.py" "$output" "$history" "$tools"
