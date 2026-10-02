"""Exercise the real deployment script with deterministic Docker/Tailscale commands.
No Docker daemon, SSH, accounts, or network services are used on the test machine.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / 'remote/executor-deploy.sh').read_text()
DOCKERFILE = (ROOT / 'remote/Executor.Dockerfile').read_text()

class ExecutorDeploymentTests(unittest.TestCase):
    def fixture(self, root, existing=False, conflicting_route=False, foreign=False):
        commands = root / 'commands'
        commands.mkdir()
        log = root / 'commands.log'
        docker = commands / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['WM_FIXTURE_LOG'], 'a') as out: out.write(json.dumps(['docker']+sys.argv[1:])+'\\n')
if sys.argv[1]=='inspect':
    if not os.environ.get('WM_FIXTURE_EXISTING'): sys.exit(1)
    if '--format' in sys.argv: print('foreign' if os.environ.get('WM_FIXTURE_FOREIGN') else 'managed-v1')
''')
        tailscale = commands / 'tailscale'
        tailscale.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['WM_FIXTURE_LOG'], 'a') as out: out.write(json.dumps(['tailscale']+sys.argv[1:])+'\\n')
if sys.argv[1:]==['status','--json']: print(json.dumps({'Self':{'DNSName':'fixture.tailnet.ts.net.'}}))
elif sys.argv[1:]==['serve','status','--json']:
    print(json.dumps({'TCP':{'8443':{'TCPForward':'127.0.0.1:9999'}}} if os.environ.get('WM_FIXTURE_CONFLICT') else {}))
''')
        docker.chmod(0o755)
        tailscale.chmod(0o755)
        payload = root / 'setup.json'
        payload.write_text(json.dumps({'origin': 'https://fixture.tailnet.ts.net:8443', 'apiKey': 'a'*64, 'encryptionKey': 'b'*64, 'dockerfile': DOCKERFILE}))
        env = {**os.environ, 'PATH': str(commands)+':/usr/bin:/bin', 'WM_FIXTURE_LOG': str(log)}
        for flag, value in [('WM_FIXTURE_EXISTING', existing), ('WM_FIXTURE_CONFLICT', conflicting_route), ('WM_FIXTURE_FOREIGN', foreign)]:
            if value: env[flag] = '1'
        # Replace only the home directory anchor; every deployment command and
        # credential/route/ownership check runs from the production source.
        adapted = SCRIPT.replace('wm_root="$HOME/.local/share/wovenmatter-executor"', 'wm_root="'+str(root / 'runtime')+'"')
        completed = subprocess.run(['bash', '-c', 'wm_payload="'+str(payload)+'"\n'+adapted], env=env, capture_output=True)
        return completed, log

    def test_standalone_container_has_persistent_data_and_private_https(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result, log = self.fixture(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            run = next(call for call in calls if call[:2] == ['docker', 'run'])
            self.assertIn('--network', run)
            self.assertIn('host', run)
            self.assertIn('--restart', run)
            self.assertIn('--env-file', run)
            self.assertIn('--mount', run)
            self.assertFalse(any('funnel' in call for call in calls))
            env = root / 'runtime/runtime.env'
            self.assertEqual(env.stat().st_mode & 0o777, 0o600)
            self.assertIn('EXECUTOR_BROWSER_ORIGIN=https://fixture.tailnet.ts.net:8443', env.read_text())
            self.assertNotIn('a'*64, result.stdout.decode()+result.stderr.decode()+log.read_text())
            self.assertEqual((root / 'runtime/Dockerfile').read_text(), DOCKERFILE)
            self.assertEqual((root / 'runtime/.dockerignore').read_text(), '*\n!Dockerfile\n')

    def test_retry_restarts_only_owned_container(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, log = self.fixture(Path(temporary), existing=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertIn(['docker', 'start', 'wovenmatter-executor'], calls)
            self.assertFalse(any(call[:2] == ['docker', 'run'] for call in calls))

    def test_foreign_container_or_private_route_is_preserved(self):
        for options in [{'existing': True, 'foreign': True}, {'conflicting_route': True}]:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as temporary:
                result, log = self.fixture(Path(temporary), **options)
                self.assertNotEqual(result.returncode, 0)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertFalse(any(call[:2] in (['docker', 'run'], ['docker', 'start']) for call in calls))
                self.assertFalse(any(call[:2] == ['tailscale', 'serve'] and '--bg' in call for call in calls))

if __name__ == '__main__':
    unittest.main()
