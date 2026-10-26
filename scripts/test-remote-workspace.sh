#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/wovenmatter-host-inspect.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM
fake_bin="$fixture_root/bin"
mkdir -p "$fake_bin"
for tool in awk dirname; do
  ln -s "$(command -v "$tool")" "$fake_bin/$tool"
done

cat > "$fixture_root/os-release" <<'EOF'
ID=ubuntu
VERSION_ID=24.04
VERSION_CODENAME=noble
EOF

cat > "$fake_bin/uname" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -s ]; then printf 'Linux\n'; else printf 'x86_64\n'; fi
EOF
cat > "$fake_bin/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = -u ] && { printf '0\n'; exit 0; }
exec /usr/bin/id "$@"
EOF
cat > "$fake_bin/dpkg-query" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$fake_bin/uname" "$fake_bin/id" "$fake_bin/dpkg-query"

inspection="$(
  PATH="$fake_bin" \
  WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
  /bin/bash "$repo_root/scripts/remote-workspace.sh" inspect
)"
jq -e '
  .ready == false
  and .canPrepare == true
  and .preparationRequired == true
  and (.preparationActions | length) == 5
  and (.blockingIssues | length) == 0
' <<< "$inspection" >/dev/null

cat > "$fake_bin/docker" <<'EOF'
#!/bin/sh
if [ "${1:-}" = info ] && [ "${2:-}" != --format ]; then exit 0; fi
if [ "${1:-}" = context ] && [ "${2:-}" = show ]; then
  printf 'default\n'
  exit 0
fi
if [ "${1:-}" = context ] && [ "${2:-}" = inspect ]; then
  printf '%s\n' "${WOVENMATTER_FAKE_ENDPOINT:-unix:///var/run/docker.sock}"
  exit 0
fi
if [ "${1:-}" = version ]; then
  case "${3:-}" in
    *Platform.Name*) printf '%s\n' "${WOVENMATTER_FAKE_PLATFORM-Docker Engine - Community}" ;;
    *Components*) printf '%s\n' "${WOVENMATTER_FAKE_COMPONENTS-Engine}" ;;
    *Server.Version*) printf '%s\n' "${WOVENMATTER_FAKE_VERSION-29.7.2}" ;;
    *APIVersion*) printf '%s\n' "${WOVENMATTER_FAKE_API-1.55}" ;;
    *) printf '29.7.2\n' ;;
  esac
  exit 0
fi
case "${3:-}" in
  *Architecture*) printf 'x86_64\n' ;;
  *OSType*) printf 'linux\n' ;;
  *DockerRootDir*) printf '/fake/docker-root\n' ;;
  *MemoryLimit*|*SwapLimit*) printf 'true\n' ;;
  *CgroupVersion*) printf '2\n' ;;
  *CgroupDriver*) printf 'systemd\n' ;;
  *SecurityOptions*) printf '["name=seccomp"]\n' ;;
  *) printf '\n' ;;
esac
EOF
cat > "$fake_bin/df" <<'EOF'
#!/bin/sh
available="${WOVENMATTER_FAKE_AVAILABLE_KIB:-52428800}"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 104857600 52428800 %s 50%% /fake\n' "$available"
EOF
chmod +x "$fake_bin/docker" "$fake_bin/df"

inspection="$(
  PATH="$fake_bin" \
  WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
  /bin/bash "$repo_root/scripts/remote-workspace.sh" inspect
)"
jq -e '
  .ready == true
  and .capabilities.memory == true
  and .capabilities.swap == true
  and .hostStorageCapacityBytes == 107374182400
  and .hostStorageAvailableBytes == 53687091200
  and .hostStorageLow == false
  and .storageWarning == null
  and .preparationRequired == false
' <<< "$inspection" >/dev/null

inspection="$(
  PATH="$fake_bin" \
  WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
  WOVENMATTER_FAKE_AVAILABLE_KIB=5242880 \
  /bin/bash "$repo_root/scripts/remote-workspace.sh" inspect
)"
jq -e '
  .ready == true
  and .hostStorageLow == true
  and (.storageWarning | contains("running low on disk space"))
' <<< "$inspection" >/dev/null

inspection="$(
  PATH="$fake_bin" \
  WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
  WOVENMATTER_FAKE_PLATFORM='Podman Engine' \
  /bin/bash "$repo_root/scripts/remote-workspace.sh" inspect
)"
jq -e '
  .ready == false
  and (.blockingIssues | map(select(contains("Podman"))) | length) == 1
' <<< "$inspection" >/dev/null

inspection="$(
  PATH="$fake_bin" \
  WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
  WOVENMATTER_FAKE_ENDPOINT='tcp://remote-docker:2376' \
  /bin/bash "$repo_root/scripts/remote-workspace.sh" inspect
)"
jq -e '
  .ready == false
  and (.blockingIssues | map(select(contains("Remote Docker contexts"))) | length) == 1
' <<< "$inspection" >/dev/null

# Arch/Omarchy's supported Docker package omits the optional platform name.
for platform in '' 'Moby Engine'; do
  inspection="$(
    PATH="$fake_bin" WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
    WOVENMATTER_FAKE_PLATFORM="$platform" \
    WOVENMATTER_FAKE_COMPONENTS=$'Engine\ncontainerd\nrunc' \
    /bin/bash "$repo_root/scripts/remote-workspace.sh" inspect
  )"
  jq -e '.ready == true and .preparationRequired == false and (.blockingIssues | length) == 0' \
    <<< "$inspection" >/dev/null
done

# A blank platform alone must never admit an unidentified compatibility shim.
for components in '' 'Some Engine' 'Podman Engine'; do
  inspection="$(
    PATH="$fake_bin" WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
    WOVENMATTER_FAKE_PLATFORM='' WOVENMATTER_FAKE_COMPONENTS="$components" \
    /bin/bash "$repo_root/scripts/remote-workspace.sh" inspect
  )"
  jq -e '.ready == false and .canPrepare == false and (.blockingIssues | length) == 1' \
    <<< "$inspection" >/dev/null
done

# Supported branding/API alone cannot bypass the Docker localhost isolation floor.
for version in '27.5.1' '' 'unknown'; do
  inspection="$(
    PATH="$fake_bin" WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
    WOVENMATTER_FAKE_VERSION="$version" \
    /bin/bash "$repo_root/scripts/remote-workspace.sh" inspect
  )"
  jq -e '.ready == false and (.blockingIssues[0] | contains("Docker Engine 28"))' \
    <<< "$inspection" >/dev/null
done

for api in '1.40' '' 'unknown'; do
  inspection="$(
    PATH="$fake_bin" WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
    WOVENMATTER_FAKE_API="$api" \
    /bin/bash "$repo_root/scripts/remote-workspace.sh" inspect
  )"
  jq -e '.ready == false and (.blockingIssues[0] | contains("API"))' \
    <<< "$inspection" >/dev/null
  if [ "$api" = '1.40' ]; then
    jq -e '.blockingIssues[0] | contains("API 1.40") and contains("Update Docker Engine")' \
      <<< "$inspection" >/dev/null
  fi
done

inspection="$(
  PATH="$fake_bin" WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
  WOVENMATTER_FAKE_API=1.41 WOVENMATTER_FAKE_PLATFORM='' \
  /bin/bash "$repo_root/scripts/remote-workspace.sh" inspect
)"
jq -e '.ready == true' <<< "$inspection" >/dev/null

if PATH="$fake_bin" \
  WOVENMATTER_OS_RELEASE="$fixture_root/os-release" \
  /bin/bash "$repo_root/scripts/remote-workspace.sh" prepare NOT_AUTHORIZED \
  >"$fixture_root/unauthorized.out" 2>"$fixture_root/unauthorized.err"; then
  printf '%s\n' 'unauthorized host preparation unexpectedly succeeded' >&2
  exit 1
fi
jq -e '.error == "host_preparation_not_authorized"' \
  "$fixture_root/unauthorized.err" >/dev/null

printf '%s\n' 'remote workspace inspection tests passed'
