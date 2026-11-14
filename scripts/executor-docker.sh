#!/usr/bin/env bash
set -euo pipefail

os_release_file="${WOVENMATTER_OS_RELEASE:-/etc/os-release}"
low_storage_bytes="${WOVENMATTER_LOW_STORAGE_BYTES:-10737418240}"
low_storage_percent="${WOVENMATTER_LOW_STORAGE_PERCENT:-10}"
docker_prefix=()
docker_engine_problem=''
host_capacity=''
host_available=''
host_storage_low=false
host_storage_warning=''

usage() {
  printf '%s\n' 'usage: executor-docker.sh inspect | prepare AUTHORIZED' >&2
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
  local platform components api major minor version engine_major
  docker_engine_problem=''
  if ! local_docker_endpoint; then
    docker_engine_problem='Docker is targeting a remote endpoint. Select a local Docker Engine socket on this SSH host, then inspect again. Remote Docker contexts are not supported for workspace storage and ports.'
    return 1
  fi
  platform="$(docker_exec version --format '{{.Server.Platform.Name}}' 2>/dev/null || true)"
  components="$(docker_exec version --format '{{range .Server.Components}}{{println .Name}}{{end}}' 2>/dev/null || true)"
  case "$platform"$'\n'"$components" in
    *[Pp][Oo][Dd][Mm][Aa][Nn]*)
      docker_engine_problem='This host is using Podman through a Docker compatibility command. Install Docker Engine alongside it without replacing existing containers, then inspect again.'
      return 1 ;;
  esac
  # Docker/Moby distribution packages (including Arch/Omarchy) may leave the
  # optional branding field empty. The Engine component identifies the daemon.
  if [[ "$platform" != *"Docker Engine"* ]] \
    && [[ $'\n'"$components"$'\n' != *$'\nEngine\n'* ]]; then
    docker_engine_problem="The container runtime could not be identified as Docker Engine (reported name: ${platform:-not provided}). Install Docker Engine on this host, then inspect again. Docker-compatible command shims are not supported."
    return 1
  fi
  api="$(docker_exec version --format '{{.Server.APIVersion}}' 2>/dev/null || true)"
  # Docker <28 can expose localhost-published ports to adjacent LAN hosts.
  version="$(docker_exec version --format '{{.Server.Version}}' 2>/dev/null || true)"
  engine_major="${version%%.*}"
  if ! [[ "$engine_major" =~ ^[0-9]+$ ]] || [ "$engine_major" -lt 28 ]; then
    docker_engine_problem="Workspaces require Docker Engine 28 or newer to keep published ports private. Update Docker Engine on this host, then inspect again."
    return 1
  fi
  if ! [[ "$api" =~ ^[0-9]+\.[0-9]+$ ]]; then
    docker_engine_problem='Docker answered, but its Engine API version could not be read. Check docker version using this SSH account, then inspect again.'
    return 1
  fi
  major="${api%%.*}"
  minor="${api#*.}"
  if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 41 ]; }; then
    docker_engine_problem="This host reports Docker Engine API ${api}; workspaces require API 1.41 or newer. Update Docker Engine on this host, then inspect again."
    return 1
  fi
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
  [ "$(uname -s 2>/dev/null || true)" = Linux ] || blockers+=("Executor requires a Linux host.")
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
    [ "$engine_supported" = true ] || blockers+=("$docker_engine_problem")
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

command="${1:-}"
[ -n "$command" ] || usage
shift
case "$command" in
  inspect) inspect_host "$@" ;;
  prepare) prepare_host "$@" ;;
  *) usage ;;
esac
