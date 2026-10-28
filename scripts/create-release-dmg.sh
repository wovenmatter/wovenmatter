#!/usr/bin/env bash
# Prefer LZFSE speed, retaining the installed legacy updater's size bound.
# ULFO requires macOS 10.11 and ULMO 10.15; the app requires macOS 26.
set -euo pipefail
staging="${1:?STAGING OUTPUT}"
dmg="${2:?STAGING OUTPUT}"
[ ! -e "$dmg" ] && [ ! -L "$dmg" ] || { echo 'Refusing to overwrite an existing disk image.' >&2; exit 65; }
for format in ULFO ULMO; do
  started=$SECONDS
  hdiutil create -volname 'Woven Matter' -srcfolder "$staging" -format "$format" "$dmg"
  bytes="$(stat -f %z "$dmg")"
  printf 'DMG compression format %s: %s seconds, %s bytes\n' "$format" "$((SECONDS-started))" "$bytes"
  # Leave room for the signature and staple; final signed size is checked again.
  if [ "$bytes" -le 535822336 ]; then exit 0; fi
  if [ "$format" = ULFO ]; then rm -f "$dmg"; fi
done
echo 'Compatibility disk image exceeds the installed updater size budget.' >&2
exit 65
