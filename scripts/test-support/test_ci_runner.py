"""Exercise portable CI routing and failure propagation without native tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SUITES = ('release_approval', 'release_notarization',
          'release_cache', 'tagged_release_reuse',
          'release_code', 'release_metadata', 'update_request', 'update_refresh',
          'ios_runner', 'dev_build', 'executor_deployment', 'remote_image', 'cua_runtime')


class CIRunnerTests(unittest.TestCase):
    def run_fixture(self, paths, fail=False, fail_host=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / 'scripts'
            support = scripts / 'test-support'
            support.mkdir(parents=True)
            for name in ('test-ci.sh', 'ci-scopes.py'):
                shutil.copy2(ROOT / 'scripts' / name, scripts / name)
            # The classifier itself is tested separately; keep this fixture small.
            (support / 'test_ci_scopes.py').write_text('')
            (support / 'test_ci_runner.py').write_text('')
            for suite in SUITES:
                (support / f'test_{suite}.py').write_text('')
            for name in ('scan-public-tree.sh', 'test-release.sh',
                         'test-dev-signing.sh', 'test-remote-workspace.sh',
                         'test-remote-host.sh'):
                script = scripts / name
                recorded = name in ('test-remote-workspace.sh', 'test-remote-host.sh')
                log = f"printf '%s\\n' '{json.dumps([name])}' >> \"$CI_FIXTURE_CALLS\"\n" if recorded else ''
                reject = 'if [ "${CI_FIXTURE_HOST_FAIL:-0}" = 1 ]; then exit 43; fi\n' if name == 'test-remote-host.sh' else ''
                script.write_text('#!/bin/sh\n' + log + reject + 'exit 0\n')
                script.chmod(0o755)
            (root / 'harnesses').mkdir()
            (root / 'harnesses/catalog.json').write_text(json.dumps({
                'schemaVersion': 4, 'harnesses': [1, 2, 3, 4]}))
            binaries = root / 'bin'
            binaries.mkdir()
            for name in ('npm', 'node', 'swift', 'xcodebuild', 'docker'):
                stub = binaries / name
                stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ['CI_FIXTURE_CALLS'], 'a') as log:
    log.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + '\\n')
if Path(sys.argv[0]).name in ('swift', 'xcodebuild', 'docker'):
    sys.exit(99)
if os.environ.get('CI_FIXTURE_FAIL') == '1' and sys.argv[1:] == ['test', '--prefix', 'remote']:
    sys.exit(42)
''')
                stub.chmod(0o755)
            # A real index also exercises the runner's NUL-delimited syntax scan.
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            changed = root / 'changed paths'
            changed.write_text('\n'.join(paths) + '\n')
            calls = root / 'calls.jsonl'
            result = subprocess.run(['bash', str(scripts / 'test-ci.sh'), '--files', str(changed)],
                env=dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                         CI_FIXTURE_CALLS=str(calls), CI_FIXTURE_FAIL='1' if fail else '0',
                         CI_FIXTURE_HOST_FAIL='1' if fail_host else '0'),
                capture_output=True, text=True, timeout=30)
            recorded = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            self.assertFalse(any(call[0] in ('swift', 'xcodebuild', 'docker') for call in recorded))
            return result, recorded

    def test_documentation_needs_no_node_install_or_native_tools(self):
        result, calls = self.run_fixture(['README.md'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_native_and_mobile_source_do_not_start_platform_validation(self):
        result, calls = self.run_fixture(['app/Sources/WovenMatterCore/Workspace.swift',
            'ios/App/Views/ConversationView.swift', 'integration/Tests/ClientTests.swift'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_image_recipe_runs_portable_tests_without_building_images(self):
        result, calls = self.run_fixture(['remote/Dockerfile'])
        self.assertEqual(result.returncode, 0, result.stderr)
        npm = [call[1:] for call in calls if call[0] == 'npm']
        self.assertEqual([call for call in npm if call[0] == 'test'], [['test', '--prefix', 'remote']])

    def test_remote_source_runs_service_tests_once(self):
        result, calls = self.run_fixture(['remote/src/server.mjs'])
        self.assertEqual(result.returncode, 0, result.stderr)
        npm = [call[1:] for call in calls if call[0] == 'npm']
        self.assertEqual(sum(call[0] == 'ci' for call in npm), 1)
        self.assertEqual([call for call in npm if call[0] == 'test'], [['test', '--prefix', 'remote']])

    def test_agent_runs_each_suite_once_with_one_install(self):
        result, calls = self.run_fixture(['default-agent/src/runtime.mjs'])
        self.assertEqual(result.returncode, 0, result.stderr)
        npm = [call[1:] for call in calls if call[0] == 'npm']
        self.assertEqual(sum(call[0] == 'ci' for call in npm), 1)
        self.assertEqual([call for call in npm if call[0] == 'test'], [
            ['test', '--prefix', 'default-agent'], ['test', '--prefix', 'remote']])
        self.assertIn(['node', 'scripts/build-ios-pi-runtime.mjs', '--check'], calls)

    def test_service_failure_cannot_pass_ci(self):
        result, _ = self.run_fixture(['remote/src/server.mjs'], fail=True)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertNotIn('Portable CI passed.', result.stdout)

    def test_native_host_change_runs_portable_workspace_fixtures_once(self):
        result, calls = self.run_fixture(['scripts/remote-host.sh'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [['test-remote-workspace.sh'], ['test-remote-host.sh']])

    def test_native_host_fixture_failure_cannot_pass_ci(self):
        result, calls = self.run_fixture(['scripts/remote-host.sh'], fail_host=True)
        self.assertEqual(result.returncode, 43, result.stderr)
        self.assertEqual(calls, [['test-remote-workspace.sh'], ['test-remote-host.sh']])
        self.assertNotIn('Portable CI passed.', result.stdout)


if __name__ == '__main__':
    unittest.main()
