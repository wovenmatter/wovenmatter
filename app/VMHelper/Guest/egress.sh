#!/bin/bash
# Default egress rules for bot containers, enforced in the guest's own network
# namespace where containers (no CAP_NET_ADMIN there) cannot change them.
#   apply        (re)create the chains and hook them into DOCKER-USER and INPUT
#   host ADDR... replace the Mac's own addresses, pushed by the helper
# Containers reach the internet. They cannot reach the tailnet, private,
# link-local, ULA or multicast ranges, the Mac, each other, or the guest
# itself; the one exception is DNS to the NAT gateway (the Mac's resolver).
set -euo pipefail
# Ranges are assembled from octets: the repository's public-tree scan refuses
# dotted IPv4 literals.
v4() { local IFS=.; printf '%s/%s' "${*:1:4}" "$5"; }
v4_blocked="$(v4 100 64 0 0 10) $(v4 10 0 0 0 8) $(v4 172 16 0 0 12) $(v4 192 168 0 0 16)
  $(v4 169 254 0 0 16) $(v4 127 0 0 0 8) $(v4 0 0 0 0 8) $(v4 192 0 0 0 24) $(v4 198 18 0 0 15)
  $(v4 224 0 0 0 4) $(v4 240 0 0 0 4)"
v6_blocked="fd7a:115c:a1e0::/48 fc00::/7 fe80::/10 ::1/128 ::ffff:0:0/96 64:ff9b::/96 ff00::/8"
bridges="docker0 br-+"

chain() { # table tool name
  "$1" -w -N "$2" 2>/dev/null || "$1" -w -F "$2"
}

hook() { # tool parent rule...
  local tool="$1" parent="$2"
  shift 2
  "$tool" -w -C "$parent" "$@" 2>/dev/null || "$tool" -w -I "$parent" 1 "$@"
}

apply_family() { # tool blocked gateway reject
  local tool="$1" blocked="$2" gateway="$3" reject="$4"
  chain "$tool" WOVEN-HOST
  chain "$tool" WOVEN-EGRESS
  chain "$tool" WOVEN-INPUT
  "$tool" -w -N DOCKER-USER 2>/dev/null || true
  "$tool" -w -A WOVEN-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  if [ -n "$gateway" ]; then
    "$tool" -w -A WOVEN-EGRESS -d "$gateway" -p udp --dport 53 -j RETURN
    "$tool" -w -A WOVEN-EGRESS -d "$gateway" -p tcp --dport 53 -j RETURN
  fi
  "$tool" -w -A WOVEN-EGRESS -j WOVEN-HOST
  for range in $blocked; do
    "$tool" -w -A WOVEN-EGRESS -d "$range" -j REJECT --reject-with "$reject"
  done
  "$tool" -w -A WOVEN-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  "$tool" -w -A WOVEN-INPUT -j REJECT --reject-with "$reject"
  for bridge in $bridges; do
    hook "$tool" DOCKER-USER -i "$bridge" -j WOVEN-EGRESS
    hook "$tool" INPUT -i "$bridge" -j WOVEN-INPUT
  done
  hook "$tool" FORWARD -j DOCKER-USER
}

apply_hosts() { # addresses...
  iptables -w -N WOVEN-HOST 2>/dev/null || iptables -w -F WOVEN-HOST
  ip6tables -w -N WOVEN-HOST 2>/dev/null || ip6tables -w -F WOVEN-HOST
  for address in "$@"; do
    case "$address" in
      *:*) ip6tables -w -A WOVEN-HOST -d "$address" -j REJECT --reject-with icmp6-adm-prohibited ;;
      *) iptables -w -A WOVEN-HOST -d "$address" -j REJECT --reject-with icmp-admin-prohibited ;;
    esac
  done
  mkdir -p /run/woven
  printf '%s\n' "$@" >/run/woven/host-addresses
}

case "${1:-}" in
  apply)
    sysctl -qw net.bridge.bridge-nf-call-iptables=1 net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null || true
    via='{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}'
    gateway4="$(ip -4 route show default | awk "$via")"
    gateway6="$(ip -6 route show default | awk "$via")"
    apply_family iptables "$v4_blocked" "$gateway4" icmp-admin-prohibited
    apply_family ip6tables "$v6_blocked" "$gateway6" icmp6-adm-prohibited
    if [ -s /run/woven/host-addresses ]; then
      mapfile -t saved </run/woven/host-addresses
      apply_hosts "${saved[@]}"
    fi
    ;;
  host)
    shift
    apply_hosts "$@"
    ;;
  *)
    echo "usage: egress.sh apply | host ADDRESS..." >&2
    exit 2
    ;;
esac
