#!/usr/bin/env bash
set -euo pipefail

image_name='wovenmatter/workspace:0.1'
os_release_file="${WOVENMATTER_OS_RELEASE:-/etc/os-release}"
low_storage_bytes="${WOVENMATTER_LOW_STORAGE_BYTES:-10737418240}"
low_storage_percent="${WOVENMATTER_LOW_STORAGE_PERCENT:-10}"
active_lock=''
docker_prefix=()
host_capacity=''
host_available=''
host_storage_low=false
host_storage_warning=''
workspace_storage_kind='unavailable'
workspace_storage_source=''
workspace_storage_destination=''
workspace_storage_legacy=true
workspace_storage_used=''

usage() {
  printf '%s\n' 'usage: remote-workspace.sh inspect | prepare AUTHORIZED | create ID PORT [MEMORY_BYTES] [MEMORY_AND_SWAP_BYTES] | status ID | start ID | stop ID | restart ID | update ID IMAGE [MEMORY_BYTES] [MEMORY_AND_SWAP_BYTES] [PORT] | delete ID [--data]' >&2
  exit 64
}

json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

json_optional_string() {
  if [ -n "$1" ]; then json_string "$1"; else printf null; fi
}

json_optional_number() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf null; fi
}

json_array() {
  local value separator=''
  printf '['
  for value in "$@"; do
    [ -n "$value" ] || continue
    printf '%s' "$separator"
    json_string "$value"
    separator=','
  done
  printf ']'
}

fail() {
  local error="$1" detail="$2" status="${3:-64}"
  {
    printf '{"error":'
    json_string "$error"
    printf ',"detail":'
    json_string "$detail"
    printf '}\n'
  } >&2
  exit "$status"
}

validate_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || fail \
    "invalid_workspace_id" \
    "Use 1-48 lowercase letters, digits, or hyphens, beginning with a letter or digit."
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ] || fail \
    "invalid_loopback_port" \
    "The remote loopback port must be between 1024 and 65535."
}

validate_optional_bytes() {
  local value="$1" label="$2"
  [ -z "$value" ] || [[ "$value" =~ ^[0-9]+$ ]] || fail \
    "invalid_resource_limit" "$label must be an unsigned byte count."
}

container_name() { printf 'wovenmatter-%s' "$1"; }
volume_name() { printf 'wovenmatter-%s-home' "$1"; }

release_lock() {
  if [ -n "$active_lock" ]; then
    rmdir "$active_lock" >/dev/null 2>&1 || true
    active_lock=''
  fi
}

acquire_lock() {
  local id="$1" lock_root lock_path attempt
  lock_root="${XDG_RUNTIME_DIR:-/tmp}/wovenmatter-remote-workspace-$(id -u)"
  (umask 077 && mkdir -p "$lock_root")
  chmod 700 "$lock_root" >/dev/null 2>&1 || true
  lock_path="${lock_root}/${id}.lock"
  for ((attempt = 0; attempt < 100; attempt += 1)); do
    if mkdir "$lock_path" >/dev/null 2>&1; then
      active_lock="$lock_path"
      trap release_lock EXIT HUP INT TERM
      return
    fi
    sleep 0.1
  done
  fail "workspace_busy" "Another operation is already changing this workspace." 75
}

can_elevate() {
  [ "$(id -u)" -eq 0 ] || {
    command -v sudo >/dev/null 2>&1 \
      && sudo -n sh -c 'exit 0' >/dev/null 2>&1
  }
}

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi
}

select_docker() {
  docker_prefix=()
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker_prefix=(docker)
  elif command -v docker >/dev/null 2>&1 && can_elevate \
    && sudo -n docker info >/dev/null 2>&1; then
    docker_prefix=(sudo -n docker)
  else
    return 1
  fi
}

docker_exec() { "${docker_prefix[@]}" "$@"; }

docker_info_value() {
  docker_exec info --format "{{.$1}}" 2>/dev/null || true
}

docker_engine_supported() {
  local platform api major minor
  local_docker_endpoint || return 1
  platform="$(docker_exec version --format '{{.Server.Platform.Name}}' 2>/dev/null || true)"
  api="$(docker_exec version --format '{{.Server.APIVersion}}' 2>/dev/null || true)"
  [[ "$platform" == *"Docker Engine"* ]] || return 1
  [[ "$api" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
  major="${api%%.*}"
  minor="${api#*.}"
  [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 41 ]; }
}

local_docker_endpoint() {
  local context endpoint
  case "${DOCKER_HOST:-}" in
    ''|unix://*) ;;
    *) return 1 ;;
  esac
  context="$(docker_exec context show 2>/dev/null || true)"
  [ -n "$context" ] || return 0
  endpoint="$(docker_exec context inspect --format '{{.Endpoints.docker.Host}}' "$context" 2>/dev/null || true)"
  [ -z "$endpoint" ] || [[ "$endpoint" == unix://* ]]
}

require_docker() {
  command -v docker >/dev/null 2>&1 || fail \
    "container_runtime_missing" \
    "Docker Engine is not installed. Inspect and authorize host preparation first." 69
  select_docker || fail \
    "container_runtime_unavailable" \
    "Docker Engine is installed but unavailable. Inspect and authorize host preparation first." 69
  docker_engine_supported || fail \
    "unsupported_container_runtime" \
    "Woven Matter requires Docker Engine API 1.41 or newer; Docker-compatible command shims are not supported." 69
}

is_rootless() {
  local security
  security="$(docker_exec info --format '{{json .SecurityOptions}}' 2>/dev/null || true)"
  [[ "$security" == *rootless* ]]
}

docker_capability() { [ "$(docker_info_value "$1")" = true ]; }

memory_capable() {
  docker_capability MemoryLimit || return 1
  if is_rootless; then
    [ "$(docker_info_value CgroupVersion)" = 2 ] || return 1
    [ "$(docker_info_value CgroupDriver)" = systemd ] || return 1
  fi
}

swap_capable() { memory_capable && docker_capability SwapLimit; }

parse_df_metrics() {
  local output="$1" blocks available
  read -r blocks available < <(awk 'NR > 1 { print $2, $4; exit }' <<< "$output")
  [[ "${blocks:-}" =~ ^[0-9]+$ ]] && [[ "${available:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s\n' "$((blocks * 1024))" "$((available * 1024))"
}

path_df_metrics() {
  local path="$1" output parsed
  [[ "$path" == /* ]] || return 1
  if output="$(LC_ALL=C df -Pk "$path" 2>/dev/null)"; then
    parsed="$(parse_df_metrics "$output")" || return 1
  elif can_elevate && output="$(run_privileged df -Pk "$path" 2>/dev/null)"; then
    parsed="$(parse_df_metrics "$output")" || return 1
  else
    return 1
  fi
  printf '%s\n' "$parsed"
}

set_host_storage_state() {
  local percent_threshold
  host_storage_low=false
  host_storage_warning=''
  [[ "$host_capacity" =~ ^[0-9]+$ ]] || return
  [[ "$host_available" =~ ^[0-9]+$ ]] || return
  [[ "$low_storage_bytes" =~ ^[0-9]+$ ]] || low_storage_bytes=10737418240
  if ! [[ "$low_storage_percent" =~ ^[0-9]+$ ]] \
    || [ "$low_storage_percent" -gt 100 ]; then
    low_storage_percent=10
  fi
  percent_threshold="$((host_capacity / 100 * low_storage_percent))"
  if [ "$host_available" -lt "$low_storage_bytes" ] \
    || [ "$host_available" -lt "$percent_threshold" ]; then
    host_storage_low=true
    host_storage_warning='The remote host is running low on disk space. Workspace writes may fail if available storage is exhausted.'
  fi
}

refresh_host_storage_metrics() {
  local root metrics
  host_capacity=''
  host_available=''
  host_storage_low=false
  host_storage_warning=''
  select_docker || return 0
  local_docker_endpoint || return 0
  root="$(docker_info_value DockerRootDir)"
  metrics="$(path_df_metrics "$root" 2>/dev/null || true)"
  if [[ "$metrics" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
    host_capacity="${BASH_REMATCH[1]}"
    host_available="${BASH_REMATCH[2]}"
  fi
  set_host_storage_state
}

read_os_release() {
  os_id=''
  os_version=''
  os_codename=''
  if [ -r "$os_release_file" ]; then
    # shellcheck disable=SC1090
    . "$os_release_file"
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
    os_codename="${VERSION_CODENAME:-}"
  fi
}

apt_conflicts() {
  local package status conflicts=''
  command -v dpkg-query >/dev/null 2>&1 || return
  for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
    if [ "$status" = 'install ok installed' ]; then
      conflicts="${conflicts:+${conflicts}, }${package}"
    fi
  done
  printf '%s' "$conflicts"
}

inspect_host() {
  [ "$#" -eq 0 ] || usage
  local architecture os_type='' version='' runtime_ready=false engine_supported=false
  local ready=false memory=false swap=false privilege=false supported_arch=false
  local supported_install=false conflicts install_label=''
  local -a actions=('') blockers=('') limitations=('')
  read_os_release
  architecture="$(uname -m 2>/dev/null || printf unknown)"
  case "$architecture" in
    amd64|x86_64|arm64|aarch64) supported_arch=true ;;
    *) blockers+=("The pinned workspace image supports amd64 and arm64 Linux hosts; this host reports ${architecture}.") ;;
  esac
  [ "$(uname -s 2>/dev/null || true)" = Linux ] || blockers+=("Remote workspaces require Linux.")
  can_elevate && privilege=true

  if select_docker; then
    runtime_ready=true
    docker_engine_supported && engine_supported=true
    version="$(docker_exec version --format '{{.Server.Version}}' 2>/dev/null || true)"
    os_type="$(docker_info_value OSType)"
    memory_capable && memory=true
    swap_capable && swap=true
    [ "$memory" = true ] || limitations+=("Memory limits are unavailable in this Docker and cgroup configuration.")
    [ "$swap" = true ] || limitations+=("Swap limits are unavailable in this Docker, kernel, or cgroup configuration.")
    [ "$engine_supported" = true ] || blockers+=("Woven Matter requires a local Docker Engine API 1.41 or newer. Docker-compatible command shims such as Podman and remote Docker contexts are not supported by this lifecycle implementation.")
    refresh_host_storage_metrics
    if [ -z "$host_capacity" ]; then
      limitations+=("Host storage capacity could not be measured safely.")
    fi
  elif command -v docker >/dev/null 2>&1; then
    if [ "$privilege" = true ] && command -v systemctl >/dev/null 2>&1; then
      actions+=("Enable and start the existing Docker Engine systemd service.")
    else
      blockers+=("Docker is installed but unavailable to this SSH account, and Woven Matter cannot start or access it automatically.")
    fi
  else
    case "$os_id" in
      ubuntu) supported_install=true; install_label='Ubuntu' ;;
      debian) supported_install=true; install_label='Debian' ;;
    esac
    if [ "$supported_install" != true ]; then
      blockers+=("Automatic Docker installation currently supports Ubuntu and Debian. Install Docker Engine manually on this ${os_id:-unknown} host, then inspect again.")
    elif [ "$privilege" != true ]; then
      blockers+=("Docker is missing, and automatic preparation requires root SSH or passwordless sudo.")
    elif [ -z "$os_codename" ]; then
      blockers+=("The ${install_label} release codename is unavailable, so Woven Matter cannot configure Docker's repository safely.")
    else
      conflicts="$(apt_conflicts)"
      if [ -n "$conflicts" ]; then
        blockers+=("Conflicting container packages are installed (${conflicts}). Woven Matter will not remove them automatically.")
      else
        actions+=("Install ca-certificates and curl with apt.")
        actions+=("Add Docker's official signing key at /etc/apt/keyrings/docker.asc.")
        actions+=("Add Docker's official stable apt source at /etc/apt/sources.list.d/docker.sources.")
        actions+=("Install docker-ce, docker-ce-cli, containerd.io, and docker-buildx-plugin.")
        actions+=("Enable and start docker.service.")
      fi
    fi
  fi

  if [ "$runtime_ready" = true ] && [ "$engine_supported" = true ] \
    && [ "$supported_arch" = true ] && [ "$os_type" = linux ]; then ready=true; fi
  local can_prepare=false preparation_required=false
  [ "${#actions[@]}" -gt 1 ] && preparation_required=true
  if [ "$preparation_required" = true ] && [ "${#blockers[@]}" -eq 1 ] \
    && [ "$privilege" = true ]; then can_prepare=true; fi
  if [ "${#blockers[@]}" -gt 1 ]; then limitations+=("${blockers[@]:1}"); fi

  printf '{"ready":%s,"runtime":"docker","version":' "$ready"
  json_string "$version"
  printf ',"architecture":'
  json_string "$architecture"
  printf ',"capabilities":{"memory":%s,"swap":%s},"limitations":' "$memory" "$swap"
  json_array "${limitations[@]}"
  printf ',"hostStorageCapacityBytes":'
  json_optional_number "$host_capacity"
  printf ',"hostStorageAvailableBytes":'
  json_optional_number "$host_available"
  printf ',"hostStorageLow":%s,"storageWarning":' "$host_storage_low"
  json_optional_string "$host_storage_warning"
  printf ',"canPrepare":%s,"preparationRequired":%s,"preparationActions":' "$can_prepare" "$preparation_required"
  json_array "${actions[@]}"
  printf ',"blockingIssues":'
  json_array "${blockers[@]}"
  printf '}\n'
}

install_docker_apt() {
  read_os_release
  [ "$os_id" = ubuntu ] || [ "$os_id" = debian ] || fail \
    "unsupported_host_preparation" \
    "Automatic Docker installation currently supports Ubuntu and Debian."
  [ -n "$os_codename" ] || fail \
    "unsupported_host_preparation" "The distribution release codename is unavailable."
  [ -z "$(apt_conflicts)" ] || fail \
    "conflicting_container_packages" \
    "Conflicting container packages are installed; Woven Matter will not remove them."
  run_privileged apt-get update >/dev/null
  run_privileged env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y ca-certificates curl >/dev/null
  run_privileged install -m 0755 -d /etc/apt/keyrings >/dev/null
  run_privileged curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" \
    -o /etc/apt/keyrings/docker.asc
  run_privileged chmod a+r /etc/apt/keyrings/docker.asc >/dev/null
  local architecture
  architecture="$(dpkg --print-architecture)"
  run_privileged sh -c 'cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/'"$os_id"'
Suites: '"$os_codename"'
Components: stable
Architectures: '"$architecture"'
Signed-By: /etc/apt/keyrings/docker.asc
EOF' >/dev/null
  run_privileged apt-get update >/dev/null
  run_privileged env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null
}

prepare_host() {
  [ "$#" -eq 1 ] || usage
  local authorization="$1"
  [ "$authorization" = AUTHORIZED ] || fail \
    "host_preparation_not_authorized" \
    "Host preparation requires explicit authorization from the Woven Matter UI."
  can_elevate || fail \
    "host_preparation_requires_admin" \
    "Host preparation requires root SSH or passwordless sudo."
  if ! command -v docker >/dev/null 2>&1; then install_docker_apt; fi
  if ! select_docker; then
    if command -v systemctl >/dev/null 2>&1; then
      run_privileged systemctl enable --now docker.service >/dev/null
    elif command -v service >/dev/null 2>&1; then
      run_privileged service docker start >/dev/null
    fi
  fi
  select_docker || fail \
    "container_runtime_unavailable" \
    "Docker Engine is still unavailable after preparation."
  inspect_host
}

validate_container_resources() {
  local memory="$1" memory_and_swap="$2"
  if [ -n "$memory" ] && [ "$memory" -gt 0 ]; then
    memory_capable || fail \
      "memory_limit_unsupported" \
      "This Docker and cgroup configuration cannot enforce a memory limit."
  fi
  if [ -n "$memory_and_swap" ] && [ "$memory_and_swap" -gt 0 ]; then
    [ -n "$memory" ] && [ "$memory" -gt 0 ] || fail \
      "invalid_resource_limit" "Additional swap requires a Memory limit."
    [ "$memory_and_swap" -ge "$memory" ] || fail \
      "invalid_resource_limit" \
      "The combined memory-and-swap limit cannot be lower than Memory."
    swap_capable || fail \
      "swap_limit_unsupported" \
      "This Docker, kernel, or cgroup configuration cannot enforce a swap limit."
  fi
}

container_args=()
build_container_args() {
  local operation="$1" name="$2" id="$3" port="$4" token="$5"
  local memory="$6" memory_and_swap="$7" volume="$8" image="$9"
  local swap_mode=default
  if [ "$memory_and_swap" = -1 ]; then
    swap_mode=unlimited
  elif [ -n "$memory" ] && [ "$memory" -gt 0 ] \
    && [ -n "$memory_and_swap" ] && [ "$memory_and_swap" -gt 0 ]; then
    if [ "$memory_and_swap" -eq "$memory" ]; then
      swap_mode=disabled
    else
      swap_mode=additional
    fi
  fi
  container_args=(
    "$operation" --name "$name" --restart unless-stopped
    --read-only --cap-drop ALL --security-opt no-new-privileges:true
    --tmpfs /tmp:rw,noexec,nosuid,size=256m
    --tmpfs /run:rw,noexec,nosuid,size=16m
    --publish "127.0.0.1:${port}:7337"
    --log-driver local --log-opt max-size=20m --log-opt max-file=5
    --env "WOVENMATTER_API_TOKEN=${token}"
    --env HOME=/home
    --env WOVENMATTER_WORKSPACE=/home/.woven-matter
    --label "com.wovenmatter.workspace=${id}"
    --label "com.wovenmatter.host-port=${port}"
    --label "com.wovenmatter.storage-kind=named-volume"
    --label "com.wovenmatter.swap-mode=${swap_mode}"
    --volume "${volume}:/home"
  )
  if [ -n "$memory" ] && [ "$memory" -gt 0 ]; then container_args+=(--memory "$memory"); fi
  if [ -n "$memory_and_swap" ] && {
    [ "$memory_and_swap" -gt 0 ] || [ "$memory_and_swap" -eq -1 ]
  }; then container_args+=(--memory-swap "$memory_and_swap"); fi
  container_args+=("$image")
}

validate_workspace_volume() {
  local volume="$1" id="$2" owner driver
  if docker_exec volume inspect "$volume" >/dev/null 2>&1; then
    owner="$(docker_exec volume inspect --format '{{index .Labels "com.wovenmatter.workspace"}}' "$volume" 2>/dev/null || true)"
    driver="$(docker_exec volume inspect --format '{{.Driver}}' "$volume" 2>/dev/null || true)"
    if { [ -z "$owner" ] || [ "$owner" = '<no value>' ]; } \
      && [ "$driver" = local ]; then
      fail "legacy_storage_migration_required" \
        "An unlabeled volume with this workspace name already exists and may contain legacy data. It was left unchanged and requires an explicit migration."
    fi
    [ "$owner" = "$id" ] || fail \
      "workspace_volume_conflict" \
      "A volume with the workspace name already exists but is not owned by this workspace."
    [ "$driver" = local ] || fail \
      "workspace_volume_conflict" \
      "The workspace volume exists but does not use Docker's local volume driver."
  else
    docker_exec volume create \
      --label "com.wovenmatter.workspace=${id}" \
      --label 'com.wovenmatter.mount=/home' \
      "$volume" >/dev/null
  fi
}

create_workspace() {
  [ "$#" -ge 2 ] && [ "$#" -le 4 ] || usage
  local id="$1" port="$2" token="${WOVENMATTER_API_TOKEN:-}" memory="${3:-}"
  local memory_and_swap="${4:-}" name volume output
  validate_id "$id"
  validate_port "$port"
  [ -n "$token" ] || fail "missing_api_token" "The workspace API token is empty."
  validate_optional_bytes "$memory" "Memory limit"
  validate_optional_bytes "$memory_and_swap" "Memory-and-swap limit"
  require_docker
  acquire_lock "$id"
  validate_container_resources "$memory" "$memory_and_swap"
  docker_exec image inspect "$image_name" >/dev/null 2>&1 || fail \
    "workspace_image_missing" \
    "Provision the pinned workspace image before creating a workspace."
  name="$(container_name "$id")"
  volume="$(volume_name "$id")"
  docker_exec container inspect "$name" >/dev/null 2>&1 && fail \
    "workspace_exists" "A workspace container with this ID already exists." 73
  validate_workspace_volume "$volume" "$id"
  build_container_args run "$name" "$id" "$port" "$token" \
    "$memory" "$memory_and_swap" "$volume" "$image_name"
  container_args=(run --detach "${container_args[@]:1}")
  if ! output="$(docker_exec "${container_args[@]}" 2>&1)"; then
    fail "workspace_create_failed" \
      "${output} The persistent workspace volume was preserved." 70
  fi
  if ! wait_for_healthy "$name"; then
    docker_exec rm --force "$name" >/dev/null 2>&1 || true
    fail "workspace_create_failed" \
      "The container did not become healthy. Its persistent workspace volume was preserved." 70
  fi
  status_workspace "$id"
}

inspect_value() {
  local name="$1" format="$2"
  docker_exec container inspect --format "$format" "$name"
}

detect_workspace_storage() {
  local name="$1" id="$2" expected mounts type volume driver source destination
  local owner='' legacy_kind='' legacy_source='' legacy_destination=''
  expected="$(volume_name "$id")"
  workspace_storage_kind='unavailable'
  workspace_storage_source=''
  workspace_storage_destination=''
  workspace_storage_legacy=true
  mounts="$(inspect_value "$name" '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Driver}}|{{.Source}}|{{.Destination}}{{println}}{{end}}' 2>/dev/null || true)"
  while IFS='|' read -r type volume driver source destination; do
    [ -n "$type" ] || continue
    if [ "$destination" = /home ]; then
      workspace_storage_source="${volume:-$source}"
      workspace_storage_destination="$destination"
      if [ "$type" = volume ] && [ "$volume" = "$expected" ] \
        && [ "$driver" = local ]; then
        owner="$(docker_exec volume inspect --format '{{index .Labels "com.wovenmatter.workspace"}}' "$volume" 2>/dev/null || true)"
        if [ "$owner" = "$id" ]; then
          workspace_storage_kind='named-volume'
          workspace_storage_legacy=false
        else
          workspace_storage_kind='legacy-volume'
        fi
      elif [ "$type" = bind ]; then workspace_storage_kind='legacy-bind'
      else workspace_storage_kind='legacy-volume'
      fi
      return
    fi
    if [[ "$destination" == /home/* ]] && [ -z "$legacy_kind" ]; then
      if [ "$type" = bind ]; then legacy_kind='legacy-bind'; else legacy_kind='legacy-volume'; fi
      legacy_source="${volume:-$source}"
      legacy_destination="$destination"
    fi
  done <<< "$mounts"
  if [ -n "$legacy_kind" ]; then
    workspace_storage_kind="$legacy_kind"
    workspace_storage_source="$legacy_source"
    workspace_storage_destination="$legacy_destination"
  fi
}

path_usage_bytes() {
  local path="$1" output blocks
  [[ "$path" == /* ]] || return 1
  command -v timeout >/dev/null 2>&1 || return 1
  if output="$(timeout 15s du -sk "$path" 2>/dev/null)"; then :
  elif can_elevate \
    && output="$(run_privileged timeout 15s du -sk "$path" 2>/dev/null)"; then :
  else return 1
  fi
  blocks="$(awk 'NR == 1 { print $1 }' <<< "$output")"
  [[ "$blocks" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((blocks * 1024))"
}

container_usage_bytes() {
  local name="$1" destination="$2" output blocks
  output="$(docker_exec exec "$name" timeout 15s du -sk "$destination" 2>/dev/null)" || return 1
  blocks="$(awk 'NR == 1 { print $1 }' <<< "$output")"
  [[ "$blocks" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((blocks * 1024))"
}

container_df_metrics() {
  local name="$1" destination="$2" output
  output="$(docker_exec exec "$name" env LC_ALL=C df -Pk "$destination" 2>/dev/null)" || return 1
  parse_df_metrics "$output"
}

measure_workspace_storage() {
  local name="$1" running="$2" metrics=''
  workspace_storage_used=''
  host_capacity=''
  host_available=''
  host_storage_low=false
  host_storage_warning=''
  if [ "$running" = true ] && [ -n "$workspace_storage_destination" ]; then
    workspace_storage_used="$(container_usage_bytes "$name" "$workspace_storage_destination" 2>/dev/null || true)"
    metrics="$(container_df_metrics "$name" "$workspace_storage_destination" 2>/dev/null || true)"
  elif [ "$workspace_storage_kind" = legacy-bind ]; then
    workspace_storage_used="$(path_usage_bytes "$workspace_storage_source" 2>/dev/null || true)"
    metrics="$(path_df_metrics "$workspace_storage_source" 2>/dev/null || true)"
  fi
  if [[ "$metrics" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
    host_capacity="${BASH_REMATCH[1]}"
    host_available="${BASH_REMATCH[2]}"
    set_host_storage_state
  else refresh_host_storage_metrics
  fi
}

append_storage_warning() {
  if [ -n "$1" ]; then
    host_storage_warning="${host_storage_warning:+${host_storage_warning} }$1"
  fi
}

status_workspace() {
  [ "$#" -eq 1 ] || usage
  local id="$1" name container_id state running health started_at image
  local memory memory_and_swap additional_swap swap_mode host_port inspect_error
  validate_id "$id"
  require_docker
  name="$(container_name "$id")"
  if ! inspect_error="$(docker_exec container inspect "$name" 2>&1)"; then
    fail "workspace_not_found" "$inspect_error" 66
  fi
  container_id="$(inspect_value "$name" '{{.Id}}')"
  state="$(inspect_value "$name" '{{.State.Status}}')"
  running="$(inspect_value "$name" '{{.State.Running}}')"
  health="$(inspect_value "$name" '{{if .State.Health}}{{.State.Health.Status}}{{end}}')"
  started_at="$(inspect_value "$name" '{{.State.StartedAt}}')"
  image="$(inspect_value "$name" '{{.Config.Image}}')"
  memory="$(inspect_value "$name" '{{.HostConfig.Memory}}')"
  memory_and_swap="$(inspect_value "$name" '{{.HostConfig.MemorySwap}}')"
  swap_mode="$(inspect_value "$name" '{{index .Config.Labels "com.wovenmatter.swap-mode"}}')"
  host_port="$(inspect_value "$name" '{{index .Config.Labels "com.wovenmatter.host-port"}}')"
  [[ "$memory" =~ ^-?[0-9]+$ ]] || memory=0
  [[ "$memory_and_swap" =~ ^-?[0-9]+$ ]] || memory_and_swap=0
  [[ "$host_port" =~ ^[0-9]+$ ]] || host_port=0
  case "$swap_mode" in
    default|disabled|additional|unlimited) ;;
    *)
      if [ "$memory_and_swap" -lt 0 ]; then swap_mode=unlimited
      elif [ "$memory" -gt 0 ] && [ "$memory_and_swap" -eq "$memory" ]; then swap_mode=disabled
      elif [ "$memory" -gt 0 ] && [ "$memory_and_swap" -gt "$memory" ]; then swap_mode=additional
      else swap_mode=default
      fi
      ;;
  esac
  if [ "$swap_mode" = unlimited ]; then additional_swap=-1
  elif [ "$swap_mode" = additional ] && [ "$memory_and_swap" -gt "$memory" ]; then
    additional_swap="$((memory_and_swap - memory))"
  else additional_swap=0
  fi
  detect_workspace_storage "$name" "$id"
  measure_workspace_storage "$name" "$running"
  if [ "$workspace_storage_legacy" = true ]; then
    append_storage_warning 'This legacy workspace does not use the current /home named-volume layout. Its data is preserved, but container recreation requires an explicit migration.'
  fi
  printf '{"id":'
  json_string "$container_id"
  printf ',"name":'
  json_string "$name"
  printf ',"state":'
  json_string "$state"
  printf ',"running":%s,"health":' "$running"
  json_optional_string "$health"
  printf ',"startedAt":'
  json_string "$started_at"
  printf ',"image":'
  json_string "$image"
  printf ',"memoryBytes":%s,"swapBytes":%s,"swapMode":' "$memory" "$additional_swap"
  json_string "$swap_mode"
  printf ',"hostPort":%s,"persistentVolume":' "$host_port"
  json_string "$workspace_storage_source"
  printf ',"capabilities":{"memory":'
  if memory_capable; then printf true; else printf false; fi
  printf ',"swap":'
  if swap_capable; then printf true; else printf false; fi
  printf '},"storageKind":'
  json_string "$workspace_storage_kind"
  printf ',"storageUsedBytes":'
  json_optional_number "$workspace_storage_used"
  printf ',"hostStorageCapacityBytes":'
  json_optional_number "$host_capacity"
  printf ',"hostStorageAvailableBytes":'
  json_optional_number "$host_available"
  printf ',"hostStorageLow":%s,"storageWarning":' "$host_storage_low"
  json_optional_string "$host_storage_warning"
  printf ',"legacyStorage":%s}\n' "$workspace_storage_legacy"
}

lifecycle() {
  [ "$#" -eq 2 ] || usage
  local action="$1" id="$2" name output
  validate_id "$id"
  require_docker
  name="$(container_name "$id")"
  if ! output="$(docker_exec "$action" "$name" 2>&1)"; then
    fail "workspace_lifecycle_failed" "$output" 70
  fi
  status_workspace "$id"
}

wait_for_healthy() {
  local name="$1" attempt state health
  for ((attempt = 0; attempt < 45; attempt += 1)); do
    state="$(inspect_value "$name" '{{.State.Status}}' 2>/dev/null || true)"
    health="$(inspect_value "$name" '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null || true)"
    case "$state" in exited|dead|removing) return 1 ;; esac
    if [ "$state" = running ] && { [ -z "$health" ] || [ "$health" = healthy ]; }; then return 0; fi
    sleep 1
  done
  return 1
}

restore_update() {
  local name="$1" backup="$2" old_running="$3"
  docker_exec rm --force "$name" >/dev/null 2>&1 || true
  docker_exec rename "$backup" "$name" >/dev/null 2>&1 || true
  [ "$old_running" = true ] && docker_exec start "$name" >/dev/null 2>&1 || true
}

update_workspace() {
  [ "$#" -ge 2 ] && [ "$#" -le 5 ] || usage
  local id="$1" image="$2" requested_memory="${3-}"
  local requested_memory_and_swap="${4-}" requested_port="${5-}"
  local name backup token port memory memory_and_swap volume old_running
  local output='' new_started=false
  validate_id "$id"
  [[ "$image" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]+$ ]] || fail \
    "invalid_workspace_image" "The workspace image reference is invalid."
  validate_optional_bytes "$requested_memory" "Memory limit"
  validate_optional_bytes "$requested_memory_and_swap" "Memory-and-swap limit"
  require_docker
  acquire_lock "$id"
  name="$(container_name "$id")"
  volume="$(volume_name "$id")"
  docker_exec image inspect "$image" >/dev/null 2>&1 || fail \
    "workspace_image_missing" "The requested workspace image is not available."
  docker_exec container inspect "$name" >/dev/null 2>&1 || fail \
    "workspace_not_found" "The workspace container does not exist." 66
  detect_workspace_storage "$name" "$id"
  if [ "$workspace_storage_kind" != named-volume ] \
    || [ "$workspace_storage_source" != "$volume" ] \
    || [ "$workspace_storage_destination" != /home ]; then
    fail "legacy_storage_migration_required" \
      "This legacy workspace's data was left unchanged. Migrate it explicitly to the dedicated /home named volume before recreating the container." 78
  fi
  token="$(inspect_value "$name" '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^WOVENMATTER_API_TOKEN=//p' | head -n 1)"
  port="$(inspect_value "$name" '{{index .Config.Labels "com.wovenmatter.host-port"}}')"
  memory="$(inspect_value "$name" '{{.HostConfig.Memory}}')"
  memory_and_swap="$(inspect_value "$name" '{{.HostConfig.MemorySwap}}')"
  old_running="$(inspect_value "$name" '{{.State.Running}}')"
  [ -n "$token" ] || fail "missing_api_token" \
    "The existing workspace container has no API token."
  if [ "$#" -ge 3 ]; then memory="$requested_memory"; fi
  if [ "$#" -ge 4 ]; then memory_and_swap="$requested_memory_and_swap"; fi
  if [ "$#" -ge 5 ]; then port="$requested_port"; fi
  validate_port "$port"
  validate_container_resources "$memory" "$memory_and_swap"
  backup="${name}-rollback-$$"
  if ! output="$(docker_exec rename "$name" "$backup" 2>&1)"; then
    fail "workspace_update_failed" "$output" 70
  fi
  if [ "$old_running" = true ] \
    && ! docker_exec stop "$backup" >/dev/null 2>&1; then
    restore_update "$name" "$backup" "$old_running"
    fail "workspace_update_failed" \
      "The existing container could not be stopped safely." 70
  fi
  build_container_args create "$name" "$id" "$port" "$token" \
    "$memory" "$memory_and_swap" "$volume" "$image"
  if output="$(docker_exec "${container_args[@]}" 2>&1)" \
    && docker_exec start "$name" >/dev/null 2>&1; then new_started=true; fi
  if [ "$new_started" != true ] || ! wait_for_healthy "$name"; then
    restore_update "$name" "$backup" "$old_running"
    fail "workspace_update_failed" \
      "The replacement did not become healthy; the previous container was restored. ${output}" 70
  fi
  [ "$old_running" = true ] || docker_exec stop "$name" >/dev/null 2>&1 || true
  docker_exec rm "$backup" >/dev/null 2>&1 || true
  status_workspace "$id"
}

delete_workspace() {
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
  local id="$1" remove_data="${2:-}" name volume container_existed=false
  local persistent_data_removed=false
  validate_id "$id"
  [ -z "$remove_data" ] || [ "$remove_data" = '--data' ] || usage
  require_docker
  acquire_lock "$id"
  name="$(container_name "$id")"
  volume="$(volume_name "$id")"
  if docker_exec container inspect "$name" >/dev/null 2>&1; then
    container_existed=true
    detect_workspace_storage "$name" "$id"
    if [ "$remove_data" = '--data' ] && {
      [ "$workspace_storage_kind" != named-volume ] \
        || [ "$workspace_storage_source" != "$volume" ] \
        || [ "$workspace_storage_destination" != /home ]
    }; then
      fail "legacy_storage_migration_required" \
        "Woven Matter will not delete legacy, bind-backed, or differently owned workspace data. Migrate or remove it explicitly before deleting workspace data." 78
    fi
    if [ "$remove_data" = '--data' ]; then
      validate_workspace_volume "$volume" "$id"
    fi
    docker_exec rm --force "$name" >/dev/null
  fi
  if [ "$remove_data" = '--data' ] \
    && docker_exec volume inspect "$volume" >/dev/null 2>&1; then
    validate_workspace_volume "$volume" "$id"
    docker_exec volume rm "$volume" >/dev/null
    persistent_data_removed=true
  fi
  printf '{"deleted":true,"id":'
  json_string "$id"
  printf ',"containerExisted":%s,"persistentDataRemoved":%s}\n' \
    "$container_existed" "$persistent_data_removed"
}

command="${1:-}"
[ -n "$command" ] || usage
shift
case "$command" in
  inspect) inspect_host "$@" ;;
  prepare) prepare_host "$@" ;;
  create) create_workspace "$@" ;;
  status) status_workspace "$@" ;;
  start|stop|restart) lifecycle "$command" "$@" ;;
  update) update_workspace "$@" ;;
  delete) delete_workspace "$@" ;;
  *) usage ;;
esac
