#!/usr/bin/env bash
set -euo pipefail
version="${1:?VERSION BUILD DMG OUTPUT}"
build="${2:?}"
dmg="${3:?}"
output="${4:?}"
: "${WOVENMATTER_SPARKLE_PRIVATE_KEY:?Update feeds require a release signing key file}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tools="$("$repo_root/scripts/prepare-sparkle-tools.sh")"
archives="$(mktemp -d)"
trap 'rm -rf "$archives"' EXIT
# Full-only: the generator sees only the new archive, so no published build can
# become a delta base, and --maximum-deltas 0 states the same intent.
asset="WovenMatter_${version}_${build}_arm64.dmg"
cp "$dmg" "$archives/$asset"
echo "Generating full-only update feed for $asset."
started=$SECONDS
status=0
"$tools/bin/generate_appcast" --ed-key-file "$WOVENMATTER_SPARKLE_PRIVATE_KEY" \
  --download-url-prefix "https://github.com/wovenmatter/wovenmatter/releases/download/v${version}/" \
  --maximum-versions 1 --maximum-deltas 0 --versions "$build" \
  --full-release-notes-url "https://github.com/wovenmatter/wovenmatter/releases/tag/v${version}" \
  -o "$archives/appcast.xml" "$archives" || status=$?
elapsed=$((SECONDS - started))
if [ "$status" -ne 0 ]; then
  echo "generate_appcast failed with status $status after ${elapsed}s." >&2
  exit "$status"
fi
echo "Generated full-only update feed in ${elapsed}s."
if find "$archives" -maxdepth 1 -name '*.delta' | grep -q .; then
  echo "generate_appcast produced a delta for a full-only release." >&2
  exit 1
fi
"$tools/bin/sign_update" --ed-key-file "$WOVENMATTER_SPARKLE_PRIVATE_KEY" "$archives/appcast.xml"
"$tools/bin/sign_update" --verify --ed-key-file "$WOVENMATTER_SPARKLE_PRIVATE_KEY" "$archives/appcast.xml"
cp "$archives/$asset" "$archives/appcast.xml" "$output/"
swift "$repo_root/scripts/verify-update-signatures.swift" "$output"
python3 "$repo_root/scripts/release-assets.py" prepare "$output" "$version" "$(git -C "$repo_root" rev-parse HEAD)" --build "$build"

python3 "$repo_root/scripts/verify-update-paths.py" "$output"
