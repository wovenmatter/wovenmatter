"""The owned runners admit only collaborator jobs and keep release caches apart."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / '.github/workflows'
OWNED = re.compile(r'runs-on: \[self-hosted, (wovenmatter-macos|wovenmatter-linux)\]')


def jobs(workflow):
    text = (WORKFLOWS / workflow).read_text()
    for job in re.split(r'\n(?=  [\w-]+:\n)', text.split('\njobs:\n', 1)[-1]):
        if re.match(r'  [\w-]+:\n', job):  # not the comments before the first job
            yield job.split(':', 1)[0].strip(), job


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        self.hooks = self.directory / 'hooks'
        self.hooks.mkdir()
        shutil.copy2(ROOT / 'scripts/ci-runner/runner-guard.sh', self.hooks / 'runner-guard.sh')
        self.bin = self.directory / 'bin'
        self.bin.mkdir()
        self.calls = self.directory / 'security.log'
        self.keychains = self.directory / 'keychains'
        self.keychains.write_text('    "/home/runner-user/Library/Keychains/login.keychain-db"\n')
        self.stub('uname', 'echo "${FAKE_UNAME:-Linux}"')
        self.stub('security', f'''echo "$*" >> "{self.calls}"
if [ "$1" = list-keychains ] && [ "$#" -eq 3 ]; then cat "{self.keychains}"; fi''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f'#!/bin/sh\n{body}\n')
        path.chmod(0o755)

    def guard(self, phase='started', event='workflow_dispatch', workflow='validation.yml',
              repository='wovenmatter/wovenmatter', **extra):
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GITHUB_')}
        environment.update(PATH=f'{self.bin}:{environment["PATH"]}', GITHUB_EVENT_NAME=event,
                           GITHUB_REPOSITORY=repository, GITHUB_REF='refs/heads/topic',
                           GITHUB_WORKFLOW_REF=f'{repository}/.github/workflows/{workflow}@refs/heads/topic')
        environment.update(extra)
        return subprocess.run(['bash', str(self.hooks / 'runner-guard.sh'), phase], env=environment,
                              capture_output=True, text=True, timeout=30)

    def test_collaborator_dispatches_and_pushes_of_allowed_workflows_run(self):
        self.assertEqual(self.guard().returncode, 0)
        self.assertEqual(self.guard(event='push', workflow='release.yml').returncode, 0)

    def test_fork_reachable_and_unattended_events_are_refused(self):
        for event in ('pull_request', 'pull_request_target', 'issue_comment', 'schedule',
                      'workflow_run', 'merge_group', ''):
            result = self.guard(event=event)
            self.assertNotEqual(result.returncode, 0, event)
            self.assertIn('refuses the job', result.stderr)

    def test_other_workflows_and_repositories_are_refused(self):
        self.assertNotEqual(self.guard(workflow='ci.yml').returncode, 0)
        self.assertNotEqual(self.guard(workflow='new-workflow.yml').returncode, 0)
        self.assertNotEqual(self.guard(repository='someone/fork').returncode, 0)
        self.assertNotEqual(self.guard(GITHUB_WORKFLOW_REF='').returncode, 0)
        # A same-named file from another repository is not this repository's workflow.
        self.assertNotEqual(self.guard(
            GITHUB_WORKFLOW_REF='someone/fork/.github/workflows/validation.yml@refs/heads/x').returncode, 0)

    def test_a_workflow_environment_cannot_widen_the_allowlist(self):
        result = self.guard(workflow='ci.yml', WOVENMATTER_RUNNER_WORKFLOWS='.github/workflows/ci.yml',
                            WOVENMATTER_RUNNER_REPOSITORY='someone/fork')
        self.assertNotEqual(result.returncode, 0)

    def test_the_installed_allowlist_file_narrows_the_workflows(self):
        (self.hooks / 'allowed-workflows').write_text('.github/workflows/release.yml\n')
        self.assertNotEqual(self.guard().returncode, 0)
        self.assertEqual(self.guard(event='push', workflow='release.yml').returncode, 0)

    def test_completed_jobs_never_fail(self):
        self.assertEqual(self.guard('completed', event='pull_request').returncode, 0)
        self.assertNotEqual(self.guard('unknown').returncode, 0)

    def test_linux_never_touches_keychains(self):
        self.guard()
        self.assertFalse(self.calls.exists())

    def test_mac_leaves_the_users_keychains_alone(self):
        self.assertEqual(self.guard(FAKE_UNAME='Darwin').returncode, 0)
        self.assertEqual(self.calls.read_text(), 'list-keychains -d user\n')

    def test_mac_removes_only_a_stale_release_keychain(self):
        stale = '/home/runner-user/actions-runner/wovenmatter/_work/_temp/wovenmatter-release.keychain-db'
        self.keychains.write_text(f'    "{stale}"\n    "/home/runner-user/Library/Keychains/login.keychain-db"\n'
                                  '    "/home/runner-user/Library/Keychains/Other Things.keychain-db"\n')
        self.assertEqual(self.guard('completed', FAKE_UNAME='Darwin').returncode, 0)
        self.assertEqual(self.calls.read_text().splitlines(), [
            'list-keychains -d user', f'delete-keychain {stale}',
            'list-keychains -d user -s /home/runner-user/Library/Keychains/login.keychain-db '
            '/home/runner-user/Library/Keychains/Other Things.keychain-db'])


class CacheTests(unittest.TestCase):
    def cache_env(self, purpose, home, **extra):
        environment = dict(os.environ, HOME=str(home), **extra)
        environment.pop('XDG_CACHE_HOME', None)
        result = subprocess.run(['bash', str(ROOT / 'scripts/ci-runner/cache-env.sh'), purpose],
                                env=environment, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split('=', 1) for line in result.stdout.splitlines())

    def test_release_and_validation_caches_are_apart_from_each_other_and_dev_builds(self):
        with tempfile.TemporaryDirectory() as home:
            validation = self.cache_env('validation', home)
            release = self.cache_env('release', home)
            self.assertEqual(validation.keys(), release.keys())
            dev = (Path(home) / 'Library/Caches/WovenMatter', Path('/private/tmp'))
            for key in validation:
                self.assertNotEqual(validation[key], release[key], key)
                for value in (validation[key], release[key]):
                    self.assertTrue(value.startswith(home), (key, value))
                    self.assertFalse(any(Path(value).is_relative_to(path) for path in dev), (key, value))
                    self.assertTrue(Path(value).is_relative_to(release['WOVENMATTER_CI_CACHE_ROOT'])
                                    or Path(value).is_relative_to(validation['WOVENMATTER_CI_CACHE_ROOT']))

    def test_an_oversized_compiler_cache_starts_over(self):
        with tempfile.TemporaryDirectory() as home:
            compiler = Path(self.cache_env('release', home)['WOVENMATTER_COMPILER_CACHE'])
            compiler.mkdir(parents=True)
            (compiler / 'object').write_bytes(b'x' * 4096)
            self.cache_env('release', home)
            self.assertTrue(compiler.exists())
            self.cache_env('release', home, WOVENMATTER_COMPILER_CACHE_LIMIT_MB='0')
            self.assertFalse(compiler.exists())

    def test_unknown_purposes_are_refused(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/ci-runner/cache-env.sh'), 'dev'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 64)


class WorkflowTests(unittest.TestCase):
    def test_only_guarded_workflows_target_the_owned_runners(self):
        guard = (ROOT / 'scripts/ci-runner/runner-guard.sh').read_text()
        allowed = set(re.search(r"^workflows='([^']+)'", guard, re.MULTILINE).group(1).split())
        for workflow in WORKFLOWS.glob('*.yml'):
            text = workflow.read_text()
            if 'self-hosted' in text:
                self.assertIn(f'.github/workflows/{workflow.name}', allowed, workflow.name)
            # Fork-triggerable workflows stay on GitHub's runners.
            if re.search(r'^  (pull_request|pull_request_target|issue_comment):', text, re.MULTILINE):
                self.assertNotIn('self-hosted', text, workflow.name)

    def test_validation_and_release_run_on_owned_runners_with_their_own_caches(self):
        hosted = {('validation.yml', 'remote')}  # arm64 images need arm64 Linux hardware
        for workflow, purpose in (('validation.yml', 'validation'), ('release.yml', 'release')):
            for name, job in jobs(workflow):
                if (workflow, name) in hosted:
                    self.assertNotIn('self-hosted', job)
                    continue
                self.assertRegex(job, OWNED, (workflow, name))
                self.assertNotIn('actions/cache', job, (workflow, name))
                if name != 'preflight':
                    self.assertIn(f'scripts/ci-runner/cache-env.sh {purpose} >> "$GITHUB_ENV"', job,
                                  (workflow, name))
                other = 'release' if purpose == 'validation' else 'validation'
                self.assertNotIn(f'cache-env.sh {other}', job, (workflow, name))

    def test_release_signing_keeps_the_users_keychains(self):
        text = (WORKFLOWS / 'release.yml').read_text()
        self.assertNotIn('security list-keychains -d user -s "$keychain"\n', text)
        self.assertIn('security list-keychains -d user -s "$keychain" ${existing[@]+"${existing[@]}"}', text)
        self.assertIn("grep -c 'Developer ID Application:'", text)
        self.assertIn('security delete-keychain "$keychain"', text)

    def test_rehearsals_publish_nothing(self):
        text = (WORKFLOWS / 'release.yml').read_text()
        publish = text.split("- name: Verify private draft and deliver authorized update refresh", 1)[1]
        self.assertLess(publish.index('if [ "$REHEARSAL" = true ]'), publish.index('gh release create'))
        self.assertIn('^refs/tags/v-rehearsal-', text)


if __name__ == '__main__':
    unittest.main()
