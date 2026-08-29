#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
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
token_a="container-smoke-a-${suffix}"
token_b="container-smoke-b-${suffix}"

cleanup() {
  docker rm --force "$container_a" "$container_b" "$legacy_container" >/dev/null 2>&1 || true
  docker volume rm "$volume_a" "$volume_b" >/dev/null 2>&1 || true
  rm -rf -- "$legacy_data"
}
trap cleanup EXIT HUP INT TERM
cleanup
mkdir -p "$legacy_data"

docker build --tag wovenmatter/workspace:0.1 --file remote/Dockerfile .
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
[ "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port_a}/v1/health")" = 401 ]
[ "$(docker inspect -f '{{.State.Running}}' "$container_a")" = true ]
[ "$(docker inspect -f '{{.State.Running}}' "$container_b")" = true ]
[ "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home"}}{{.Type}}|{{.Name}}{{end}}{{end}}' "$container_a")" = "volume|$volume_a" ]
[ "$(docker exec "$container_a" sh -c 'printf %s "$HOME"')" = /home ]
[ "$(docker exec "$container_a" getent passwd woven | cut -d: -f6)" = /home ]
[ "$(docker exec "$container_a" sh -c 'test -w /home && printf writable')" = writable ]

docker exec "$container_a" sh -c 'printf persistent > "$HOME/.woven-matter/.scratch/smoke-marker"'
status="$(scripts/remote-workspace.sh status "$workspace_a")"
jq -e '
  .storageKind == "named-volume"
  and .legacyStorage == false
  and .swapMode == "default"
  and .storageUsedBytes > 0
  and .hostStorageCapacityBytes > 0
  and .hostStorageAvailableBytes >= 0
' <<< "$status" >/dev/null
scripts/remote-workspace.sh restart "$workspace_a" >/dev/null
wait_for_health "$port_a" "$token_a"
[ "$(docker exec "$container_a" cat /home/.woven-matter/.scratch/smoke-marker)" = persistent ]

scripts/remote-workspace.sh update "$workspace_a" wovenmatter/workspace:0.1 "" "" "$port_a" >/dev/null
wait_for_health "$port_a" "$token_a"
[ "$(docker exec "$container_a" cat /home/.woven-matter/.scratch/smoke-marker)" = persistent ]

delete_status="$(scripts/remote-workspace.sh delete "$workspace_a")"
jq -e '.persistentDataRemoved == false' <<< "$delete_status" >/dev/null
docker volume inspect "$volume_a" >/dev/null
WOVENMATTER_API_TOKEN="$token_a" \
  scripts/remote-workspace.sh create "$workspace_a" "$port_a" >/dev/null
wait_for_health "$port_a" "$token_a"
[ "$(docker exec "$container_a" cat /home/.woven-matter/.scratch/smoke-marker)" = persistent ]

printf legacy > "$legacy_data/marker"
docker create --name "$legacy_container" \
  --label "com.wovenmatter.workspace=${legacy_workspace}" \
  --volume "$legacy_data:/home/legacy" \
  --entrypoint /bin/true wovenmatter/workspace:0.1 >/dev/null
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
