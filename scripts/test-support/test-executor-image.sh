#!/usr/bin/env bash
set -euo pipefail

test -s /etc/ssl/certs/ca-certificates.crt
test "$(id -u)" -ne 0
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' curl)" ge 8.21.0
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libacl1)" ge 2.4.0-1+wmsecurity1
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libtinfo6)" ge 6.5+20250216-2+wmsecurity1
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' util-linux)" ge 2.41.5-0+deb13u1+wmsecurity1
perl -MArchive::Tar -e 'exit(Archive::Tar->VERSION ge q(3.14) ? 0 : 1)'
npm --version | awk -F. '$1 > 12 || ($1 == 12 && $2 >= 2) { ok=1 } END { exit !ok }'
node -e 'const {createRequire}=require("node:module"); const npm=createRequire("/usr/local/lib/node_modules/npm/package.json"); if(npm("undici/package.json").version!=="8.12.3"||npm("ip-address/package.json").version!=="10.7.5")process.exit(1)'
runtime_modules="$(find /opt/executor/node_modules -type d -path '*/runtime/node_modules' -print -quit)"
node -e 'const sharp=require(process.argv[1]); if(sharp.versions.sharp!=="0.35.5"||sharp.versions.rsvg!=="2.63.2")process.exit(1)' "$runtime_modules/sharp"
test -z "$(find /usr -xdev -type f -perm /6000 -print -quit)"

wm_helpers=0
while IFS= read -r -d '' wm_helper; do
  "$wm_helper" --version
  wm_helpers=$((wm_helpers + 1))
done < <(find /opt/executor -type f \( -path '*/git/bin/git' -o -path '*/bin/workerd' \) -print0)
test "$wm_helpers" -ge 2
