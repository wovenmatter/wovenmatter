#!/usr/bin/env bash
# Installs or updates this repository's self-hosted GitHub Actions runner on an
# owned machine: the Apple Silicon Mac (label wovenmatter-macos) or the x86_64
# Linux workstation (label wovenmatter-linux). See docs/CI_RUNNERS.md.
#
#   scripts/ci-runner/install-runner.sh                 # this machine
#   scripts/ci-runner/install-runner.sh --host NAME     # over SSH
#
# Re-running is safe: it refreshes the job guard and environment and restarts
# the service. Registration needs a token only the first time; a repository
# admin copies it from Settings > Actions > Runners > New self-hosted runner and
# pastes it at the hidden prompt (or sets WOVENMATTER_RUNNER_TOKEN).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repository=wovenmatter/wovenmatter

if [ "${1:-}" = --host ]; then
  host="${2:?usage: install-runner.sh [--host SSH_HOST]}"
  remote='.cache/wovenmatter-runner-setup'
  # Copies only these scripts; the runner itself is downloaded and verified there.
  ssh "$host" "rm -rf ~/$remote && mkdir -p ~/$remote"
  tar -C "$here" -cf - install-runner.sh runner-guard.sh | ssh "$host" "tar -C ~/$remote -xf -"
  exec ssh -t "$host" "bash ~/$remote/install-runner.sh"
fi
[ "$#" -eq 0 ] || { echo 'usage: install-runner.sh [--host SSH_HOST]' >&2; exit 64; }

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=osx-arm64; label=wovenmatter-macos ;;
  Linux-x86_64) platform=linux-x64; label=wovenmatter-linux ;;
  *) echo "Unsupported runner machine: $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
root="$HOME/actions-runner/wovenmatter"
name="$(hostname -s | tr '[:upper:]' '[:lower:]')-$label"
mkdir -p "$root"
cd "$root"

if [ ! -x ./config.sh ]; then
  # The current official release, checked against the SHA-256 its release notes
  # publish. The runner updates itself afterwards, as GitHub requires.
  release="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)"
  version="$(printf '%s' "$release" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')"
  expected="$(printf '%s' "$release" | PLATFORM="$platform" python3 -c '
import json, os, re, sys
body = json.load(sys.stdin)["body"]
match = re.search(r"<!-- BEGIN SHA %s -->([0-9a-f]{64})<!-- END SHA" % re.escape(os.environ["PLATFORM"]), body)
print(match.group(1) if match else "")')"
  [ -n "$expected" ] || { echo "No published checksum for actions-runner $version ($platform)." >&2; exit 1; }
  archive="actions-runner-$platform-$version.tar.gz"
  curl -fsSLo "$archive" "https://github.com/actions/runner/releases/download/v$version/$archive"
  if command -v sha256sum >/dev/null; then actual="$(sha256sum "$archive" | cut -d' ' -f1)"
  else actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"; fi
  [ "$actual" = "$expected" ] || { rm -f "$archive"; echo "Checksum mismatch for $archive." >&2; exit 1; }
  tar -xzf "$archive"
  rm -f "$archive"
  echo "Installed actions-runner $version ($platform), SHA-256 verified."
fi

# The job guard lives here, outside every checkout, so no branch can change it.
mkdir -p hooks
install -m 0755 "$here/runner-guard.sh" hooks/runner-guard.sh
printf '#!/bin/sh\nexec "%s/hooks/runner-guard.sh" started\n' "$root" > hooks/job-started.sh
printf '#!/bin/sh\nexec "%s/hooks/runner-guard.sh" completed\n' "$root" > hooks/job-completed.sh
chmod 0755 hooks/job-started.sh hooks/job-completed.sh

# Jobs run as this user but see none of the user's own credentials or settings:
# no gh login, git config, SSH agent, npm or Docker credentials.
mkdir -p isolation/gh isolation/docker
: > isolation/gitconfig
: > isolation/npmrc
chmod 0700 isolation

if [ ! -f .runner ]; then
  token="${WOVENMATTER_RUNNER_TOKEN:-}"
  if [ -z "$token" ]; then
    printf 'Runner registration token for %s (hidden): ' "$repository" >&2
    IFS= read -rs token
    echo >&2
  fi
  [ -n "$token" ] || { echo 'A registration token is required the first time.' >&2; exit 1; }
  ./config.sh --unattended --url "https://github.com/$repository" --token "$token" \
    --name "$name" --labels "$label" --work _work --replace
  unset token
fi

# config.sh writes .env; keep its lines and replace ours.
touch .env
grep -v -E '^(ACTIONS_RUNNER_HOOK_JOB_(STARTED|COMPLETED)|GH_CONFIG_DIR|GIT_CONFIG_GLOBAL|GIT_CONFIG_NOSYSTEM|DOCKER_CONFIG|NPM_CONFIG_USERCONFIG|SSH_AUTH_SOCK|WOVENMATTER_OWNED_RUNNER)=' .env > .env.next || true
cat >> .env.next <<EOF
ACTIONS_RUNNER_HOOK_JOB_STARTED=$root/hooks/job-started.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$root/hooks/job-completed.sh
GH_CONFIG_DIR=$root/isolation/gh
GIT_CONFIG_GLOBAL=$root/isolation/gitconfig
GIT_CONFIG_NOSYSTEM=1
DOCKER_CONFIG=$root/isolation/docker
NPM_CONFIG_USERCONFIG=$root/isolation/npmrc
SSH_AUTH_SOCK=
WOVENMATTER_OWNED_RUNNER=$label
EOF
mv .env.next .env

if [ "$platform" = osx-arm64 ]; then
  # A LaunchAgent in the logged-in session: desktop tests need the window server.
  # svc.sh names the agent after the runner and keeps the user's PATH from .path.
  ./svc.sh status >/dev/null 2>&1 && ./svc.sh stop >/dev/null 2>&1 || true
  ./svc.sh install >/dev/null 2>&1 || true
  ./svc.sh start
else
  # A user service; lingering keeps it running without a login session.
  unit="$HOME/.config/systemd/user/wovenmatter-actions-runner.service"
  mkdir -p "$(dirname "$unit")"
  cat > "$unit" <<EOF
[Unit]
Description=GitHub Actions runner for $repository ($label)
After=network-online.target

[Service]
WorkingDirectory=$root
ExecStart=$root/run.sh
Restart=always
RestartSec=10
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable wovenmatter-actions-runner.service >/dev/null
  systemctl --user restart wovenmatter-actions-runner.service
  [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ] \
    || echo 'Note: enable lingering (loginctl enable-linger) so the runner survives logout.' >&2
fi
echo "Runner $name ($label) is installed in $root."
