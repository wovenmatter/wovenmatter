#!/bin/bash
# Woven VM guest provisioning, run by systemd (never by hand).
#   first-boot: prepare the data disk, install the pinned Docker Engine, apply
#               Woven's configuration. Retried on every boot until it succeeds.
#   upgrade:    Woven's Update action: guest packages plus the pinned Docker
#               Engine, then the same configuration. The Mac snapshots the
#               disks before and reboots and health-checks the guest after.
set -Eeuo pipefail
mode="${1:-first-boot}"
state=/var/lib/woven
data=/var/lib/woven-data
log=/var/log/woven-provision.log
status_file="$state/status.json"
[ "$mode" = upgrade ] && status_file="$state/update.json"
mkdir -p "$state"
exec >>"$log" 2>&1
echo "=== $(date -Is) $mode"
# shellcheck source=/dev/null
. /etc/woven/versions.env
export DEBIAN_FRONTEND=noninteractive
step="Starting"

status() {
  python3 - "$status_file" "$@" <<'PY'
import json, os, sys
path, phase, step = sys.argv[1:4]
error = sys.argv[4] if len(sys.argv) > 4 else None
with open(path + ".tmp", "w") as handle:
    json.dump({"phase": phase, "step": step, "error": error}, handle)
os.replace(path + ".tmp", path)
PY
}
begin() { step="$1"; echo "--- $step"; status running "$step"; }
failed() {
  local code=$?
  status failed "$step" "$step failed (exit $code): $(tail -n 4 "$log" | tr '\n' ' ' | cut -c1-600)"
  exit "$code"
}
trap failed ERR

apt_get() {
  apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold "$@"
}

turn_off_automatic_updates() {
  begin "Turning off automatic updates"
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
  begin "Preparing the bot disk"
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
  begin "Installing Docker Engine $DOCKER_CE_VERSION"
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
  begin "Applying network rules"
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
  if [ -d /etc/default/grub.d ] && ! grep -qs hvc0 /etc/default/grub.d/90-woven.cfg; then
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0"' >/etc/default/grub.d/90-woven.cfg
    update-grub || true
  fi
  systemctl daemon-reload
  systemctl enable woven-egress.service woven-agent.service
  /usr/local/lib/woven/egress.sh apply
}

start_docker() {
  begin "Starting Docker Engine"
  systemctl enable docker.service containerd.service
  systemctl restart containerd.service docker.service
  for _ in $(seq 1 60); do
    if curl -fsS --unix-socket /run/docker.sock http://localhost/_ping >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  false
}

case "$mode" in
  first-boot)
    turn_off_automatic_updates
    prepare_data_disk
    install_docker
    configure
    start_docker
    printf '{"guestVersion": %s, "at": "%s"}\n' "$WOVEN_GUEST_VERSION" "$(date -Is)" >"$state/provisioned"
    status ready "Ready"
    ;;
  upgrade)
    turn_off_automatic_updates
    begin "Updating guest packages"
    apt-mark hold docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || true
    apt_get update
    apt_get -y full-upgrade
    # Idempotent: refreshes the data disk's mount options for the reboot.
    prepare_data_disk
    install_docker
    apt_get -y autoremove --purge
    apt_get clean
    configure
    start_docker
    printf '{"guestVersion": %s, "at": "%s"}\n' "$WOVEN_GUEST_VERSION" "$(date -Is)" >"$state/provisioned"
    status ready "Updated"
    ;;
  *)
    echo "unknown mode $mode" >&2
    exit 2
    ;;
esac
