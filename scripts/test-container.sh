#!/usr/bin/env bash
set -euo pipefail
trap 'printf "Container smoke failed at line %s\n" "$LINENO" >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
case "${1:-}" in
  '') build_image=true ;;
  --skip-build) build_image=false ;;
  *) printf '%s\n' 'usage: scripts/test-container.sh [--skip-build]' >&2; exit 64 ;;
esac
command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'Docker is required for the container smoke test.' >&2
  exit 69
}
docker info >/dev/null

suffix="$$"
workspace_a="smoke-a-${suffix}"
workspace_b="smoke-b-${suffix}"
container_a="wovenmatter-${workspace_a}"
container_b="wovenmatter-${workspace_b}"
volume_a="wovenmatter-${workspace_a}-home"
volume_b="wovenmatter-${workspace_b}-home"
legacy_workspace="legacy-${suffix}"
legacy_container="wovenmatter-${legacy_workspace}"
legacy_data="$(mktemp -d "${TMPDIR:-/tmp}/wovenmatter-legacy-storage.XXXXXX")"
base_port=$((20000 + (suffix % 18000)))
port_a="$base_port"
port_b=$((base_port + 1))
token_a="$(openssl rand -hex 32)"
token_b="$(openssl rand -hex 32)"

cleanup() {
  docker rm --force "$container_a" "$container_b" "$legacy_container" >/dev/null 2>&1 || true
  docker volume rm "$volume_a" "$volume_b" >/dev/null 2>&1 || true
  docker network rm "wovenmatter-$workspace_a" "wovenmatter-$workspace_b" >/dev/null 2>&1 || true
  rm -rf -- "$legacy_data"
}
trap cleanup EXIT HUP INT TERM
cleanup
mkdir -p "$legacy_data"

if [ "$build_image" = true ]; then
  docker build --pull --no-cache --tag wovenmatter/workspace:latest --file remote/Dockerfile .
fi
WOVENMATTER_API_TOKEN="$token_a" \
  scripts/remote-workspace.sh create "$workspace_a" "$port_a" >/dev/null
WOVENMATTER_API_TOKEN="$token_b" \
  scripts/remote-workspace.sh create "$workspace_b" "$port_b" >/dev/null

wait_for_health() {
  local port="$1" token="$2" deadline=$((SECONDS + 30))
  until curl -fsS -H "Authorization: Bearer ${token}" \
      "http://127.0.0.1:${port}/v1/health" >/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || {
      printf 'Workspace service on port %s did not become ready.\n' "$port" >&2
      return 1
    }
    sleep 1
  done
}

wait_for_health "$port_a" "$token_a"
wait_for_health "$port_b" "$token_b"
printf '%s\n' 'Checking API authentication and persistent home ownership.'
[ "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port_a}/v1/health")" = 401 ]
[ "$(docker inspect -f '{{.State.Running}}' "$container_a")" = true ]
[ "$(docker inspect -f '{{.State.Running}}' "$container_b")" = true ]
[ "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home"}}{{.Type}}|{{.Name}}{{end}}{{end}}' "$container_a")" = "volume|$volume_a" ]
[ "$(docker exec "$container_a" sh -c 'printf %s "$HOME"')" = /home ]
[ "$(docker exec "$container_a" getent passwd woven | cut -d: -f6)" = /home ]
[ "$(docker exec "$container_a" sh -c 'test -w /home && printf writable')" = writable ]
[ "$(docker inspect -f '{{.HostConfig.PidsLimit}}' "$container_a")" = 512 ]
[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$container_a")" = true ]
[ "$(docker inspect -f '{{.Config.User}}' "$container_a")" = 10001:10001 ]
[ "$(docker exec "$container_a" stat -c '%a' /home/.woven-matter)" = 700 ]
docker exec "$container_a" ssh -V
docker exec "$container_a" node -e 'const {createRequire}=require("node:module"); const npm=createRequire("/usr/local/lib/node_modules/npm/package.json"); for(const name of ["undici","ip-address"]){const expected=require("/opt/wovenmatter/npm-runtime/node_modules/"+name+"/package.json").version; if(npm(name+"/package.json").version!==expected)process.exit(1)}'
printf '%s\n' 'Checking patched system runtimes and excluded vulnerable components.'
docker exec "$container_a" sh -ec '
  python3 -c "import sqlite3, ssl, sys; assert sys.version_info >= (3, 15, 2)"
  dpkg --compare-versions "$(dpkg-query -W -f=\${Version} curl)" ge "8.23.0-1+wmsecurity1"
  perl -MArchive::Tar -e '\''exit(Archive::Tar->VERSION ge "3.14" ? 0 : 1)'\''
  dpkg --compare-versions "$(dpkg-query -W -f=\${Version} libxml2)" ge "2.12.7+dfsg+really2.9.14-2.1+deb13u3+wmsecurity1"
  dpkg --compare-versions "$(dpkg-query -W -f=\${Version} libtiff6)" ge "4.7.2-1"
  dpkg --compare-versions "$(dpkg-query -W -f=\${Version} libacl1)" ge "2.4.0-1"
  dpkg --compare-versions "$(dpkg-query -W -f=\${Version} util-linux)" ge "2.41.5-0+deb13u1+wmsecurity1"
  command -v chromium >/dev/null
  ! command -v cupsd >/dev/null
  ! command -v systemd-homed >/dev/null
  ! command -v tiffcrop >/dev/null
  ! command -v thunderbird >/dev/null
  ! command -v xdg-email >/dev/null
  ! python3 -c "import libxml2" >/dev/null 2>&1
  ! find /usr -xdev -type f -perm /6000 -print -quit | grep -q .
'

# Even possession of the other workspace's API token cannot cross its bridge.
ip_a="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_a")"
if docker exec "$container_b" curl -fsS --connect-timeout 2 --max-time 3 \
  -H "Authorization: Bearer $token_a" "http://${ip_a}:7337/v1/health" >/dev/null 2>&1; then
  printf '%s\n' 'workspace networks unexpectedly allow sibling API access' >&2
  exit 1
fi


docker exec "$container_a" sh -c 'printf persistent > "$HOME/.woven-matter/smoke-marker"'
printf '%s\n' 'Checking storage reporting and restart/update preservation.'
status="$(scripts/remote-workspace.sh status "$workspace_a")"
if ! jq -e '
  .storageKind == "named-volume"
  and .legacyStorage == false
  and .swapMode == "default"
  and .storageUsedBytes > 0
  and .hostStorageCapacityBytes > 0
  and .hostStorageAvailableBytes >= 0
' <<< "$status" >/dev/null; then
  jq '{storageKind, legacyStorage, swapMode, storageUsedBytes, hostStorageCapacityBytes, hostStorageAvailableBytes}' <<< "$status" >&2
  docker exec "$container_a" sh -c 'stat -c "%a %u:%g %n" /home /home/node 2>/dev/null; du -sk /home' >&2 || true
  exit 1
fi
scripts/remote-workspace.sh restart "$workspace_a" >/dev/null
wait_for_health "$port_a" "$token_a"
[ "$(docker exec "$container_a" cat /home/.woven-matter/smoke-marker)" = persistent ]

scripts/remote-workspace.sh update "$workspace_a" wovenmatter/workspace:latest "" "" "$port_a" >/dev/null
wait_for_health "$port_a" "$token_a"
[ "$(docker exec "$container_a" cat /home/.woven-matter/smoke-marker)" = persistent ]

delete_status="$(scripts/remote-workspace.sh delete "$workspace_a")"
printf '%s\n' 'Checking explicit data deletion and legacy storage safety.'
jq -e '.persistentDataRemoved == false' <<< "$delete_status" >/dev/null
docker volume inspect "$volume_a" >/dev/null
WOVENMATTER_API_TOKEN="$token_a" \
  scripts/remote-workspace.sh create "$workspace_a" "$port_a" >/dev/null
wait_for_health "$port_a" "$token_a"
[ "$(docker exec "$container_a" cat /home/.woven-matter/smoke-marker)" = persistent ]

printf legacy > "$legacy_data/marker"
docker create --name "$legacy_container" \
  --label "com.wovenmatter.workspace=${legacy_workspace}" \
  --volume "$legacy_data:/home/legacy" \
  --entrypoint /bin/true wovenmatter/workspace:latest >/dev/null
if scripts/remote-workspace.sh delete "$legacy_workspace" --data \
  >"$legacy_data/delete.out" 2>"$legacy_data/delete.err"; then
  printf '%s\n' 'legacy storage deletion unexpectedly succeeded' >&2
  exit 1
fi
jq -e '.error == "legacy_storage_migration_required"' "$legacy_data/delete.err" >/dev/null
docker container inspect "$legacy_container" >/dev/null
[ "$(cat "$legacy_data/marker")" = legacy ]

delete_status="$(scripts/remote-workspace.sh delete "$workspace_a" --data)"
jq -e '.persistentDataRemoved == true' <<< "$delete_status" >/dev/null
if docker volume inspect "$volume_a" >/dev/null 2>&1; then
  printf '%s\n' 'explicit workspace data deletion left its named volume behind' >&2
  exit 1
fi
scripts/remote-workspace.sh delete "$workspace_b" --data >/dev/null
trap - EXIT HUP INT TERM
cleanup
printf '%s\n' 'Container home, storage reporting, lifecycle persistence, legacy safety, and explicit deletion passed.'
