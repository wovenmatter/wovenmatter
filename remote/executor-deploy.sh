# Sourced by the trusted Woven manager over the existing noninteractive SSH flow.
# wm_payload names a private temporary JSON file. Never echo its contents.
set -eu
command -v python3 >/dev/null
command -v tailscale >/dev/null
if docker info >/dev/null 2>&1; then wm_docker=docker
elif sudo -n docker info >/dev/null 2>&1; then wm_docker='sudo -n docker'
else exit 69; fi
wm_root="$HOME/.local/share/wovenmatter-executor"
mkdir -p "$wm_root/data"
chmod 700 "$wm_root" "$wm_root/data"
# Verify the selected private origin belongs to this machine before installing.
tailscale status --json > "$wm_root/host.json"
tailscale serve status --json > "$wm_root/serve.json"
python3 - "$wm_payload" "$wm_root" <<'PY'
import json, pathlib, re, sys, urllib.parse
payload=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2])
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
PY
# Build before retiring the previous owned runtime. Exact image tags identify
# this transaction; later setup resolves the supported channel again.
wm_version=$(cat "$wm_root/version")
wm_image="wovenmatter/executor:$wm_version"
wm_previous=false
wm_new=false
wm_healthy=false
wm_rollback() {
  if [ "$wm_healthy" = false ] && [ "$wm_new" = true ]; then
    $wm_docker rm -f wovenmatter-executor >/dev/null 2>&1 || true
    if [ "$wm_previous" = true ]; then
      $wm_docker rename wovenmatter-executor-previous wovenmatter-executor
      $wm_docker start wovenmatter-executor >/dev/null
    fi
  fi
  rm -f "$wm_payload" "$wm_root/host.json" "$wm_root/serve.json"
}
trap wm_rollback EXIT
if $wm_docker inspect wovenmatter-executor >/dev/null 2>&1; then
  test "$($wm_docker inspect --format '{{index .Config.Labels "sh.wovenmatter.executor"}}' wovenmatter-executor)" = 'managed-v1'
  if [ "$($wm_docker inspect --format '{{.Config.Image}}' wovenmatter-executor)" = "$wm_image" ]; then
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
  printf '%s\n' '*' '!Dockerfile' > "$wm_root/.dockerignore"
  $wm_docker build --tag "$wm_image" "$wm_root" >/dev/null 2>&1
  if $wm_docker inspect wovenmatter-executor >/dev/null 2>&1; then
    # A previous failed rollback is retained for inspection, never overwritten.
    if $wm_docker inspect wovenmatter-executor-previous >/dev/null 2>&1; then exit 69; fi
    $wm_docker stop wovenmatter-executor >/dev/null
    if ! $wm_docker rename wovenmatter-executor wovenmatter-executor-previous; then
      $wm_docker start wovenmatter-executor >/dev/null
      exit 69
    fi
    wm_previous=true
  fi
  wm_new=true
  $wm_docker run -d --name wovenmatter-executor --label sh.wovenmatter.executor=managed-v1 \
      --restart unless-stopped --network host --env-file "$wm_root/runtime.env" \
      --mount "type=bind,src=$wm_root/data,dst=/data" "$wm_image" >/dev/null

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
