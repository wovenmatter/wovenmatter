"""Hermetic device installation, using only temporary data and fake external tools."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
NODE = shutil.which('node')
STUB = r'''#!/usr/bin/env python3
import json, os, re, shutil, signal, sys, time
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
base = Path(os.environ['PIBOT_TEST_BASE'])
with (base/'calls').open('a') as log: log.write(json.dumps([name, *args])+'\n')
def port(config): return re.search(r'^port = (\d+)', config.read_text(), re.M)[1]
def mark(p, value): (base/('port-'+p)).write_text(json.dumps(value))
if name == 'uname': print(os.environ.get('PIBOT_TEST_OS', 'Linux') if args == ['-s'] else 'x86_64')
elif name == 'getconf': print('glibc 2.39')
elif name == 'ldd':
    print(os.environ.get('PIBOT_TEST_LIBC', 'glibc'))
    if os.environ.get('PIBOT_TEST_LIBC') == 'musl': sys.exit(1)
elif name == 'loginctl': print(os.environ.get('PIBOT_TEST_LINGER', 'no'))
elif name == 'npm':
    assert args == ['ci', '--no-audit', '--no-fund'], args
    if os.environ.get('PIBOT_TEST_HANG_NPM') == '1':
        (base/'npm-started').write_text(str(os.getpid()))
        time.sleep(60)
    bin = Path('node_modules/.bin'); bin.mkdir(parents=True)
    (bin/'pnpm').symlink_to(base/'bin/pnpm')
    print('fake npm ci')
elif name == 'pnpm':
    if args == ['--version']: print('12.16.1')
    else:
        assert args[:4] == ['install', '--prod', '--frozen-lockfile', '--filter'], args
        assert args[4] == '@wovenmatter/pi-bot...' and args[5] == '--store-dir', args
        Path('node_modules').mkdir()
        print('fake pnpm install')
elif name == 'node':
    if args == ['--version']: print('v26.13.0')
    elif args[0] in ('-', '-e'): os.execv(os.environ['PIBOT_TEST_REAL_NODE'], [os.environ['PIBOT_TEST_REAL_NODE'], *args])
    else:
        assert args[1:3] == ['serve', '--config'], args
        config = Path(args[3]); text = config.read_text()
        assert '[credentials]\nbackend = "encrypted-sqlite"' in text
        assert '[environment]\nbackend = "none"' in text
        assert 'main = "openai/gpt-6-sol"' in text
        assert '.health.' in str(config) and '.health.' in text, text
        with (base/'configs').open('a') as log: log.write(json.dumps(text)+'\n')
        if os.environ.get('PIBOT_TEST_BAD_HEALTH') == '1': sys.exit(23)
        mark(port(config), {'pid':os.getpid(), 'version':'0.1.0', 'protocol':1, 'installationId':'fixture-id'})
        while True: time.sleep(.05)
elif name == 'curl':
    if '-o' in args: shutil.copyfile(base/'node.tar.gz', args[args.index('-o')+1])
    else:
        p = args[-1].split(':')[-1].split('/')[0]
        if p == '4317':
            if os.environ.get('PIBOT_TEST_EXISTING') == '1': print('{"version":"0.2.0","protocol":1,"installationId":"foreign-id"}')
            else: sys.exit(7)
        else:
            file = base/('port-'+p)
            if not file.exists(): sys.exit(7)
            value = json.loads(file.read_text())
            if 'pid' in value:
                try: os.kill(value['pid'], 0)
                except ProcessLookupError: sys.exit(7)
            print(json.dumps(value))
elif name == 'systemctl':
    assert args[0] == '--user' and 'pi-bot.service' not in args
    action = args[1]
    root = Path(os.environ['PIBOT_TEST_ROOT'])
    if action == 'start':
        if os.environ.get('PIBOT_TEST_FAIL_SERVICE') == root.joinpath('current').resolve().name: sys.exit(24)
        mark(port(root/'config.toml'), {'version':'0.1.0'})
    if action == 'stop': (base/('port-'+port(root/'config.toml'))).unlink(missing_ok=True)
elif name == 'launchctl':
    root = Path(os.environ['PIBOT_TEST_ROOT'])
    if args[0] == 'print':
        if '/' in args[1].split('/',1)[-1]: sys.exit(1)
        if args[1].startswith('gui/') and os.environ.get('PIBOT_TEST_NO_GUI') == '1': sys.exit(1)
    elif args[0] == 'bootstrap': mark(port(root/'config.toml'), {'version':'0.1.0'})
    elif args[0] == 'bootout': (base/('port-'+port(root/'config.toml'))).unlink(missing_ok=True)
    else: sys.exit(91)
else: sys.exit(92)
'''


def archive(path, files):
    with tarfile.open(path, 'w:gz') as output:
        for name, content in files.items():
            content = content.encode()
            info = tarfile.TarInfo(name)
            info.mode = 0o755 if name.endswith('/node') else 0o644
            info.size = len(content)
            output.addfile(info, io.BytesIO(content))


class HostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.root = self.base/'managed'
        self.home = self.base/'home'
        self.home.mkdir()
        self.bin = self.base/'bin'
        self.bin.mkdir()
        for name in ('node', 'npm', 'pnpm', 'systemctl', 'launchctl', 'curl', 'uname', 'ldd', 'getconf', 'loginctl'):
            file = self.bin/name
            file.write_text(STUB)
            file.chmod(0o755)
        archive(self.base/'node.tar.gz', {'node-v26.13.0-linux-x64/bin/node':STUB,
            'node-v26.13.0-linux-x64/bin/npm':STUB})
        self.checksum = hashlib.sha256((self.base/'node.tar.gz').read_bytes()).hexdigest()
        self.bundle = self.base/'bundle.tar.gz'
        self.tooling = ROOT/'pi-bot/tooling'
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
            PIBOT_TEST_BASE=str(self.base), PIBOT_TEST_REAL_NODE=NODE, PIBOT_TEST_ROOT=str(self.root))
        self.make_bundle('a'*40)

    def tearDown(self):
        self.temp.cleanup()

    def make_bundle(self, commit):
        lock = 'lockfileVersion: 9\n'
        archive(self.bundle, {'manifest.json':json.dumps({'commit':commit, 'version':'0.1.0',
            'protocol':1, 'lockSha256':hashlib.sha256(lock.encode()).hexdigest()}),
            'package.json':'{"private":true}', 'pnpm-lock.yaml':lock,
            'pnpm-workspace.yaml':'packages: []', 'packages/server/dist/cli.js':'fixture',
            'apps/web/dist/index.html':'fixture'})

    def run_host(self, command, *args, success=True, input=None, **env):
        result = subprocess.run(['bash', str(ROOT/'scripts/pi-bot-host.sh'), command,
            '--instance', 'fixture', '--root', str(self.root), *args], input=input,
            env={**self.env, **env, 'PIBOT_TEST_ROOT':str(self.root)}, capture_output=True, text=input is None or isinstance(input, str), timeout=45)
        if isinstance(result.stdout, bytes):
            result.stdout = result.stdout.decode()
            result.stderr = result.stderr.decode()
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(result.stdout)
            self.assertEqual(value['schema'], 1)
            return value
        self.assertNotEqual(result.returncode, 0, result)
        self.assertEqual(result.stdout, '', result)
        errors = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{"error":')]
        self.assertTrue(errors, result.stderr)
        return errors[0]

    def install(self, commit='a'*40, service=False, success=True, extra=(), bundle=None, tooling=None, input=None, **env):
        return self.run_host('install', '--commit', commit, '--node-version', '26.13.0',
            '--node-sha256', self.checksum, '--pnpm-version', '12.16.1', '--bundle', str(bundle or self.bundle),
            '--tooling-lock-dir', str(tooling or self.tooling), '--service' if service else '--no-service',
            *extra, success=success, input=input, **env)

    def calls(self, name):
        return [call for call in map(json.loads, (self.base/'calls').read_text().splitlines()) if call[0] == name]

    def test_layout_config_permissions_and_caller_supervision(self):
        installed = self.install()
        self.assertEqual(installed['commit'], 'a'*40)
        self.assertEqual(installed['port'], 47310)
        self.assertEqual(os.readlink(self.root/'current'), 'releases/'+'a'*40)
        for directory in ('data', 'node', 'releases', 'pnpm-store'):
            self.assertEqual((self.root/directory).stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root/'config.toml').stat().st_mode & 0o777, 0o600)
        self.assertIn(json.dumps(str(self.root/'current/apps/web/dist')), (self.root/'config.toml').read_text())
        self.assertTrue((self.root/'tooling/node_modules/.bin/pnpm').exists())
        self.assertEqual(self.run_host('start')['supervisor'], 'caller')
        self.assertEqual(self.run_host('stop')['supervisor'], 'caller')
        self.assertEqual(self.calls('systemctl'), [])
        self.assertTrue(all('.health.' in line for line in (self.base/'configs').read_text().splitlines()))

    def test_bundle_and_tooling_stdin_inputs(self):
        self.install(bundle='-', input=self.bundle.read_bytes())
        self.root = self.base/'tooling-stream'
        tooling = self.base/'tooling.tar.gz'
        with tarfile.open(tooling, 'w:gz') as output:
            for name in ('package.json', 'package-lock.json'):
                output.add(self.tooling/name, arcname=name)
        self.install(tooling='-', input=tooling.read_bytes())
        self.assertTrue((self.root/'tooling/package-lock.json').exists())

    def test_checksum_rejected_before_execution(self):
        self.checksum = '0'*64
        self.assertEqual(self.install(success=False)['error'], 'checksum')
        self.assertEqual(self.calls('node'), [])
        self.assertFalse((self.root/'current').exists())

    def test_failed_scratch_health_keeps_current_and_config(self):
        self.install()
        before = (self.root/'config.toml').read_bytes()
        self.make_bundle('b'*40)
        self.assertEqual(self.install('b'*40, success=False, PIBOT_TEST_BAD_HEALTH='1')['error'], 'health')
        self.assertEqual(os.readlink(self.root/'current'), 'releases/'+'a'*40)
        self.assertEqual((self.root/'config.toml').read_bytes(), before)
        self.assertFalse((self.root/'releases'/('b'*40)).exists())

    def test_service_failure_rolls_back_and_restarts_previous_release(self):
        self.install(service=True)
        self.make_bundle('b'*40)
        error = self.install('b'*40, service=True, success=False, PIBOT_TEST_FAIL_SERVICE='b'*40)
        self.assertEqual(error['error'], 'activation')
        self.assertEqual(os.readlink(self.root/'current'), 'releases/'+'a'*40)
        self.assertTrue(self.run_host('status')['running'])
        self.assertEqual({p.name for p in (self.root/'releases').iterdir()}, {'a'*40})
        self.assertEqual(self.calls('systemctl')[-1], ['systemctl', '--user', 'start', 'wovenmatter-pi-bot-fixture.service'])

    def test_port_selection_reuse_config_written_once_and_retention(self):
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 47310)); occupied.listen()
            self.assertEqual(self.install()['port'], 47311)
        config = self.root/'config.toml'
        config.write_text(config.read_text()+'\n# Owned by Pi Bot settings\n')
        before = config.read_bytes()
        for char in ('b', 'c'):
            self.make_bundle(char*40)
            self.assertEqual(self.install(char*40)['port'], 47311)
        self.assertEqual(config.read_bytes(), before)
        self.assertEqual({p.name for p in (self.root/'releases').iterdir()}, {'b'*40, 'c'*40})
        self.assertEqual(self.install('c'*40, extra=('--port', '47444'), success=False)['error'], 'config')

    def test_foreign_roots_instances_and_service_labels_are_protected(self):
        self.root.mkdir(); (self.root/'config.toml').write_text('foreign')
        self.assertEqual(self.install(success=False)['error'], 'foreign_root')
        (self.root/'config.toml').unlink()
        (self.root/'.woven-instance').write_text('other-instance')
        self.assertEqual(self.install(success=False)['error'], 'foreign_root')
        (self.root/'.woven-instance').unlink()
        unit = self.home/'.config/systemd/user/wovenmatter-pi-bot-fixture.service'
        unit.parent.mkdir(parents=True); unit.write_text('foreign service')
        self.assertEqual(self.install(service=True, success=False)['error'], 'foreign_service')
        self.assertEqual(unit.read_text(), 'foreign service')

    def test_inspect_is_read_only_and_reports_foreign_standalone(self):
        # A standalone server on its configured port is found. Unrelated listeners are never probed.
        (self.base/'port-47333').write_text(json.dumps({'version':'0.3.0','protocol':1,'installationId':'other-standalone'}))
        (self.base/'port-47444').write_text(json.dumps({'version':'0.3.0','protocol':1,'installationId':'unrelated'}))
        (self.home/'.config/systemd/user').mkdir(parents=True)
        (self.home/'.config/systemd/user/pi-bot.service').write_text('standalone')
        (self.home/'.config/pi-bot').mkdir(parents=True)
        (self.home/'.config/pi-bot/config.toml').write_text('[server]\nhost = "127.0.0.1"\nport = 47333\n')
        value = self.run_host('inspect', PIBOT_TEST_EXISTING='1')
        self.assertFalse(self.root.exists())
        self.assertEqual(value['serviceManager'], 'systemd')
        self.assertEqual(value['existing'][0]['service'], 'pi-bot.service')
        self.assertEqual(value['existing'][0]['installationId'], 'foreign-id')
        self.assertEqual(value['existing'][1]['port'], 47333)
        self.assertEqual(value['existing'][1]['installationId'], 'other-standalone')
        self.assertEqual(len(value['existing']), 2)
        self.assertFalse(value['lingering'])
        self.assertEqual(self.calls('systemctl'), [])

    def test_config_port_tolerates_a_trailing_comment(self):
        self.install()
        config = self.root/'config.toml'
        config.write_text(config.read_text().replace('port = ', 'port = 47399 # chosen\nignored = ', 1))
        self.assertEqual(self.run_host('inspect')['managed']['port'], 47399)

    def test_cancel_install_stops_a_slow_child_now_and_releases_the_lock(self):
        env = dict(self.env, PIBOT_TEST_HANG_NPM='1')
        command = ['/bin/bash', str(ROOT/'scripts/pi-bot-host.sh'), 'install', '--instance', 'fixture', '--root', str(self.root),
            '--commit', 'a'*40, '--node-version', '26.13.0', '--node-sha256', self.checksum, '--pnpm-version', '12.16.1',
            '--bundle', str(self.bundle), '--tooling-lock-dir', str(self.tooling), '--no-service']
        installer = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        started = self.base/'npm-started'
        for _ in range(100):
            if started.exists(): break
            time.sleep(0.1)
        self.assertTrue(started.exists())
        self.assertEqual(self.run_host('cancel-install')['action'], 'cancel-install')
        installer.communicate(timeout=20)
        self.assertNotEqual(installer.returncode, 0)
        self.assertFalse((self.root/'.install-lock').exists())
        self.assertFalse((self.root/'current').exists())
        with self.assertRaises(ProcessLookupError): os.kill(int(started.read_text()), 0)

    def test_cancel_install_without_an_installer_is_a_no_op(self):
        self.install()
        self.assertEqual(self.run_host('cancel-install')['action'], 'cancel-install')

    def test_json_and_config_escape_paths(self):
        self.root = self.base/'managed "quote" \\ slash\t unicode-é'
        installed = self.install()
        self.assertEqual(installed['root'], str(self.root))
        self.assertEqual(self.run_host('inspect')['managed']['root'], str(self.root))
        fields = dict(line.split(' = ', 1) for line in (self.root/'config.toml').read_text().splitlines() if ' = ' in line)
        self.assertEqual(json.loads(fields['data_dir']), str(self.root/'data'))
        self.assertEqual(json.loads(fields['web_dir']), str(self.root/'current/apps/web/dist'))

    def test_argument_validation_and_reserved_port(self):
        for args in (('--wat',), ('--port', '4317'), ('--port', 'abc'), ('--service',),
                     ('--commit', 'deadbeef'), ('--port', '70000')):
            self.assertEqual(self.install(extra=args, success=False)['error'], 'arguments')
        for command, args in (('wat', ()), ('start', ('--delete-data',)), ('inspect', ('--root',))):
            self.assertEqual(self.run_host(command, *args, success=False)['error'], 'arguments')
        self.assertFalse(self.root.exists())

    def test_live_lock_refused_and_dead_lock_recovered(self):
        self.install()
        lock = self.root/'.install-lock'; lock.mkdir(); (lock/'pid').write_text(str(os.getpid()))
        self.assertEqual(self.install(success=False)['error'], 'locked')
        self.assertTrue((lock/'pid').exists())
        (lock/'pid').write_text('2147483647')
        self.install()
        self.assertFalse(lock.exists())

    def test_uninstall_retains_data_unless_explicitly_deleted(self):
        self.install(); (self.root/'data/fixture').write_text('retained')
        self.run_host('uninstall')
        self.assertTrue((self.root/'data/fixture').exists())
        self.assertTrue((self.root/'config.toml').exists())
        self.assertFalse((self.root/'current').exists())
        self.run_host('uninstall', '--delete-data')
        self.assertFalse((self.root/'data').exists())
        self.assertFalse((self.root/'config.toml').exists())

    def test_systemd_scoped_service_and_lingering(self):
        self.assertFalse(self.install(service=True)['lingering'])
        unit = self.home/'.config/systemd/user/wovenmatter-pi-bot-fixture.service'
        text = unit.read_text()
        self.assertIn('Restart=always', text)
        self.assertIn('Environment=PIBOT_RESTART_EXIT_CODE=75', text)
        self.assertIn(str(self.root/'run-server'), text)
        self.run_host('restart'); self.run_host('stop'); self.run_host('start')
        self.run_host('uninstall')
        self.assertFalse(unit.exists())

    def test_launchd_gui_and_headless_fallback(self):
        for headless in ('0', '1'):
            self.root = self.base/('mac-'+headless)
            value = self.install(service=True, PIBOT_TEST_OS='Darwin', PIBOT_TEST_NO_GUI=headless)
            self.assertIsNone(value['lingering'])
            calls = self.calls('launchctl')
            bootstrap = [c for c in calls if c[1] == 'bootstrap'][-1]
            self.assertTrue(bootstrap[2].startswith('user/' if headless == '1' else 'gui/'), bootstrap)
            import plistlib
            plist = plistlib.loads((self.home/'Library/LaunchAgents/io.wovenmatter.pi-bot.fixture.plist').read_bytes())
            self.assertTrue(plist['KeepAlive'])
            self.assertEqual(plist['EnvironmentVariables']['PIBOT_RESTART_EXIT_CODE'], '75')
            self.run_host('uninstall', PIBOT_TEST_OS='Darwin', PIBOT_TEST_NO_GUI=headless)
        self.assertEqual(self.calls('systemctl'), [])

    def test_explicit_port_uses_unreserved_scratch_port(self):
        self.assertEqual(self.install(extra=('--port', '4316'))['port'], 4316)
        config = json.loads((self.base/'configs').read_text().splitlines()[0])
        self.assertIn('port = 47310\n', config)
        self.assertFalse(any('4317/health' in arg for call in self.calls('curl') for arg in call))

    def test_musl_refused_before_download(self):
        self.assertEqual(self.run_host('inspect', PIBOT_TEST_LIBC='musl')['libc'], 'musl')
        self.assertEqual(self.install(success=False, PIBOT_TEST_LIBC='musl')['error'], 'libc')
        self.assertFalse(self.root.exists())

    def test_bundle_traversal_and_manifest_mismatch(self):
        archive(self.bundle, {'../escape':'bad'})
        self.assertEqual(self.install(success=False)['error'], 'bundle')
        self.assertFalse((self.base/'escape').exists())
        with tarfile.open(self.bundle, 'w:gz') as output:
            info = tarfile.TarInfo('outside-link'); info.type = tarfile.SYMTYPE; info.linkname = '../outside'
            output.addfile(info)
        self.assertEqual(self.install(success=False)['error'], 'bundle')
        self.make_bundle('b'*40)
        self.assertEqual(self.install(success=False)['error'], 'operation_failed')
        self.assertFalse((self.root/'current').exists())


if __name__ == '__main__':
    unittest.main()
