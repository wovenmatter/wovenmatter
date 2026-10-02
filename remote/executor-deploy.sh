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
import json, pathlib, sys, urllib.parse
payload=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2])
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
# Refuse a name collision; preserve all unrelated containers and HTTPS routes.
if $wm_docker inspect wovenmatter-executor >/dev/null 2>&1; then
  test "$($wm_docker inspect --format '{{index .Config.Labels "sh.wovenmatter.executor"}}' wovenmatter-executor)" = 'managed-v1'
  $wm_docker start wovenmatter-executor >/dev/null
else
  # Never expose an unrelated loopback service through the new private route.
  python3 - <<'PY_PORT'
import socket
with socket.socket() as client:
    client.settimeout(1)
    assert client.connect_ex(('127.0.0.1', 4312)) != 0, 'Loopback port 4312 is already used by another service'
PY_PORT
  printf '%s\n' '*' '!Dockerfile' > "$wm_root/.dockerignore"
  $wm_docker build --tag wovenmatter/executor:2.0.0-beta.7 "$wm_root" >/dev/null 2>&1
  $wm_docker run -d --name wovenmatter-executor --label sh.wovenmatter.executor=managed-v1 \
    --restart unless-stopped --network host --env-file "$wm_root/runtime.env" \
    --mount "type=bind,src=$wm_root/data,dst=/data" \
    wovenmatter/executor:2.0.0-beta.7 >/dev/null
fi
# Tailscale Serve is private to the tailnet. Never enable Funnel/public exposure.
if tailscale serve --bg --https=8443 http://127.0.0.1:4312 >/dev/null 2>&1; then :
elif sudo -n tailscale serve --bg --https=8443 http://127.0.0.1:4312 >/dev/null 2>&1; then :
else exit 69; fi
rm -f "$wm_root/host.json" "$wm_root/serve.json"
