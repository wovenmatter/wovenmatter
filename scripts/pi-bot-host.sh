#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
failure_reported=no

json() {
  local value="$1" character number escaped i
  printf '"'
  for ((i=0; i<${#value}; i++)); do
    character="${value:i:1}"
    case "$character" in
      '"') printf '\\"' ;;
      '\') printf '\\\\' ;;
      *)
        printf -v number '%d' "'$character"
        number=$((number & 255))
        if [ "$number" -lt 32 ]; then
          printf -v escaped '\\u%04x' "$number"
          printf '%s' "$escaped"
        else printf '%s' "$character"; fi ;;
    esac
  done
  printf '"'
}
fail() { printf '{"error":'; json "$1"; printf ',"detail":'; json "$2"; printf '}\n'; } >&2
abort() { failure_reported=yes; fail "$1" "$2"; exit "${3:-1}"; }
progress() { printf 'WM_PROGRESS %s\n' "$1" >&2; }
xml() { printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }
sha256() {
  # Hash stdin: GNU sha256sum prefixes the hash with a backslash for a path containing one.
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -d ' ' -f1
  else shasum -a 256 < "$1" | cut -d ' ' -f1; fi
}
command_name="${1:-}"
[ "$#" -gt 0 ] && shift
case "$command_name" in inspect|install|cancel-install|start|stop|restart|status|uninstall) ;;
  *) abort arguments 'Expected inspect, install, cancel-install, start, stop, restart, status or uninstall.' 64 ;; esac
instance= root= commit= node_version= node_sha= pnpm_version= bundle= tooling= port= service=yes delete_data=no
container_version= container_sha=
seen=' '
while [ "$#" -gt 0 ]; do
  option="$1"; shift
  case "$seen" in *" $option "*) abort arguments "Repeated option: $option" 64 ;; esac
  seen="$seen$option "
  case "$option" in
    --instance|--root|--commit|--node-version|--node-sha256|--pnpm-version|--bundle|--tooling-lock-dir|--port|--container-version|--container-sha256)
      [ "$#" -gt 0 ] && [ -n "$1" ] || abort arguments "Missing value for $option" 64
      value="$1"; shift
      case "$option" in
        --instance) instance="$value" ;; --root) root="$value" ;; --commit) commit="$value" ;;
        --node-version) node_version="$value" ;; --node-sha256) node_sha="$value" ;;
        --pnpm-version) pnpm_version="$value" ;; --bundle) bundle="$value" ;;
        --tooling-lock-dir) tooling="$value" ;; --port) port="$value" ;;
        --container-version) container_version="$value" ;; --container-sha256) container_sha="$value" ;;
      esac ;;
    --service) service=yes ;; --no-service) service=no ;; --delete-data) delete_data=yes ;;
    *) abort arguments "Unknown option: $option" 64 ;;
  esac
done
[[ "$instance" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || abort arguments 'Invalid or missing instance name.' 64
for option in $seen; do
  case "$option" in --instance|--root) continue ;; esac
  case "$command_name:$option" in
    install:--commit|install:--node-version|install:--node-sha256|install:--pnpm-version|install:--bundle|install:--tooling-lock-dir|install:--port|install:--container-version|install:--container-sha256|install:--service|install:--no-service|uninstall:--delete-data) ;;
    *) abort arguments "Option $option is not valid for $command_name." 64 ;;
  esac
done
case "$seen" in *' --service '*) case "$seen" in *' --no-service '*) abort arguments 'Conflicting service options.' 64 ;; esac ;; esac
os="$(uname -s)"; arch="$(uname -m)"; libc=null; manager=none
case "$arch" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=x64 ;; *) abort platform "Unsupported architecture: $arch" ;; esac
case "$os" in
  Darwin) os=darwin; manager=launchd; default_root="$HOME/Library/Application Support/Woven Matter Pi Bot/$instance" ;;
  Linux)
    os=linux
    libc_description="$(ldd --version 2>&1 || true)"
    if printf '%s' "$libc_description" | grep -qi musl; then libc=musl
    elif getconf GNU_LIBC_VERSION >/dev/null 2>&1; then libc=glibc
    else libc=unknown; fi
    command -v systemctl >/dev/null 2>&1 && manager=systemd
    # A plain SSH session may not carry the user manager's bus address.
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    default_root="$HOME/.local/share/wovenmatter/pi-bot/$instance" ;;
  *) abort platform "Unsupported operating system: $os" ;;
esac
root="${root:-$default_root}"
case "$root" in /*) ;; *) abort arguments 'Root must be an absolute path.' 64 ;; esac
# Resolve existing ancestors before applying the standalone-installation boundary.
resolve_path() {
  local path="$1" suffix=
  while [ ! -e "$path" ]; do suffix="/$(basename "$path")$suffix"; path="$(dirname "$path")"; done
  [ -d "$path" ] || abort root 'Root or its ancestor is not a directory.'
  printf '%s%s' "$(cd "$path" && pwd -P)" "$suffix"
}
root="$(resolve_path "$root")"
case "$root/" in
  //|"$HOME/"|"$HOME/.config/pi-bot/"*|"$HOME/.local/share/pi-bot/"*) abort foreign_root 'Refusing a standalone Pi Bot or home root.' ;;
esac
case "$root" in *$'\n'*|*$'\r'*|*/../*|*/..|*/./*) abort arguments 'Root cannot contain line breaks.' 64 ;; esac
unit="wovenmatter-pi-bot-$instance.service"
label="io.wovenmatter.pi-bot.$instance"
if [ "$os" = linux ]; then service_file="$HOME/.config/systemd/user/$unit"
else service_file="$HOME/Library/LaunchAgents/$label.plist"; fi
owned=no
if [ -f "$root/.woven-instance" ] && [ "$(cat "$root/.woven-instance")" = "$instance" ]; then owned=yes; fi
current_commit=
if [ "$owned" = yes ] && [ -L "$root/current" ]; then
  target="$(readlink "$root/current")"
  if [[ "$target" =~ ^releases/[a-f0-9]{40}$ ]] && [ -d "$root/$target" ]; then current_commit="${target#releases/}"; fi
fi
# Pi Bot's Config page saves this file as written, so a trailing comment is ordinary.
toml_port() { sed -n '/^\[server\]/,/^\[/s/^[[:space:]]*port[[:space:]]*=[[:space:]]*\([0-9]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$1"; }
config_port() { toml_port "$root/config.toml"; }
valid_port() { [[ "$1" =~ ^[1-9][0-9]{3,4}$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ] && [ "$1" -ne 4317 ]; }
managed_port=
if [ "$owned" = yes ] && [ -f "$root/config.toml" ]; then managed_port="$(config_port)"; fi
if [ -n "$managed_port" ]; then valid_port "$managed_port" || abort config 'Managed config has an invalid server port.'; fi
health() { curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$1/health" 2>/dev/null; }
health_field() {
  # Health identifiers contain only this alphabet; never print arbitrary response bodies.
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([a-zA-Z0-9._-]*\)\".*/\1/p"
}
running=false
if [ -n "$current_commit" ] && [ -n "$managed_port" ] && health "$managed_port" >/dev/null; then running=true; fi
lingering=null
if [ "$os" = linux ]; then
  lingering=false
  if command -v loginctl >/dev/null 2>&1 && [ "$(loginctl show-user "$(id -u)" --property=Linger --value 2>/dev/null || true)" = yes ]; then lingering=true; fi
fi
# Where bots' tools will run. On a Mac that can use it, Apple's `container` keeps no shared VM
# running, so an idle Mac holds almost no memory for bots; see docs/architecture/PI_BOT_INTEGRATION.md.
runtime_search="${PI_BOT_RUNTIME_SEARCH_PATH:-$PATH:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin}"
find_runtime() { PATH="$runtime_search" command -v "$1" 2>/dev/null || true; }
docker_cli="$(find_runtime docker)"
container_cli="$(find_runtime container)"
# Apple's services are per user and can't run twice, so every installation on a Mac shares one
# copy and one set of images, and each records its use of them in instances/.
shared_runtime="$HOME/Library/Application Support/Woven Matter Pi Bot/runtime"
apple_container_supported=no
if [ "$os" = darwin ] && [ "$arch" = arm64 ]; then
  macos_major="$(sw_vers -productVersion 2>/dev/null | cut -d . -f 1 || true)"
  if [[ "$macos_major" =~ ^[0-9]+$ ]] && [ "$macos_major" -ge 26 ]; then apple_container_supported=yes; fi
fi
if [ "$apple_container_supported" = yes ]; then environment=container
elif [ -n "$docker_cli" ]; then environment=docker
else environment=none; fi
if [ "$command_name" = inspect ]; then
  docker=false; [ -n "$docker_cli" ] && docker=true
  printf '{"schema":1,"os":'; json "$os"; printf ',"arch":'; json "$arch"
  printf ',"libc":'; if [ "$libc" = null ]; then printf null; else json "$libc"; fi
  printf ',"serviceManager":'; json "$manager"; printf ',"environment":'; json "$environment"
  printf ',"docker":%s,"lingering":%s,"managed":{"installed":' "$docker" "$lingering"
  if [ -n "$current_commit" ]; then printf true; else printf false; fi
  printf ',"commit":'; if [ -n "$current_commit" ]; then json "$current_commit"; else printf null; fi
  printf ',"running":%s,"port":%s,"root":' "$running" "${managed_port:-null}"; json "$root"; printf '},"existing":['
  # Only where a standalone Pi Bot listens: other ports on this host belong to other apps.
  listener_ports() {
    printf '4317\n'
    standalone_config="$HOME/.config/pi-bot/config.toml"
    if [ -r "$standalone_config" ]; then
      toml_port "$standalone_config"
    fi
  }
  separator=
  while IFS= read -r existing_port; do
    [[ "$existing_port" =~ ^[1-9][0-9]{0,4}$ ]] || continue
    [ "$existing_port" -le 65535 ] || continue
    [ "$existing_port" != "${managed_port:-0}" ] || continue
    existing="$(health "$existing_port" || true)"
    version="$(health_field "$existing" version)"
    [ -n "$version" ] || continue
    printf '%s{"port":%s,"version":' "$separator" "$existing_port"; json "$version"
    printf ',"protocol":'; if printf '%s' "$existing" | grep -Eq '"protocol"[[:space:]]*:[[:space:]]*1([,}]|[[:space:]])'; then printf 1; else printf null; fi
    printf ',"installationId":'; installation_id="$(health_field "$existing" installationId)"
    if [ -n "$installation_id" ]; then json "$installation_id"; else printf null; fi
    printf ',"service":'
    # Only its unit file is read. Nothing here ever asks systemd about pi-bot.service.
    if [ "$os" = linux ] && [ -f "$HOME/.config/systemd/user/pi-bot.service" ]; then json pi-bot.service; else printf null; fi
    printf '}'
    separator=,
  done < <(listener_ports | sort -un)
  printf ']}\n'; exit
fi
# An installer whose SSH client is gone can outlive it, so cancelling is explicit and waits.
if [ "$command_name" = cancel-install ]; then
  owner="$(cat "$root/.install-lock/pid" 2>/dev/null || true)"
  if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
    kill -TERM "$owner" 2>/dev/null || true
    # The installer releases its lock as its last act; an unreaped process still looks alive.
    for ((attempt=0; attempt<60; attempt++)); do
      [ -d "$root/.install-lock" ] && kill -0 "$owner" 2>/dev/null || break
      sleep 0.5
    done
    if [ -d "$root/.install-lock" ] && kill -0 "$owner" 2>/dev/null; then abort locked 'The running install did not stop.'; fi
  fi
  printf '{"schema":1,"action":"cancel-install"}\n'; exit
fi
# Stopping what isn't installed has nothing to do, as after cancelling a first install.
if [ "$command_name" = stop ] && [ -z "$current_commit" ]; then
  printf '{"schema":1,"action":"stop","supervisor":null}\n'; exit
fi
[ "$command_name" = install ] || [ -n "$current_commit" ] || { [ "$command_name" = uninstall ] && [ "$owned" = yes ]; } || abort not_installed 'No managed installation exists at this root.'
if [ "$command_name" = status ]; then
  printf '{"schema":1,"running":%s,"port":%s,"root":' "$running" "${managed_port:-null}"; json "$root"
  printf ',"supervisor":'; if [ "$(cat "$root/.service-mode" 2>/dev/null || true)" = no ]; then json caller; else json "$manager"; fi
  printf ',"lingering":%s}\n' "$lingering"; exit
fi
if [ "$command_name" = install ]; then
  [[ "$commit" =~ ^[a-f0-9]{40}$ ]] || abort arguments 'Commit must be a full lowercase SHA.' 64
  [[ "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || abort arguments 'Invalid Node version.' 64
  [[ "$node_sha" =~ ^[a-f0-9]{64}$ ]] || abort arguments 'Invalid Node SHA-256.' 64
  [[ "$pnpm_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || abort arguments 'Invalid pnpm version.' 64
  [ -n "$bundle" ] && [ -n "$tooling" ] || abort arguments 'Bundle and tooling lock directory are required.' 64
  [ "$bundle" != - ] || [ "$tooling" != - ] || abort arguments 'Only one input can use stdin.' 64
  [ -z "$port" ] || valid_port "$port" || abort arguments 'Invalid or reserved port.' 64
  [ -z "$container_version$container_sha" ] || { [[ "$container_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$container_sha" =~ ^[a-f0-9]{64}$ ]]; } || abort arguments 'Invalid Apple container selection.' 64
  [ "$os" != linux ] || [ "$libc" = glibc ] || abort libc 'Official Node Linux archives require glibc; musl and unknown libc are unsupported.'
fi
# Every mutation uses the same lock. A separate, short-held guard serializes stale
# lock recovery so a second reaper cannot remove a newly acquired live lock.
mkdir -p "$root"
for directory in releases node tooling pnpm-store data; do
  [ ! -L "$root/$directory" ] || abort foreign_root "Refusing symlinked $directory directory."
done
[ ! -L "$root/.woven-instance" ] && [ ! -L "$root/.service-mode" ] && [ ! -L "$root/.install-lock" ] && [ ! -L "$root/.lock-guard" ] && [ ! -L "$root/config.toml" ] || abort foreign_root 'Refusing symlinked management files.'
if [ "$owned" != yes ]; then
  [ -z "$(ls -A "$root")" ] || abort foreign_root 'Root is nonempty and is not owned by this instance.'
fi
lock_held=no; scratch_pid=; scratch=; stage=; guard_held=no; child_pid=
# Bash runs a signal trap only between foreground commands, so anything slow runs in the
# background under wait. Cancelling then takes effect now instead of when npm finishes.
# Job control gives it a process group of its own, covering whatever it starts in turn.
run_child() {
  local directory="$1" status=0
  shift
  set -m
  ( cd -P "$directory" && exec "$@" ) >&2 &
  child_pid=$!
  set +m
  wait "$child_pid" || status=$?
  child_pid=
  return "$status"
}
stop_child() {
  [ -n "$child_pid" ] || return 0
  local attempt
  kill -TERM -- "-$child_pid" 2>/dev/null
  for ((attempt=0; attempt<40; attempt++)); do
    kill -0 -- "-$child_pid" 2>/dev/null || break
    sleep 0.25
  done
  kill -KILL -- "-$child_pid" 2>/dev/null
  wait "$child_pid" 2>/dev/null
  child_pid=
}
promotion_pending=no; new_release=no; service_attempted=no; tooling_replaced=no
cleanup() {
  local result=$?
  trap - EXIT
  set +e
  stop_child
  if [ "$result" -ne 0 ] && [ "$promotion_pending" = yes ]; then
    if [ "$service_attempted" = yes ]; then service_action stop; fi
    if [ -n "$current_commit" ]; then swap_current "$current_commit"; else rm -f "$root/current"; fi
    if [ -f "$stage/previous-service" ]; then cp "$stage/previous-service" "$service_file"
    elif [ "$service_attempted" = yes ]; then
      if [ "$os" = linux ]; then systemctl --user disable "$unit" >&2; fi
      rm -f "$service_file"
    fi
    if [ "$os" = linux ] && [ "$service_attempted" = yes ]; then systemctl --user daemon-reload >&2; fi
    if [ "$previous_service" = yes ]; then
      if [ "$os" = linux ]; then systemctl --user enable "$unit" >&2; fi
      service_action start
    fi
    if [ "$tooling_replaced" = yes ]; then rm -rf "$root/tooling"; fi
    if [ -d "$stage/previous-tooling" ]; then mv "$stage/previous-tooling" "$root/tooling"; fi
  fi
  if [ "$result" -ne 0 ] && [ "$new_release" = yes ]; then rm -rf "$root/releases/$commit"; fi
  if [ -n "$scratch_pid" ]; then kill "$scratch_pid" 2>/dev/null || true; wait "$scratch_pid" 2>/dev/null || true; fi
  [ -z "$scratch" ] || rm -rf "$scratch"
  [ -z "$stage" ] || rm -rf "$stage"
  if [ "$lock_held" = yes ]; then rm -f "$root/.install-lock/pid"; rmdir "$root/.install-lock"; fi
  if [ "$guard_held" = yes ]; then rmdir "$root/.lock-guard"; fi
  if [ "${remove_root:-no}" = yes ]; then rm -f "$root/.woven-instance" "$root/server.log"; rmdir "$root" 2>/dev/null || true; fi
  if [ "$result" -ne 0 ] && [ "${failure_reported:-no}" != yes ]; then fail operation_failed "$command_name failed; current and persistent data have been retained."; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$root/.lock-guard" 2>/dev/null || abort locked 'Another operation is acquiring the install lock; retry later.'
guard_held=yes
if [ -d "$root/.install-lock" ]; then
  owner="$(cat "$root/.install-lock/pid" 2>/dev/null || true)"
  [[ "$owner" =~ ^[0-9]+$ ]] || abort locked 'Install lock has no valid owner; inspect it before removing it.'
  if kill -0 "$owner" 2>/dev/null || ps -p "$owner" >/dev/null 2>&1; then abort locked 'Another installer is still alive.'; fi
  rm -f "$root/.install-lock/pid"; rmdir "$root/.install-lock" || abort locked 'Install lock contains unexpected files.'
fi
mkdir "$root/.install-lock"; lock_held=yes; printf '%s\n' "$$" > "$root/.install-lock/pid"
rmdir "$root/.lock-guard"; guard_held=no
printf '%s\n' "$instance" > "$root/.woven-instance"
chmod 700 "$root"
if command -v sha256sum >/dev/null 2>&1; then root_hash="$(printf '%s' "$root" | sha256sum | cut -d ' ' -f1)"
else root_hash="$(printf '%s' "$root" | shasum -a 256 | cut -d ' ' -f1)"; fi
service_owned() { [ ! -L "$service_file" ] && { [ ! -e "$service_file" ] || grep -Fqx "<!-- Woven Matter Pi Bot: $root_hash -->" "$service_file" || grep -Fqx "# Woven Matter Pi Bot: $root_hash" "$service_file"; }; }
domain=
select_domain() {
  domain="gui/$(id -u)"
  if ! launchctl print "$domain" >/dev/null 2>&1; then domain="user/$(id -u)"; fi
}
service_action() {
  local action="$1"
  service_owned || abort foreign_service 'Service label belongs to another root.'
  if [ "$os" = linux ]; then
    [ "$manager" = systemd ] || return 1
    systemctl --user "$action" "$unit" >&2
  else
    select_domain
    case "$action" in
      stop)
        launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
        # launchd still lists a service while it exits, and a start in that moment would be lost.
        for ((attempt=0; attempt<60; attempt++)); do
          launchctl print "$domain/$label" >/dev/null 2>&1 || return 0
          sleep 0.5
        done
        return 1 ;;
      start) launchctl print "$domain/$label" >/dev/null 2>&1 || launchctl bootstrap "$domain" "$service_file" >&2 ;;
      restart) service_action stop && service_action start ;;
    esac
  fi
}
# Removing data includes each bot's container and workspace. Only this installation's bots are
# named, because a Docker daemon or Apple's shared services can also serve other Pi Bots. The
# database is what names them, so nothing is deleted if they can't be removed: run this again.
remove_bot_runtimes() {
  local current_node listing backend binary install_root app_root ids id output failures=
  current_node="$root/node/$(cat "$root/current/.node-version" 2>/dev/null || true)/bin/node"
  [ "$delete_data" = yes ] && [ -x "$current_node" ] && [ -f "$root/config.toml" ] || return 0
  listing="$("$current_node" - "$root/config.toml" "$root/current/packages/server/dist/config.js" 2>/dev/null <<'JS'
const fs = require('node:fs'), path = require('node:path'), { pathToFileURL } = require('node:url');
const [configPath, parser] = process.argv.slice(2);
import(pathToFileURL(parser).href).then(({ parseConfig }) => {
  const config = parseConfig(fs.readFileSync(configPath, 'utf8'), path.dirname(configPath), configPath);
  const environment = config.environment;
  for (const value of [environment.backend, environment.binary, environment.install_root, environment.app_root]) console.log(value ?? '');
  if (fs.existsSync(config.paths.database)) {
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync(config.paths.database, { readOnly: true });
    for (const row of db.prepare('SELECT id FROM pibot_bots').all()) console.log(row.id);
    db.close();
  }
}).catch(() => { process.exitCode = 1; });
JS
)" || abort config "Pi Bot's config could not be read, so its bots' containers could not be removed. Nothing was deleted."
  backend="$(printf '%s\n' "$listing" | sed -n 1p)"; binary="$(printf '%s\n' "$listing" | sed -n 2p)"
  install_root="$(printf '%s\n' "$listing" | sed -n 3p)"; app_root="$(printf '%s\n' "$listing" | sed -n 4p)"
  ids="$(printf '%s\n' "$listing" | sed -n '5,$p')"
  case "$backend" in docker) binary="${binary:-docker}" ;; container) binary="${binary:-container}" ;; *) return 0 ;; esac
  # With its CLI gone there is nothing left to ask, and nothing here can reach its containers.
  command -v "$binary" >/dev/null 2>&1 || return 0
  if [ "$backend" = docker ]; then
    for id in $ids; do
      [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
      output="$("$binary" rm -f "pi-bot-$id" 2>&1)" || case "$output" in *[Nn]o\ such*) ;; *) failures="$output" ;; esac
      output="$("$binary" volume rm "pi-bot-$id-workspace" 2>&1)" || case "$output" in *[Nn]o\ such*) ;; *) failures="$output" ;; esac
    done
  else
    remove_apple_containers
  fi
  [ -z "$failures" ] || abort runtime "Bots' containers could not be removed, so nothing was deleted: ${failures:0:300}"
}
# Apple's CLI reaches its services through its launchd domain, which an SSH session doesn't share
# with the agent that started them. A one-shot job in that domain runs what can't run from here.
remove_apple_containers() {
  local job result retire=no helper others attempt id
  local valid=()
  for id in $ids; do [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] && valid+=("$id"); done
  case "$binary" in
    "$shared_runtime"/*)
      rm -f "$shared_runtime/instances/$root_hash"
      if [ -z "$(ls -A "$shared_runtime/instances" 2>/dev/null || true)" ]; then retire=yes; fi ;;
  esac
  job="$(mktemp -d "$root/.runtime.XXXXXX")"
  result="$job/result"
  cat > "$job/run.sh" <<'SCRIPT'
binary="$1"; install_root="$2"; app_root="$3"; retire="$4"; result="$5"; shift 5
{
  if ! "$binary" system status >/dev/null 2>&1; then
    start=(system start --disable-kernel-install)
    [ -z "$install_root" ] || start+=(--install-root "$install_root")
    [ -z "$app_root" ] || start+=(--app-root "$app_root")
    "$binary" "${start[@]}" >/dev/null 2>&1 || echo "failed Apple's container services would not start."
  fi
  for id in "$@"; do
    output="$("$binary" delete --force "pi-bot-$id" 2>&1)" || case "$output" in *ot\ found*|*otFound*) ;; *) echo "failed ${output%%$'\n'*}" ;; esac
    if "$binary" volume inspect "pi-bot-$id-workspace" >/dev/null 2>&1; then
      output="$("$binary" volume delete "pi-bot-$id-workspace" 2>&1)" || echo "failed ${output%%$'\n'*}"
    fi
  done
  # Anything still here belongs to someone else, as does the runtime it needs.
  others="$("$binary" list --all --quiet 2>/dev/null | grep -cvx buildkit || true)"
  echo "others $others"
  if [ "$retire" = yes ] && [ "$others" = 0 ]; then "$binary" system stop >/dev/null 2>&1 || true; fi
} > "$result.partial" 2>&1
mv "$result.partial" "$result"
SCRIPT
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key><string>%s</string><key>RunAtLoad</key><true/><key>ProgramArguments</key><array>' "$label.cleanup"
    for argument in /bin/bash "$job/run.sh" "$binary" "$install_root" "$app_root" "$retire" "$result" ${valid[@]+"${valid[@]}"}; do
      printf '<string>%s</string>' "$(xml "$argument")"
    done
    printf '</array></dict></plist>\n'
  } > "$job/job.plist"
  select_domain
  launchctl bootstrap "$domain" "$job/job.plist" >/dev/null 2>&1 || true
  for ((attempt=0; attempt<240; attempt++)); do
    [ ! -f "$result" ] || break
    sleep 0.5
  done
  launchctl bootout "$domain/$label.cleanup" >/dev/null 2>&1 || true
  if [ ! -f "$result" ]; then
    rm -rf "$job"
    failures="Apple's container services did not answer."
    return 0
  fi
  failures="$(sed -n 's/^failed //p' "$result" | head -1)"
  others="$(sed -n 's/^others //p' "$result")"
  rm -rf "$job"
  if [ -z "$failures" ] && [ "$retire" = yes ] && [ "$others" = 0 ]; then
    launchctl list 2>/dev/null | awk '$3 ~ /^com\.apple\.container\./ {print $3}' | while IFS= read -r helper; do
      launchctl bootout "$domain/$helper" >/dev/null 2>&1 || true
    done
    rm -rf "$shared_runtime"
  fi
}
if [ "$command_name" != install ]; then
  service_mode="$(cat "$root/.service-mode" 2>/dev/null || printf no)"
  if [ "$command_name" = uninstall ]; then
    [ "$service_mode" != no ] || [ "$running" != true ] || abort running 'Stop the caller-supervised process before uninstalling.'
    if [ "$service_mode" = yes ]; then
      service_action stop
      if [ "$os" = linux ]; then systemctl --user disable "$unit" >&2; fi
      rm -f "$service_file"
      if [ "$os" = linux ]; then systemctl --user daemon-reload >&2; fi
    fi
    remove_bot_runtimes
    rm -f "$root/current" "$root/run-server" "$root/.service-mode"
    rm -rf "$root/releases" "$root/node" "$root/tooling" "$root/pnpm-store"
    if [ "$delete_data" = yes ]; then rm -rf "$root/data"; rm -f "$root/config.toml"; remove_root=yes; fi
  elif [ "$service_mode" = yes ]; then service_action "$command_name"
  else progress caller-supervises; fi
  printf '{"schema":1,"action":'; json "$command_name"; printf ',"supervisor":'
  if [ "$service_mode" = no ]; then json caller; else json "$manager"; fi
  printf '}\n'; exit
fi
progress staging
mkdir -p "$root/releases" "$root/node" "$root/pnpm-store" "$root/data"
chmod 700 "$root/releases" "$root/node" "$root/pnpm-store" "$root/data"
stage="$(mktemp -d "$root/.stage.XXXXXX")"
scratch="$(mktemp -d "$root/.health.XXXXXX")"
if [ "$bundle" = - ]; then cat > "$stage/bundle.tar.gz"; bundle="$stage/bundle.tar.gz"; fi
# Reject traversal and links before extraction, including link targets outside root.
check_tar() {
  tar -tzf "$1" > "$stage/archive-list"
  while IFS= read -r member; do
    case "$member" in /*|..|../*|*/../*|*/..) abort bundle 'Archive contains an unsafe path.' ;; esac
  done < "$stage/archive-list"
  tar -tvzf "$1" > "$stage/archive-details"
  if grep -Eq '^[^d-]' "$stage/archive-details"; then abort bundle 'Only regular files and directories are supported in a bundle.'; fi
}
mkdir "$stage/release"
check_tar "$bundle"
tar -xzf "$bundle" -C "$stage/release"
[ -f "$stage/release/manifest.json" ] && [ -f "$stage/release/packages/server/dist/cli.js" ] || abort bundle 'Bundle is missing manifest or server entry.'
progress node
archive_name="node-v$node_version-$os-$arch.tar.gz"
archive="$root/node/$archive_name"
if [ ! -f "$archive" ]; then
  run_child "$stage" curl --fail --location --silent --show-error "https://nodejs.org/dist/v$node_version/$archive_name" -o "$stage/node.tar.gz"
  [ "$(sha256 "$stage/node.tar.gz")" = "$node_sha" ] || abort checksum 'Node archive SHA-256 mismatch.'
  mv "$stage/node.tar.gz" "$archive"
fi
[ "$(sha256 "$archive")" = "$node_sha" ] || abort checksum 'Node archive SHA-256 mismatch.'
node="$root/node/$node_version/bin/node"
if [ ! -x "$node" ]; then
  mkdir "$stage/node"
  tar -xzf "$archive" --strip-components=1 -C "$stage/node"
  "$stage/node/bin/node" --version >/dev/null 2>&1 || abort node 'Verified Node archive cannot execute on this host.'
  mv "$stage/node" "$root/node/$node_version"
fi
# Apple signs this package and needs no administrator to run it from here, so a Mac needs neither
# an admin password nor Docker. An installed `container` stays the user's own and is used as it is.
if [ "$environment" = container ] && [ -z "$container_cli" ]; then
  if [ -n "$container_version" ]; then
    container_private="$shared_runtime/container/$container_version"
    if [ ! -x "$container_private/bin/container" ]; then
      progress container
      run_child "$stage" curl --fail --location --silent --show-error "https://github.com/apple/container/releases/download/$container_version/container-$container_version-installer-signed.pkg" -o "$stage/container.pkg"
      [ "$(sha256 "$stage/container.pkg")" = "$container_sha" ] || abort checksum 'Apple container package SHA-256 mismatch.'
      pkgutil --check-signature "$stage/container.pkg" 2>/dev/null | grep -q 'Developer ID Installer: Apple Inc\.' || abort container 'Apple container package is not signed by Apple.'
      pkgutil --expand-full "$stage/container.pkg" "$stage/container-package" >/dev/null || abort container 'Apple container package could not be read.'
      [ -x "$stage/container-package/Payload/bin/container" ] || abort container 'Apple container package has no CLI.'
      mkdir -p "$shared_runtime/container"
      chmod 700 "$shared_runtime"
      # Another installation can get here first with the same verified package.
      mv "$stage/container-package/Payload" "$container_private" 2>/dev/null || [ -x "$container_private/bin/container" ] || abort container 'Apple container could not be installed.'
      rm -rf "$stage/container.pkg" "$stage/container-package"
    fi
    mkdir -p "$shared_runtime/instances"
    : > "$shared_runtime/instances/$root_hash"
    container_cli="$container_private/bin/container"
  elif [ -n "$docker_cli" ]; then environment=docker
  else environment=none; fi
fi
export PATH="$(dirname "$node"):$PATH"
# Node is now verified and private. Use it to validate the source-only manifest
# and tooling records, never to parse credentials or persistent application data.
"$node" - "$stage/release" "$commit" <<'JS' >&2
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const root = process.argv[2], expected = process.argv[3];
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json')));
const hash = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, 'pnpm-lock.yaml'))).digest('hex');
if (manifest.commit !== expected || manifest.protocol !== 1 || manifest.lockSha256 !== hash) throw Error('Bundle manifest does not match the requested commit, protocol or lockfile.');
JS
progress dependencies
mkdir "$stage/tooling"
if [ "$tooling" = - ]; then
  cat > "$stage/tooling.tar.gz"; check_tar "$stage/tooling.tar.gz"; tar -xzf "$stage/tooling.tar.gz" -C "$stage/tooling"
else cp "$tooling/package.json" "$tooling/package-lock.json" "$stage/tooling/"; fi
"$node" - "$stage/tooling" "$pnpm_version" <<'JS' >&2
const fs = require('node:fs'), path = require('node:path');
const root = process.argv[2], version = process.argv[3];
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json')));
const lock = JSON.parse(fs.readFileSync(path.join(root, 'package-lock.json')));
if (pkg.dependencies.pnpm !== version || lock.packages['node_modules/pnpm'].version !== version) throw Error('Tooling does not lock the requested pnpm version.');
JS
run_child "$stage/tooling" npm ci --no-audit --no-fund
pnpm="$stage/tooling/node_modules/.bin/pnpm"
[ "$("$pnpm" --version)" = "$pnpm_version" ] || abort tooling 'Installed pnpm version mismatch.'
run_child "$stage/release" "$pnpm" install --prod --frozen-lockfile --filter '@wovenmatter/pi-bot...' --store-dir "$root/pnpm-store"
printf '%s\n' "$node_version" > "$stage/release/.node-version"
port_busy() { (echo > "/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }
free_port() {
  local candidate="${1:-47310}"
  while [ "$candidate" -le 65535 ]; do
    if [ "$candidate" -ne 4317 ] && [ "$candidate" != "${port:-0}" ] && [ "$candidate" != "${managed_port:-0}" ] && ! port_busy "$candidate"; then printf '%s' "$candidate"; return; fi
    candidate=$((candidate + 1))
  done
  return 1
}
if [ -n "$managed_port" ]; then
  [ -z "$port" ] || [ "$port" = "$managed_port" ] || abort config 'Existing config owns its port; refusing to replace it.'
  port="$managed_port"
elif [ -n "$port" ]; then ! port_busy "$port" || abort port 'Requested port is in use.'
else port="$(free_port)" || abort port 'No free loopback port is available.'; fi
write_config() {
  printf '[server]\nhost = "127.0.0.1"\nport = %s\nweb_dir = ' "$2"; json "$1/apps/web/dist"
  printf '\n\n[storage]\ndata_dir = '; json "$3"
  printf '\n\n[credentials]\nbackend = "encrypted-sqlite"\n\n[environment]\nbackend = "%s"\n' "$4"
  case "$4" in
    docker) printf 'binary = '; json "$docker_cli"; printf '\n' ;;
    container)
      printf 'binary = '; json "$container_cli"; printf '\n'
      case "$container_cli" in
        "$shared_runtime"/*) printf 'install_root = '; json "${container_cli%/bin/container}"; printf '\napp_root = '; json "$shared_runtime/container-data"; printf '\n' ;;
      esac ;;
  esac
  printf '\n[models]\ndefault_profile = "default"\n\n[profiles.default]\nname = "Default"\nmain = "openai/gpt-6-sol"\n'
}
progress health
scratch_port="$(free_port)" || abort port 'No scratch port is available.'
mkdir "$scratch/data"
write_config "$stage/release" "$scratch_port" "$scratch/data" none > "$scratch/config.toml"
PIBOT_RESTART_EXIT_CODE=75 "$node" "$stage/release/packages/server/dist/cli.js" serve --config "$scratch/config.toml" > "$scratch/server.log" 2>&1 &
scratch_pid=$!
wait_health() {
  local attempt
  for ((attempt=0; attempt<60; attempt++)); do
    if health "$1" >/dev/null; then return 0; fi
    if [ -n "${2:-}" ] && ! kill -0 "$2" 2>/dev/null; then return 1; fi
    sleep 0.5
  done
  return 1
}
wait_health "$scratch_port" "$scratch_pid" || abort health 'Candidate did not become healthy against disposable data.'
kill "$scratch_pid" 2>/dev/null || true; wait "$scratch_pid" 2>/dev/null || true; scratch_pid=
# Never replace an immutable release already in use (including dirty Debug builds).
if [ -d "$root/releases/$commit" ]; then
  [ "$(sha256 "$bundle")" = "$(cat "$root/releases/$commit/.bundle-sha256" 2>/dev/null || true)" ] || abort commit_conflict 'This commit is already installed with different bundle contents.'
  rm -rf "$stage/release"
else
  sha256 "$bundle" > "$stage/release/.bundle-sha256"
  mv "$stage/release" "$root/releases/$commit"
  new_release=yes
fi
if [ ! -f "$root/config.toml" ]; then write_config "$root/current" "$port" "$root/data" "$environment" > "$root/config.toml"; fi
chmod 600 "$root/config.toml"
previous_service="$(cat "$root/.service-mode" 2>/dev/null || printf no)"
if [ "$service" = yes ] || [ "$previous_service" = yes ]; then
  service_owned || abort foreign_service 'Service label belongs to another root.'
  if [ -f "$service_file" ]; then cp "$service_file" "$stage/previous-service"; fi
fi
# The runner follows current, including that release's Node version, on restart.
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\nexport PIBOT_RESTART_EXIT_CODE=75\nroot='; printf '%q' "$root"
  printf '\nversion="$(cat "$root/current/.node-version")"\nexec "$root/node/$version/bin/node" "$root/current/packages/server/dist/cli.js" serve --config "$root/config.toml"\n'
} > "$root/run-server"
chmod 700 "$root/run-server"
swap_current() {
  rm -f "$root/.current-next"
  ln -s "releases/$1" "$root/.current-next"
  # -f alone follows directory symlinks on BSD; rename through Node instead.
  "$node" -e 'require("node:fs").renameSync(process.argv[1],process.argv[2])' "$root/.current-next" "$root/current"
}
write_service() {
  mkdir -p "$(dirname "$service_file")"
  if [ "$os" = linux ]; then
    # systemd specifiers and quoted ExecStart have their own escaping rules.
    escaped_root="${root//\\/\\\\}"; escaped_root="${escaped_root//\"/\\\"}"; escaped_root="${escaped_root//%/%%}"
    cat > "$service_file" <<UNIT
# Woven Matter Pi Bot: $root_hash
[Unit]
Description=Woven Matter Pi Bot ($instance)
[Service]
Type=simple
ExecStart="$escaped_root/run-server"
Restart=always
RestartSec=2
Environment=PIBOT_RESTART_EXIT_CODE=75
[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload >&2 && systemctl --user enable "$unit" >&2
  else
    cat > "$service_file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!-- Woven Matter Pi Bot: $root_hash -->
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$(xml "$root/run-server")</string></array>
<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>
<key>EnvironmentVariables</key><dict><key>PIBOT_RESTART_EXIT_CODE</key><string>75</string></dict>
<key>StandardOutPath</key><string>$(xml "$root/server.log")</string>
<key>StandardErrorPath</key><string>$(xml "$root/server.log")</string>
</dict></plist>
PLIST
  fi
}
# A code update can migrate the database, and rollback cannot undo that. Take a
# consistent copy first; the running server keeps serving during VACUUM INTO.
if [ -f "$root/data/pi-bot.sqlite" ] && [ -n "$current_commit" ] && [ "$current_commit" != "$commit" ]; then
  progress backup
  mkdir -p "$root/data/backups"; chmod 700 "$root/data/backups"
  backup="$root/data/backups/before-$commit.sqlite"
  rm -f "$backup"
  "$node" -e 'const {DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1],{readOnly:true});db.prepare("VACUUM INTO ?").run(process.argv[2]);db.close()' "$root/data/pi-bot.sqlite" "$backup" >&2 \
    || abort backup 'The database could not be backed up, so the update was not applied.'
  chmod 600 "$backup"
  # Retain the two most recent update backups.
  ls -1t "$root/data/backups"/before-*.sqlite 2>/dev/null | tail -n +3 | while IFS= read -r stale; do rm -f "$stale"; done
fi
progress activating
promotion_pending=yes
if [ "$previous_service" = yes ]; then service_attempted=yes; service_action stop; fi
swap_current "$commit"
activation_ok=yes
if [ "$service" = yes ]; then
  service_attempted=yes
  if [ "$manager" = none ] || ! write_service || ! service_action start || ! wait_health "$port"; then activation_ok=no; fi
fi
if [ "$activation_ok" = no ]; then
  abort activation 'Service activation failed; restoring the previous current release.'
fi
if [ "$previous_service" = yes ] && [ "$service" = no ]; then
  if [ "$os" = linux ]; then systemctl --user disable "$unit" >&2; fi
  rm -f "$service_file"
  if [ "$os" = linux ]; then systemctl --user daemon-reload >&2; fi
fi
if [ -d "$root/tooling" ]; then mv "$root/tooling" "$stage/previous-tooling"; fi
mv "$stage/tooling" "$root/tooling"; tooling_replaced=yes
printf '%s\n' "$service" > "$root/.service-mode"
promotion_pending=no
# Retain the active and immediately previous release only, after activation.
for release in "$root/releases/"*; do
  [ -d "$release" ] || continue
  case "${release##*/}" in "$commit"|"$current_commit") ;; *) rm -rf "$release" ;; esac
done
if [ "$service" = no ]; then progress caller-supervises
elif [ "$lingering" = false ]; then printf 'User lingering is off; this service stops at logout.\n' >&2; fi
printf '{"schema":1,"commit":'; json "$commit"; printf ',"port":%s,"root":' "$port"; json "$root"
printf ',"node":'; json "$node"; printf ',"entry":'; json "$root/current/packages/server/dist/cli.js"
printf ',"config":'; json "$root/config.toml"; printf ',"lingering":%s}\n' "$lingering"
