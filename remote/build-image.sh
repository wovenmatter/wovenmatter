#!/usr/bin/env bash
set -euo pipefail
# Called over SSH with an app-bundle fingerprint. Build stdin is its tar archive.
action="${1:-}"; fingerprint="${2:-}"; force="${3:-false}"
[[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || { echo 'Invalid workspace bundle fingerprint.' >&2; exit 64; }
case "$action:$force" in inspect:false|build:false|build:true) ;; *) exit 64 ;; esac
image_name="${WOVENMATTER_IMAGE_NAME:-wovenmatter/workspace:latest}"
docker_command=(docker)
if ! docker info >/dev/null 2>&1; then
  sudo -n docker info >/dev/null 2>&1 || { echo 'Docker Engine is unavailable.' >&2; exit 69; }
  docker_command=(sudo -n docker)
fi
docker_exec() { "${docker_command[@]}" "$@"; }
current_image() {
  local record id digest built os arch host_arch now
  record="$(docker_exec image inspect --format '{{.Id}}|{{index .Config.Labels "com.wovenmatter.bundle-sha256"}}|{{index .Config.Labels "com.wovenmatter.built-at"}}|{{.Os}}|{{.Architecture}}' "$image_name" 2>/dev/null)" || return 1
  IFS='|' read -r id digest built os arch <<< "$record"
  [[ "$id" =~ ^sha256:[a-f0-9]{64}$ && "$digest" = "$fingerprint" && "$built" =~ ^[0-9]{1,12}$ && "$os" = linux ]] || return 1
  host_arch="$(docker_exec info --format '{{.Architecture}}')"
  case "$host_arch" in x86_64) host_arch=amd64 ;; aarch64) host_arch=arm64 ;; esac
  [ "$arch" = "$host_arch" ] || return 1
  now="$(date +%s)"
  # A matching image is fresh for one day; explicit Update always rebuilds.
  [ "$built" -le "$now" ] && [ "$((now - built))" -lt 86400 ] || return 1
  printf '%s\n' "$id"
}
if [ "$action" = inspect ]; then current_image || printf 'build\n'; exit 0; fi
lock_root="${XDG_RUNTIME_DIR:-/tmp}/wovenmatter-remote-workspace-$(id -u)"
(umask 077; mkdir -p "$lock_root")
[[ -d "$lock_root" && ! -L "$lock_root" && -O "$lock_root" ]] || { echo 'Unsafe image build lock directory.' >&2; exit 73; }
chmod 0700 "$lock_root"
[ ! -L "$lock_root/image-build.lock" ] || { echo 'Unsafe image build lock file.' >&2; exit 73; }
exec 9>"$lock_root/image-build.lock"
printf 'WM_PROGRESS waiting\n' >&2
flock -x 9
if [ "$force" = false ] && image_id="$(current_image)"; then
  cat >/dev/null # Drain an archive already sent while another build held the lock.
  printf 'WM_PROGRESS reused\n' >&2
  printf '%s\n' "$image_id"
  exit 0
fi
image_id_file="$(mktemp "$lock_root/image-id.XXXXXX")"
trap 'rm -f "$image_id_file"' EXIT
printf 'WM_PROGRESS building\n' >&2
docker_exec build --progress=plain --pull --no-cache \
  --label "com.wovenmatter.bundle-sha256=$fingerprint" \
  --label "com.wovenmatter.built-at=$(date +%s)" \
  --iidfile "$image_id_file" --tag "$image_name" --file remote/Dockerfile - >&2
image_id="$(cat "$image_id_file")"
[[ "$image_id" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo 'Docker did not return an image identity.' >&2; exit 70; }
printf 'WM_PROGRESS ready\n' >&2
printf '%s\n' "$image_id"
