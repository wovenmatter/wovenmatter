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
    def fixture(self, root, existing=False, conflicting_route=False, foreign=False, old_version=False, readiness_failure=False, previous=False, rename_failure=False):
        commands = root / 'commands'
        commands.mkdir()
        log = root / 'commands.log'
        docker = commands / 'docker'
        state = root / 'docker.json'
        containers = {}
        if existing: containers['wovenmatter-executor'] = 'wovenmatter/executor:' + ('2.0.0-beta.7' if old_version else '2.0.0-beta.12')
        if previous: containers['wovenmatter-executor-previous'] = 'wovenmatter/executor:2.0.0-beta.6'
        state.write_text(json.dumps(containers))
        docker.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args=sys.argv[1:]; path=pathlib.Path(os.environ['WM_FIXTURE_STATE']); state=json.loads(path.read_text())
with open(os.environ['WM_FIXTURE_LOG'], 'a') as out: out.write(json.dumps(['docker']+args)+'\\n')
if args[0]=='inspect':
    name=args[-1]
    if name not in state: sys.exit(1)
    if '--format' in args:
        print(state[name] if '.Config.Image' in args[2] else 'foreign' if os.environ.get('WM_FIXTURE_FOREIGN') else 'managed-v1')
elif args[0]=='rename':
    if os.environ.get('WM_FIXTURE_RENAME_FAIL') and args[1]=='wovenmatter-executor': sys.exit(1)
    state[args[2]]=state.pop(args[1])
elif args[0]=='rm': state.pop(args[-1], None)
elif args[0]=='run': state['wovenmatter-executor']=args[-1]
path.write_text(json.dumps(state))
''')
        (commands / 'sudo').write_text('#!/bin/sh\nexit 1\n')
        (commands / 'sudo').chmod(0o755)
        # Stub only HTTP readiness, while production validation and rollback run.
        (root / 'sitecustomize.py').write_text('''import json, os, time, urllib.request
class Ready:
    status=200
    def __enter__(self): return self
    def __exit__(self, *args): pass
def ready(request, timeout):
    assert request.full_url in ('http://127.0.0.1:4312/v1/apps', 'https://fixture.tailnet.ts.net:8443/v1/apps')
    assert request.get_header('Authorization')=='Bearer '+'a'*64
    with open(os.environ['WM_FIXTURE_LOG'], 'a') as out: out.write(json.dumps(['readiness'])+'\\n')
    if os.environ.get('WM_FIXTURE_READY_FAIL'): raise OSError('fixture readiness failure')
    return Ready()
urllib.request.urlopen=ready
if os.environ.get('WM_FIXTURE_READY_FAIL'):
    tick=[0]
    def now(): tick[0]+=100; return tick[0]
    time.monotonic=now
    time.sleep=lambda _: None
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
        payload.write_text(json.dumps({'origin': 'https://fixture.tailnet.ts.net:8443', 'apiKey': 'a'*64, 'encryptionKey': 'b'*64, 'version': '2.0.0-beta.12', 'dockerfile': DOCKERFILE}))
        env = {**os.environ, 'PATH': str(commands)+':/usr/bin:/bin', 'WM_FIXTURE_LOG': str(log), 'WM_FIXTURE_STATE': str(state), 'PYTHONPATH': str(root)}
        for flag, value in [('WM_FIXTURE_EXISTING', existing), ('WM_FIXTURE_CONFLICT', conflicting_route), ('WM_FIXTURE_FOREIGN', foreign), ('WM_FIXTURE_READY_FAIL', readiness_failure), ('WM_FIXTURE_RENAME_FAIL', rename_failure)]:
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

    def test_update_replaces_owned_runtime_only_after_build_and_readiness(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result, log = self.fixture(root, existing=True, old_version=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            build = next(i for i, c in enumerate(calls) if c[:2] == ['docker', 'build'])
            stop = calls.index(['docker', 'stop', 'wovenmatter-executor'])
            ready = calls.index(['readiness'])
            remove = calls.index(['docker', 'rm', 'wovenmatter-executor-previous'])
            self.assertLess(build, stop)
            self.assertLess(ready, remove)
            self.assertEqual(json.loads((root/'docker.json').read_text()), {'wovenmatter-executor': 'wovenmatter/executor:2.0.0-beta.12'})

    def test_failed_readiness_restores_previous_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result, log = self.fixture(root, existing=True, old_version=True, readiness_failure=True)
            self.assertNotEqual(result.returncode, 0)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertIn(['docker', 'rename', 'wovenmatter-executor-previous', 'wovenmatter-executor'], calls)
            self.assertEqual(json.loads((root/'docker.json').read_text()), {'wovenmatter-executor': 'wovenmatter/executor:2.0.0-beta.7'})

    def test_failed_rename_restarts_current_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, log = self.fixture(Path(temporary), existing=True, old_version=True, rename_failure=True)
            self.assertNotEqual(result.returncode, 0)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertIn(['docker', 'stop', 'wovenmatter-executor'], calls)
            self.assertIn(['docker', 'start', 'wovenmatter-executor'], calls)
            self.assertFalse(any(call[:2] == ['docker', 'run'] for call in calls))

    def test_previous_container_collision_keeps_active_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, log = self.fixture(Path(temporary), existing=True, old_version=True, previous=True)
            self.assertNotEqual(result.returncode, 0)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertNotIn(['docker', 'stop', 'wovenmatter-executor'], calls)

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
