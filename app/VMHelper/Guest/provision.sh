#!/bin/bash
# Woven VM guest provisioning, run by systemd (never by hand).
#   first-boot: prepare the data disk, install the pinned Docker Engine, apply
#               Woven's configuration. Retried on every boot until it succeeds.
#   upgrade:    Woven's Update action: guest packages plus the pinned Docker
#               Engine, then the same configuration. The Mac snapshots the
#               disks before and reboots and health-checks the guest after.
# Every step runs under its own time limit, so a hang ends as a failure that
# names the step. The status file carries the step's limit and this boot's ID:
# the Mac enforces the same limit when the guest itself is stuck, and never
# takes an earlier boot's result for this one's.
set -Eeuo pipefail
mode="${1:-first-boot}"
state=/var/lib/woven
data=/var/lib/woven-data
log=/var/log/woven-provision.log
status_file="$state/status.json"
[ "$mode" = upgrade ] && status_file="$state/update.json"
mkdir -p "$state"
exec >>"$log" 2>&1
# shellcheck source=/dev/null
. /etc/woven/versions.env
export DEBIAN_FRONTEND=noninteractive
step="Starting"

status() { # phase step [error [limit-seconds]]
  python3 - "$status_file" "$@" <<'PY'
import json, os, sys
path, phase, step = sys.argv[1:4]
error = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
limit = int(sys.argv[5]) if len(sys.argv) > 5 else None
with open("/proc/sys/kernel/random/boot_id") as handle:
    boot = handle.read().strip()
with open(path + ".tmp", "w") as handle:
    json.dump({"phase": phase, "step": step, "error": error, "timeout": limit, "boot_id": boot}, handle)
os.replace(path + ".tmp", path)
PY
}
fail() { # message
  status failed "$step" "$1"
  exit 1
}
log_tail() { tail -n 4 "$log" | tr '\n' ' ' | cut -c1-600; }
failed() {
  local code=$?
  fail "$step failed (exit $code): $(log_tail)"
}

# run_step SECONDS TITLE FUNCTION: FUNCTION runs in a child of this script
# under `timeout`, which ends the child's whole process group at the limit.
run_step() {
  local limit="$1" code=0
  step="$2"
  echo "--- $step"
  status running "$step" "" "$limit"
  timeout --kill-after=30 "$limit" "$0" "$mode" --step "$3" || code=$?
  case "$code" in
    0) ;;
    124 | 137) fail "$step did not finish within $((limit / 60)) minutes." ;;
    *) fail "$step failed (exit $code): $(log_tail)" ;;
  esac
}

apt_get() {
  apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold "$@"
}

turn_off_automatic_updates() {
  # Woven decides when the guest changes; nothing upgrades behind its back.
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
EOF
  for unit in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service motd-news.timer \
      update-notifier-download.timer update-notifier-motd.timer fwupd-refresh.timer \
      ssh.service ssh.socket sshd-vsock.socket sshd-unix-local.socket snapd.service snapd.socket \
      snapd.seeded.service; do
    systemctl disable --now "$unit" 2>/dev/null || true
    systemctl mask "$unit" 2>/dev/null || true
  done
  # No SSH at all: systemd would otherwise offer sshd on vsock to the Mac.
  local remove=()
  for package in unattended-upgrades snapd openssh-server; do
    dpkg -s "$package" >/dev/null 2>&1 && remove+=("$package")
  done
  if [ "${#remove[@]}" -gt 0 ]; then apt_get purge -y "${remove[@]}"; fi
}

prepare_data_disk() {
  local device=/dev/disk/by-id/virtio-woven-data
  for _ in $(seq 1 30); do [ -e "$device" ] && break; sleep 1; done
  [ -e "$device" ]
  if ! blkid "$device" >/dev/null 2>&1; then
    # Lazy inode-table and journal init keep the sparse image on the Mac
    # sparse: nothing is written for space that bots never use.
    mkfs.ext4 -q -L woven-data -m 0 -i 65536 -E lazy_itable_init=1,lazy_journal_init=1,nodiscard "$device"
  fi
  mkdir -p "$data" /var/lib/docker /var/lib/containerd
  sed -i '/# woven-data$/d' /etc/fstab
  cat >>/etc/fstab <<EOF
LABEL=woven-data $data ext4 defaults,noinit_itable,commit=2,x-systemd.device-timeout=60 0 2 # woven-data
$data/docker /var/lib/docker none bind,x-systemd.requires-mounts-for=$data 0 0 # woven-data
$data/containerd /var/lib/containerd none bind,x-systemd.requires-mounts-for=$data 0 0 # woven-data
EOF
  systemctl daemon-reload
  mountpoint -q "$data" || mount "$data"
  resize2fs "$device" >/dev/null 2>&1 || true
  mkdir -p "$data/docker" "$data/containerd"
  mountpoint -q /var/lib/docker || mount /var/lib/docker
  mountpoint -q /var/lib/containerd || mount /var/lib/containerd
  if [ -f /etc/woven/disk-cap ]; then /usr/local/lib/woven/disk-cap.sh "$(cat /etc/woven/disk-cap)"; fi
}

install_docker() {
  install -d -m 0755 /etc/docker /etc/apt/keyrings
  cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "local",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "live-restore": true,
  "userland-proxy": false
}
EOF
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: $DOCKER_REPOSITORY
Suites: $DOCKER_SUITE
Components: stable
Architectures: arm64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-mark unhold docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || true
  apt_get update
  apt_get install -y --no-install-recommends --allow-downgrades --allow-change-held-packages \
    "docker-ce=$DOCKER_CE_VERSION" "docker-ce-cli=$DOCKER_CE_VERSION" "containerd.io=$CONTAINERD_VERSION" \
    iptables
  apt-mark hold docker-ce docker-ce-cli containerd.io
}

configure() {
  # Containers cannot create AF_VSOCK sockets under Docker's seccomp profile;
  # without the loopback transport not even guest root reaches the guest's
  # own vsock listeners.
  printf 'install vsock_loopback /bin/false\n' >/etc/modprobe.d/woven.conf
  # A killed or crashed helper is a power cut for the guest. Write dirty pages
  # back within about three seconds instead of thirty, so little unsynced data
  # is ever at risk.
  cat >/etc/sysctl.d/90-woven.conf <<'EOF'
vm.dirty_expire_centisecs = 200
vm.dirty_writeback_centisecs = 100
EOF
  sysctl -q --system || true
  for unit in docker.service containerd.service; do
    mkdir -p "/etc/systemd/system/$unit.d"
    cat >"/etc/systemd/system/$unit.d/woven.conf" <<'EOF'
[Unit]
RequiresMountsFor=/var/lib/docker /var/lib/containerd /var/lib/woven-data
After=woven-egress.service
Wants=woven-egress.service
EOF
  done
  cat >>/etc/systemd/system/docker.service.d/woven.conf <<'EOF'
[Service]
# Docker recreates its own chains on start; reapply ours after it.
ExecStartPost=/usr/local/lib/woven/egress.sh apply
EOF
  # The Mac's console is hvc0; boot messages there make failures diagnosable.
  # init_on_alloc=0: Ubuntu's kernel zeroes every page it allocates, including
  # the pages it hands to the balloon, and the Mac then has to back each one
  # (Virtualization never discards ballooned pages). Left untouched, they cost
  # the Mac nothing. The helper reboots the guest once to apply this.
  local options='console=hvc0 init_on_alloc=0'
  if [ -d /etc/default/grub.d ] && ! grep -qs "$options" /etc/default/grub.d/90-woven.cfg; then
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $options\"" >/etc/default/grub.d/90-woven.cfg
    update-grub || true
  fi
  systemctl daemon-reload
  systemctl enable woven-egress.service woven-agent.service
  /usr/local/lib/woven/egress.sh apply
}

start_docker() {
  systemctl enable docker.service containerd.service
  systemctl restart containerd.service docker.service
  for _ in $(seq 1 60); do
    if curl -fsS --unix-socket /run/docker.sock http://localhost/_ping >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  false
}

update_packages() {
  apt-mark hold docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || true
  apt_get update
  apt_get -y full-upgrade
}

remove_unused_packages() {
  apt_get -y autoremove --purge
  apt_get clean
}

if [ "${2:-}" = --step ]; then
  # One step, run by run_step under its time limit; run_step reports it.
  "$3"
  exit 0
fi

echo "=== $(date -Is) $mode"
trap failed ERR
case "$mode" in
  first-boot)
    run_step 900 "Turning off automatic updates" turn_off_automatic_updates
    run_step 900 "Preparing the bot disk" prepare_data_disk
    run_step 1800 "Installing Docker Engine $DOCKER_CE_VERSION" install_docker
    run_step 300 "Applying network rules" configure
    run_step 300 "Starting Docker Engine" start_docker
    printf '{"guestVersion": %s, "at": "%s"}\n' "$WOVEN_GUEST_VERSION" "$(date -Is)" >"$state/provisioned"
    status ready "Ready"
    ;;
  upgrade)
    run_step 900 "Turning off automatic updates" turn_off_automatic_updates
    run_step 3600 "Updating guest packages" update_packages
    # Idempotent: refreshes the data disk's mount options for the reboot.
    run_step 900 "Preparing the bot disk" prepare_data_disk
    run_step 1800 "Installing Docker Engine $DOCKER_CE_VERSION" install_docker
    run_step 900 "Removing unused packages" remove_unused_packages
    run_step 300 "Applying network rules" configure
    run_step 300 "Starting Docker Engine" start_docker
    printf '{"guestVersion": %s, "at": "%s"}\n' "$WOVEN_GUEST_VERSION" "$(date -Is)" >"$state/provisioned"
    status ready "Updated"
    ;;
  *)
    echo "unknown mode $mode" >&2
    exit 2
    ;;
esac
