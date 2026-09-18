#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
asset="${temporary}/WovenMatter_0.1.0_arm64.dmg"
printf 'fixture\n' > "$asset"
scripts/generate-release-manifest.sh 0.1.0 1 "$asset" "${temporary}/latest-mac.json"

jq -e '
  .schema_version == 1
  and .version == "0.1.0"
  and .build == 1
  and .architecture == "arm64"
  and .minimum_macos == "26.0"
  and .download_url == "https://github.com/wovenmatter/wovenmatter/releases/download/v0.1.0/WovenMatter_0.1.0_arm64.dmg"
  and .release_url == "https://github.com/wovenmatter/wovenmatter/releases/tag/v0.1.0"
  and (.sha256 | test("^[0-9a-f]{64}$"))
' "${temporary}/latest-mac.json" >/dev/null

if scripts/publish-release.sh invalid-tag deadbeef >/dev/null 2>&1; then
  printf '%s\n' 'Invalid release publication input was accepted.' >&2
  exit 1
fi
# Fake Git and GitHub CLI processes keep access failures entirely offline and
# prove that publication cannot reach a fetch or release operation without access.
python3 - "$repo_root" "$temporary" <<'PYTEST'
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
fixtures = Path(sys.argv[2]) / "access"
fixtures.mkdir()
calls = fixtures / "calls"
stub = """#!/usr/bin/env python3
import os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['ACCESS_TEST_CALLS'], 'a') as log:
    log.write(name + ' ' + ' '.join(args) + '\\n')
if name == 'git':
    if args not in (['remote', 'get-url', 'origin'], ['remote', 'get-url', '--push', 'origin']):
        sys.exit(90)
    remote = 'https://github.com/wovenmatter/wovenmatter.git' if os.environ['ACCESS_TEST_MODE'] == 'remote-mismatch' else 'git@github-release-agent:wovenmatter/wovenmatter.git'
    print(remote)
else:
    if args != ['api', '--hostname', 'github.com', 'user', '--jq', '.login']:
        sys.exit(91)
    if os.environ.get('GH_PROMPT_DISABLED') != '1' or os.environ.get('GH_BROWSER') != '/usr/bin/false':
        sys.exit(92)
    mode = os.environ['ACCESS_TEST_MODE']
    if mode in ('unavailable', 'auth-required'):
        print('Existing credential or network inaccessible', file=sys.stderr)
        sys.exit(4 if mode == 'auth-required' else 1)
    print('other-account' if mode == 'wrong-account' else 'release-agent')
"""
for name in ("git", "gh"):
    path = fixtures / name
    path.write_text(stub)
    path.chmod(0o755)

for mode, expected in (("ok", 0), ("unavailable", 77), ("auth-required", 77),
                       ("wrong-account", 77), ("remote-mismatch", 65)):
    commands = [[str(root / "scripts/check-release-access.sh")]]
    if expected:
        commands.append([str(root / "scripts/publish-release.sh"), "v1.2.3", "a" * 40])
    for command in commands:
        calls.write_text("")
        env = dict(os.environ, PATH=str(fixtures) + os.pathsep + os.environ["PATH"],
                   ACCESS_TEST_CALLS=str(calls), ACCESS_TEST_MODE=mode,
                   GH_PROMPT_DISABLED="", GH_BROWSER="must-not-launch",
                   GH_HOST="unrelated.example")
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        assert result.returncode == expected, (mode, command, result)
        recorded = calls.read_text().splitlines()
        assert recorded[:2] == ["git remote get-url origin", "git remote get-url --push origin"], recorded
        expected_tail = [] if mode == "remote-mismatch" else ["gh api --hostname github.com user --jq .login"]
        assert recorded[2:] == expected_tail, recorded
print("Release access checks passed: existing access, unavailable credentials/network, auth required, wrong account, wrong remote.")
PYTEST
printf '%s\n' 'Release contract validation passed.'
