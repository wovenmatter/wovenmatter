"""Source override packaging and maintenance with offline pnpm/Git fixtures."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NODE = shutil.which('node')
PACKAGE = '''import hashlib, io, json, os, pathlib, subprocess, sys, tarfile
root = pathlib.Path.cwd()
commit = os.environ.get('PI_BOT_PACKAGE_COMMIT') or subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
lock = (root/'pnpm-lock.yaml').read_bytes()
manifest = dict(commit=commit, protocol=1, version='0.1.0', lockSha256=hashlib.sha256(lock).hexdigest())
with tarfile.open(sys.argv[2], 'w:gz') as output:
    for name, value in [('manifest.json', json.dumps(manifest).encode()), ('source.txt', (root/'source.txt').read_bytes())]:
        info = tarfile.TarInfo(name); info.size = len(value); output.addfile(info, io.BytesIO(value))
with open(os.environ['PIBOT_PREPARE_CALLS'], 'a') as log: log.write('package\\n')
'''


class PrepareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.repo = self.base/'woven'
        for directory in ('scripts', 'pi-bot/tooling', 'tmp', 'bin', 'source'):
            (self.repo/directory).mkdir(parents=True)
        for name in ('prepare-pi-bot.sh', 'pi-bot-host.sh', 'pi-bot-relay.mjs', 'update-pi-bot.sh'):
            shutil.copy2(ROOT/'scripts'/name, self.repo/'scripts'/name)
        shutil.copy2(ROOT/'pi-bot/selection.json', self.repo/'pi-bot/selection.json')
        for name in ('package.json', 'package-lock.json'):
            shutil.copy2(ROOT/'pi-bot/tooling'/name, self.repo/'pi-bot/tooling'/name)
        selection = json.loads((ROOT/'pi-bot/selection.json').read_text())
        arch = 'arm64' if os.uname().machine in ('arm64', 'aarch64') else 'x64'
        system = '' if os.uname().sysname == 'Darwin' else '-linux'
        cache = self.repo/'tmp'/f'wovenmatter-node-{selection["node"]["version"]}-{arch}{system}'/'bin'
        cache.mkdir(parents=True)
        (cache/'node').symlink_to(NODE)
        npm = self.repo/'bin/npm'
        npm.write_text('''#!/usr/bin/env python3
import os, pathlib
bin = pathlib.Path('node_modules/.bin'); bin.mkdir(parents=True)
(bin/'pnpm').symlink_to(pathlib.Path(os.environ['PIBOT_PREPARE_BIN'])/'pnpm')
''')
        npm.chmod(0o755)
        pnpm = self.repo/'bin/pnpm'
        pnpm.write_text('''#!/usr/bin/env bash
set -eu
case "$1" in
 install) printf 'install\\n' >> "$PIBOT_PREPARE_CALLS" ;;
 package:woven) shift; exec python3 package.py "$@" ;;
 *) exit 99 ;;
esac
''')
        pnpm.chmod(0o755)
        self.source = self.repo/'source'
        (self.source/'package.json').write_text('{"scripts":{"package:woven":"python3 package.py"}}')
        (self.source/'pnpm-lock.yaml').write_text('lockfileVersion: 9\n')
        (self.source/'package.py').write_text(PACKAGE)
        (self.source/'source.txt').write_text('first')
        subprocess.run(['git', 'init', '-q', str(self.source)], check=True)
        subprocess.run(['git', '-C', str(self.source), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.source), '-c', 'user.name=Fixture', '-c',
                        'user.email=fixture@example.invalid', 'commit', '-qm', 'Fixture'], check=True)
        self.env = dict(os.environ, WOVENMATTER_PI_BOT_SOURCE=str(self.source),
            TMPDIR=str(self.repo/'tmp'), PIBOT_PREPARE_CALLS=str(self.repo/'calls'),
            PIBOT_PREPARE_BIN=str(self.repo/'bin'), CONFIGURATION='Debug',
            PATH=str(self.repo/'bin')+os.pathsep+os.environ['PATH'])

    def tearDown(self):
        self.temp.cleanup()

    def prepare(self, success=True, **env):
        result = subprocess.run(['bash', str(self.repo/'scripts/prepare-pi-bot.sh'), str(self.repo/'output')],
            env={**self.env, **env}, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def test_dirty_and_untracked_source_invalidate_bundle_cache(self):
        self.prepare()
        output = self.repo/'output'
        first = (output/'pi-bot-bundle.tar.gz').read_bytes()
        self.prepare()
        self.assertEqual((self.repo/'calls').read_text(), 'install\npackage\n')
        (self.source/'source.txt').write_text('dirty')
        self.prepare()
        self.assertNotEqual(first, (output/'pi-bot-bundle.tar.gz').read_bytes())
        (self.source/'untracked.txt').write_text('new source')
        self.prepare()
        self.assertEqual((self.repo/'calls').read_text().count('package\n'), 3)
        self.assertFalse((self.source/'node_modules').exists())
        self.assertTrue((output/'pi-bot-host.sh').exists())
        self.assertTrue((output/'pi-bot-relay.mjs').exists())
        # Uncommitted source names its content: HEAD would look already installed.
        head = subprocess.check_output(['git', '-C', str(self.source), 'rev-parse', 'HEAD'], text=True).strip()
        dirty = json.loads((output/'selection.json').read_text())['commit']
        self.assertNotEqual(dirty, head)
        self.assertRegex(dirty, r'^[a-f0-9]{40}$')
        with tarfile.open(output/'pi-bot-bundle.tar.gz') as bundle:
            self.assertEqual(json.load(bundle.extractfile('manifest.json'))['commit'], dirty)
        (self.source/'untracked.txt').unlink()
        subprocess.run(['git', '-C', str(self.source), 'checkout', '--', '.'], check=True)
        self.prepare()
        self.assertEqual(json.loads((output/'selection.json').read_text())['commit'], head)
        self.assertTrue((output/'tooling/package-lock.json').exists())

    def test_release_refuses_override_and_missing_packager_fails_clearly(self):
        self.assertIn('forbidden in Release', self.prepare(False, CONFIGURATION='Release').stderr)
        (self.source/'package.json').write_text('{}')
        self.assertIn('has no package:woven script', self.prepare(False).stderr)
        self.assertFalse((self.repo/'output').exists())

    def test_xcode_resource_phase_preserves_opaque_bundle(self):
        import gzip
        import re
        project = (ROOT/'app/WovenMatter.xcodeproj/project.pbxproj').read_text()
        encoded = re.search(r'shellScript = ("set -eu.*?prepare-default-agent.*?");', project)[1]
        phase = json.loads(encoded)
        self.assertLess(phase.index('prepare-default-agent.sh'), phase.index('prepare-pi-bot.sh'))
        self.assertLess(phase.index('prepare-pi-bot.sh'), phase.index('/usr/bin/xattr -cr'))
        if os.uname().sysname != 'Darwin':
            return
        payload = gzip.compress(b'opaque source resource')
        (self.repo/'fixture.tar.gz').write_bytes(payload)
        for name in ('prepare-default-agent.sh', 'prepare-cua.sh'):
            file = self.repo/'scripts'/name
            file.write_text('#!/bin/sh\nmkdir -p "$1"\n')
            file.chmod(0o755)
        file = self.repo/'scripts/prepare-pi-bot.sh'
        file.write_text('#!/bin/sh\nmkdir -p "$1"\ncp "$PIBOT_PHASE_TAR" "$1/pi-bot-bundle.tar.gz"\n')
        file.chmod(0o755)
        file = self.repo/'scripts/build-power-helper.sh'
        file.write_text('#!/bin/sh\nmkdir -p "$1/Contents/Resources/remote/test" "$1/Contents/Resources/remote/node_modules"\n')
        file.chmod(0o755)
        (self.repo/'app').mkdir()
        (self.repo/'derived').mkdir()
        result = subprocess.run(['/bin/sh', '-c', phase], capture_output=True, text=True,
            env=dict(self.env, SRCROOT=str(self.repo/'app'), TARGET_BUILD_DIR=str(self.repo/'products'),
                     UNLOCALIZED_RESOURCES_FOLDER_PATH='Fixture.app/Contents/Resources',
                     WRAPPER_NAME='Fixture.app', DERIVED_FILE_DIR=str(self.repo/'derived'),
                     PIBOT_PHASE_TAR=str(self.repo/'fixture.tar.gz')), timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        resource = self.repo/'products/Fixture.app/Contents/Resources/pi-bot/pi-bot-bundle.tar.gz'
        self.assertEqual(resource.read_bytes(), payload)
        self.assertTrue((self.repo/'derived/bundle-metadata-cleaned.stamp').exists())

    def test_refresh_records_only_exact_main_commit_using_configured_ssh_remote(self):
        git = self.repo/'bin/git'
        git.write_text('''#!/usr/bin/env bash
set -eu
case "$*" in
 *'remote get-url origin') printf 'git@github-fixture:wovenmatter/wovenmatter.git\\n' ;;
 'ls-remote git@github-fixture:wovenmatter/pi-bot.git refs/heads/main') printf '%040d\\trefs/heads/main\\n' 1 ;;
 *) exit 98 ;;
esac
''')
        git.chmod(0o755)
        before = json.loads((self.repo/'pi-bot/selection.json').read_text())
        result = subprocess.run(['bash', str(self.repo/'scripts/update-pi-bot.sh')], env=self.env,
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        after = json.loads((self.repo/'pi-bot/selection.json').read_text())
        self.assertEqual(after.pop('commit'), '0'*39+'1')
        before.pop('commit')
        self.assertEqual(after, before)


if __name__ == '__main__':
    unittest.main()
