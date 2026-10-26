# Sourced by the trusted Woven manager over the existing noninteractive SSH flow.
# wm_payload names a private temporary JSON file. Never echo its contents.
set -eu
command -v python3 >/dev/null
command -v tailscale >/dev/null
if docker info >/dev/null 2>&1; then wm_docker=docker
elif sudo -n docker info >/dev/null 2>&1; then wm_docker='sudo -n docker'
else exit 69; fi
wm_docker_version="$($wm_docker version --format '{{.Server.Version}}')"
wm_docker_major="${wm_docker_version%%.*}"
case "$wm_docker_major" in ''|*[!0-9]*) exit 69 ;; esac
[ "$wm_docker_major" -ge 28 ] || exit 69
wm_root="$HOME/.local/share/wovenmatter-executor"
mkdir -p "$wm_root/data"
chmod 700 "$wm_root" "$wm_root/data"
wm_runtime_uid="$(id -u)"
wm_runtime_gid="$(id -g)"
if [ "$wm_runtime_uid" = 0 ]; then wm_runtime_uid=1000; wm_runtime_gid=1000; fi
wm_network=wovenmatter-executor
if $wm_docker network inspect "$wm_network" >/dev/null 2>&1; then
  test "$($wm_docker network inspect --format '{{index .Labels "sh.wovenmatter.executor"}}' "$wm_network")" = managed-v1
else
  $wm_docker network create --driver bridge \
    --opt com.docker.network.bridge.enable_icc=false \
    --label sh.wovenmatter.executor=managed-v1 "$wm_network" >/dev/null
fi
wm_container_hardened() {
  wm_name="$1"
  wm_user="$($wm_docker inspect --format '{{.Config.User}}' "$wm_name")"
  case "$wm_user" in ''|0|0:*|root|root:*) return 1 ;; esac
  test "$($wm_docker inspect --format '{{.HostConfig.NetworkMode}}' "$wm_name")" = "$wm_network" \
    && test "$($wm_docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$wm_name")" = true \
    && test "$($wm_docker inspect --format '{{json .HostConfig.PortBindings}}' "$wm_name")" = '{"4312/tcp":[{"HostIp":"127.0.0.1","HostPort":"4312"}]}' \
    && test "$($wm_docker inspect --format '{{json .HostConfig.CapDrop}}' "$wm_name")" = '["ALL"]' \
    && test "$($wm_docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$wm_name")" = '["no-new-privileges"]' \
    && test "$($wm_docker inspect --format '{{.HostConfig.PidsLimit}}' "$wm_name")" = 512
}
# Verify the selected private origin belongs to this machine before installing.
tailscale status --json > "$wm_root/host.json"
tailscale serve status --json > "$wm_root/serve.json"
python3 - "$wm_payload" "$wm_root" <<'PY'
import base64, hashlib, json, pathlib, re, sys, urllib.parse
payload=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2])
# The manager implements Executor's V2 app API only (EXECUTOR_API_MAJOR).
assert re.fullmatch(r'2\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?', payload['version'])
(root/'version').write_text(payload['version'])
url=urllib.parse.urlparse(payload['origin'])
host=json.load(open(root/'host.json'))['Self']['DNSName'].rstrip('.')
assert url.scheme=='https' and url.hostname==host and url.port==8443
serve=json.load(open(root/'serve.json'))
existing=serve.get('Web', {}).get(host+':8443')
assert '8443' not in serve.get('TCP', {}) or existing, 'HTTPS port is used by another service'
if existing:
    assert existing.get('Handlers', {}).get('/', {}).get('Proxy') in ('http://127.0.0.1:4312', 'http://localhost:4312'), 'HTTPS port is already used by another service'
env=root/'runtime.env'
content='\n'.join(['EXECUTOR_API_KEY='+payload['apiKey'], 'EXECUTOR_ENCRYPTION_KEY='+payload['encryptionKey'], 'EXECUTOR_BROWSER_ORIGIN='+payload['origin'].rstrip('/'), 'EXECUTOR_PORT=4312', 'EXECUTOR_DATA_DIR=/data', 'EXECUTOR_NO_UPDATE_CHECK=1'])+'\n'
if env.exists():
    previous=env.read_text()
    for key in ('EXECUTOR_API_KEY', 'EXECUTOR_ENCRYPTION_KEY'):
        assert next(x for x in previous.splitlines() if x.startswith(key+'=')) == next(x for x in content.splitlines() if x.startswith(key+'=')), 'Existing Executor keys differ; refusing to replace credentials'
env.write_text(content); env.chmod(0o600)
(root/'Dockerfile').write_text(payload['dockerfile'])
for directory, package_key, lock_key in (
    ('npm-runtime', 'npmRuntimePackage', 'npmRuntimeLock'),
    ('executor-runtime', 'executorRuntimePackage', 'executorRuntimeLock')):
    target=root/directory
    target.mkdir(mode=0o700, exist_ok=True)
    package=json.loads(payload[package_key]); lock=json.loads(payload[lock_key])
    assert package.get('private') is True and lock.get('lockfileVersion') == 3
    assert lock.get('packages', {}).get('', {}).get('name') == package.get('name')
    (target/'package.json').write_text(payload[package_key])
    (target/'package-lock.json').write_text(payload[lock_key])
security=root/'security'
security.mkdir(mode=0o700, exist_ok=True)
for relative, encoded in payload['securityFiles'].items():
    path=pathlib.PurePosixPath(relative)
    assert not path.is_absolute() and path.parts and '..' not in path.parts
    target=security.joinpath(*path.parts)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    target.write_bytes(base64.b64decode(encoded, validate=True))
# Each explicit refresh gets a new build; retrying the same payload is idempotent.
generation=payload.get('generation', '')
assert not generation or re.fullmatch(r'[a-f0-9-]{36}', generation)
(root/'image-tag').write_text(payload['version']+'-'+hashlib.sha256((payload['dockerfile']+generation).encode()).hexdigest()[:16])
PY
# Build before retiring the previous owned runtime. Exact image tags identify
# this transaction; later setup resolves the supported channel again.
wm_image="wovenmatter/executor:$(cat "$wm_root/image-tag")"
wm_previous=false
wm_previous_safe=false
wm_new=false
wm_healthy=false
wm_rollback() {
  if [ "$wm_healthy" = false ] && [ "$wm_new" = true ]; then
    $wm_docker rm -f wovenmatter-executor >/dev/null 2>&1 || true
    if [ "$wm_previous" = true ] && [ "$wm_previous_safe" = true ]; then
      $wm_docker rename wovenmatter-executor-previous wovenmatter-executor
      $wm_docker start wovenmatter-executor >/dev/null
    fi
  fi
  rm -f "$wm_payload" "$wm_root/host.json" "$wm_root/serve.json"
}
trap wm_rollback EXIT
if $wm_docker inspect wovenmatter-executor >/dev/null 2>&1; then
  test "$($wm_docker inspect --format '{{index .Config.Labels "sh.wovenmatter.executor"}}' wovenmatter-executor)" = 'managed-v1'
  if [ "$($wm_docker inspect --format '{{.Config.Image}}' wovenmatter-executor)" = "$wm_image" ] \
      && wm_container_hardened wovenmatter-executor; then
    $wm_docker start wovenmatter-executor >/dev/null
    wm_current=true
  else
    wm_current=false
  fi
else
  wm_current=false
  python3 - <<'PY_PORT'
import socket
with socket.socket() as client:
    client.settimeout(1)
    assert client.connect_ex(('127.0.0.1', 4312)) != 0, 'Loopback port 4312 is already used by another service'
PY_PORT
fi
if [ "$wm_current" = false ]; then
  printf '%s\n' '*' '!Dockerfile' '!npm-runtime/' '!npm-runtime/package*.json' \
    '!executor-runtime/' '!executor-runtime/package*.json' '!security/' '!security/**' > "$wm_root/.dockerignore"
  # An old host-network/root container is an active exposure, not rollback
  # coverage. Stop it before any potentially slow replacement build.
  if $wm_docker inspect wovenmatter-executor >/dev/null 2>&1 \
      && ! wm_container_hardened wovenmatter-executor; then
    $wm_docker stop wovenmatter-executor >/dev/null
  fi
  $wm_docker build --pull --no-cache --tag "$wm_image" "$wm_root" >/dev/null 2>&1
  if $wm_docker inspect wovenmatter-executor >/dev/null 2>&1; then
    # A previous failed rollback is retained for inspection, never overwritten.
    if $wm_docker inspect wovenmatter-executor-previous >/dev/null 2>&1; then exit 69; fi
    if wm_container_hardened wovenmatter-executor; then wm_previous_safe=true; fi
    $wm_docker stop wovenmatter-executor >/dev/null
    if ! $wm_docker rename wovenmatter-executor wovenmatter-executor-previous; then
      if [ "$wm_previous_safe" = true ]; then $wm_docker start wovenmatter-executor >/dev/null; fi
      exit 69
    fi
    wm_previous=true
  fi
  # The former image ran as root. Migrate only root-owned persistent entries
  # while the old container is stopped; the helper has no network or other caps.
  $wm_docker run --rm --network none --user 0:0 --read-only \
      --cap-drop ALL --cap-add CHOWN --security-opt no-new-privileges --pids-limit 64 \
      --mount "type=bind,src=$wm_root/data,dst=/data" --entrypoint /usr/bin/find "$wm_image" \
      /data -xdev -uid 0 -exec /usr/bin/chown --no-dereference "$wm_runtime_uid:$wm_runtime_gid" '{}' +
  wm_new=true
  $wm_docker run -d --name wovenmatter-executor --label sh.wovenmatter.executor=managed-v1 \
      --restart unless-stopped --network "$wm_network" --publish 127.0.0.1:4312:4312 \
      --env-file "$wm_root/runtime.env" --env HOME=/data --user "$wm_runtime_uid:$wm_runtime_gid" \
      --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
      --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 --init \
      --mount "type=bind,src=$wm_root/data,dst=/data" "$wm_image" >/dev/null
  wm_container_hardened wovenmatter-executor
fi
# Require authenticated readiness before publishing the route or deleting the
# rollback container. Keys stay inside the private payload, never command args.
wm_wait_ready() {
python3 - "$wm_payload" "$1" <<'PY_READY'
import json, sys, time, urllib.request
payload=json.load(open(sys.argv[1]))
origin='http://127.0.0.1:4312' if sys.argv[2]=='local' else payload['origin'].rstrip('/')
deadline=time.monotonic()+90
while True:
    try:
        request=urllib.request.Request(origin+'/v1/apps', headers={'Authorization':'Bearer '+payload['apiKey']})
        with urllib.request.urlopen(request, timeout=3) as response:
            assert response.status==200
        break
    except Exception:
        if time.monotonic()>=deadline: raise SystemExit(69)
        time.sleep(.5)
PY_READY
}
wm_wait_ready local
# Tailscale Serve is private to the tailnet. Never enable Funnel/public exposure.
if tailscale serve --bg --https=8443 http://127.0.0.1:4312 >/dev/null 2>&1; then :
elif sudo -n tailscale serve --bg --https=8443 http://127.0.0.1:4312 >/dev/null 2>&1; then :
else exit 69; fi
# Serve accepting configuration does not prove TLS or the private route works.
# Keep rollback available until the authenticated HTTPS endpoint responds.
wm_wait_ready private
wm_healthy=true
if [ "$wm_previous" = true ]; then $wm_docker rm wovenmatter-executor-previous >/dev/null; fi
