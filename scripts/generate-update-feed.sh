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
archives="${WOVENMATTER_UPDATE_ARCHIVES:-$(mktemp -d)}"
mkdir -p "$archives"
generator_pid=""
cleanup() {
  if [ -n "$generator_pid" ]; then
    kill "$generator_pid" 2>/dev/null || true
    wait "$generator_pid" 2>/dev/null || true
  fi
  if [ -z "${WOVENMATTER_UPDATE_ARCHIVES:-}" ]; then rm -rf "$archives"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# Published signed apps are the delta bases. Never patch/re-sign an old bundle.
find "$history" -maxdepth 1 -name '*.dmg' -exec cp {} "$archives/" \;
asset="WovenMatter_${version}_${build}_arm64.dmg"
cp "$dmg" "$archives/$asset"
# Always generate the feed from the final archive bytes. Prepared deltas are
# reusable because stapling the outer DMG does not change the enclosed app.
rm -f "$archives/appcast.xml"
"$tools/bin/generate_appcast" --ed-key-file "$WOVENMATTER_SPARKLE_PRIVATE_KEY" \
  --download-url-prefix "https://github.com/wovenmatter/wovenmatter/releases/download/v${version}/" \
  --maximum-versions 1 --maximum-deltas 5 --delta-compression lzfse --versions "$build" \
  --full-release-notes-url "https://github.com/wovenmatter/wovenmatter/releases/tag/v${version}" \
  -o "$archives/appcast.xml" "$archives" &
generator_pid=$!
if wait "$generator_pid"; then generator_pid=""; else status=$?; generator_pid=""; exit "$status"; fi
if [ "${WOVENMATTER_UPDATE_PREPARE_ONLY:-0}" = 1 ]; then exit 0; fi
python3 "$repo_root/scripts/normalize-update-feed.py" "$archives" "$version" "$build"
"$tools/bin/sign_update" --ed-key-file "$WOVENMATTER_SPARKLE_PRIVATE_KEY" "$archives/appcast.xml"
"$tools/bin/sign_update" --verify --ed-key-file "$WOVENMATTER_SPARKLE_PRIVATE_KEY" "$archives/appcast.xml"
cp "$archives/$asset" "$archives/appcast.xml" "$output/"
find "$archives" -maxdepth 1 -name '*.delta' -exec cp {} "$output/" \;
swift "$repo_root/scripts/verify-update-signatures.swift" "$output"
python3 "$repo_root/scripts/release-assets.py" prepare "$output" "$version" "$(git -C "$repo_root" rev-parse HEAD)" --build "$build" --history "$history"

python3 "$repo_root/scripts/verify-update-paths.py" "$output" "$history" "$tools"
