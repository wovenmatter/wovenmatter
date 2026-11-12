#!/bin/bash
# Enforce the bots' disk cap on the data disk, online in both directions.
# The data disk is a sparse image as large as the Mac's volume; a reserve file
# of unwritten (fallocated) extents holds everything above the cap. Its blocks
# are never written, so they never take space on the Mac. Raising the cap
# shrinks the reserve at once; lowering it grows the reserve only into free
# space, so it stops at what bots already use.
set -euo pipefail
cap="${1:?usage: disk-cap.sh BYTES}"
data=/var/lib/woven-data
reserve="$data/.reserve"
mkdir -p /etc/woven
printf '%s\n' "$cap" >/etc/woven/disk-cap
mountpoint -q "$data" || { echo "data disk not mounted"; exit 0; }
read -r blocks available size < <(stat -f -c '%b %a %S' "$data")
total=$((blocks * size))
free=$((available * size))
current=$(stat -c %s "$reserve" 2>/dev/null || echo 0)
want=$((cap >= total ? 0 : total - cap))
if ((want < current)); then
  if ((want == 0)); then rm -f "$reserve"; else truncate -s "$want" "$reserve"; fi
elif ((want > current)); then
  # Return blocks bots freed to the Mac before the reserve can claim them.
  fstrim "$data" >/dev/null 2>&1 || true
  read -r blocks available size < <(stat -f -c '%b %a %S' "$data")
  free=$((available * size))
  margin=$((256 << 20))
  limit=$((current + free - margin))
  ((limit < current)) && limit=$current
  ((want > limit)) && want=$limit
  if ((want > current)); then fallocate -l "$want" "$reserve"; fi
  chmod 0600 "$reserve" 2>/dev/null || true
fi
current=$(stat -c %s "$reserve" 2>/dev/null || echo 0)
echo "effective cap $((total - current)) of $total"
