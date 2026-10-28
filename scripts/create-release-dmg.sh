#!/usr/bin/env bash
# Use ordinary zlib compression for the full download image.
set -euo pipefail
staging="${1:?STAGING OUTPUT}"
dmg="${2:?STAGING OUTPUT}"
[ ! -e "$dmg" ] && [ ! -L "$dmg" ] || { echo 'Refusing to overwrite an existing disk image.' >&2; exit 65; }
started=$SECONDS
hdiutil create -volname 'Woven Matter' -srcfolder "$staging" -format UDZO \
  -imagekey zlib-level=6 "$dmg"
bytes="$(stat -f %z "$dmg")"
printf 'DMG compression level 6: %s seconds, %s bytes\n' "$((SECONDS-started))" "$bytes"
