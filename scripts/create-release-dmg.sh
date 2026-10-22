#!/usr/bin/env bash
# Prefer faster compression, retaining the installed legacy updater's size bound.
set -euo pipefail
staging="${1:?STAGING OUTPUT}"
dmg="${2:?STAGING OUTPUT}"
[ ! -e "$dmg" ] && [ ! -L "$dmg" ] || { echo 'Refusing to overwrite an existing disk image.' >&2; exit 65; }
for level in 6 9; do
  started=$SECONDS
  hdiutil create -volname 'Woven Matter' -srcfolder "$staging" -format UDZO \
    -imagekey "zlib-level=$level" "$dmg"
  bytes="$(stat -f %z "$dmg")"
  printf 'DMG compression level %s: %s seconds, %s bytes\n' "$level" "$((SECONDS-started))" "$bytes"
  # Leave room for the signature and staple; final signed size is checked again.
  if [ "$bytes" -le 535822336 ]; then exit 0; fi
  if [ "$level" = 6 ]; then rm -f "$dmg"; fi
done
echo 'Compatibility disk image exceeds the installed updater size budget.' >&2
exit 65
