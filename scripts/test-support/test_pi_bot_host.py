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
import json, os, re, shutil, signal, subprocess, sys, time
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
base = Path(os.environ['PIBOT_TEST_BASE'])
with (base/'calls').open('a') as log: log.write(json.dumps([name, *args])+'\n')
def port(config): return re.search(r'^port = (\d+)', config.read_text(), re.M)[1]
def mark(p, value): (base/('port-'+p)).write_text(json.dumps(value))
if name == 'uname': print(os.environ.get('PIBOT_TEST_OS', 'Linux') if args == ['-s'] else os.environ.get('PIBOT_TEST_ARCH', 'x86_64'))
elif name == 'sw_vers': print(os.environ.get('PIBOT_TEST_MACOS', '27.2'))
elif name == 'pkgutil':
    if args[0] == '--check-signature': print(os.environ.get('PIBOT_TEST_PKG_SIGNER', 'Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)'))
    else:
        assert args[0] == '--expand-full', args
        cli = Path(args[2])/'Payload/bin/container'; cli.parent.mkdir(parents=True); shutil.copyfile(base/'bin/container-stub', cli); cli.chmod(0o755)
elif name in ('docker', 'container'): pass
elif name == 'getconf': print('glibc 2.39')
elif name == 'ldd':
    print(os.environ.get('PIBOT_TEST_LIBC', 'glibc'))
    if os.environ.get('PIBOT_TEST_LIBC') == 'musl': sys.exit(1)
elif name == 'loginctl': print(os.environ.get('PIBOT_TEST_LINGER', 'no'))
elif name == 'npm':
    assert args == ['ci', '--no-audit', '--no-fund'], args
    if os.environ.get('PIBOT_TEST_HANG_NPM') == '1':
        (base/'npm-started').write_text(str(os.getpid()))
        # A grandchild, as npm's own scripts would be, which ignores nothing and outlives no one.
        grandchild = subprocess.Popen(['sleep', '60'])
        (base/'npm-grandchild').write_text(str(grandchild.pid))
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
    if '-o' in args: shutil.copyfile(base/('container.pkg' if 'apple/container' in ' '.join(args) else 'node.tar.gz'), args[args.index('-o')+1])
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
        if '/' in args[1].split('/',1)[-1]:
            lag = base/'bootout-lag'
            left = int(lag.read_text()) if lag.exists() else 0
            if left > 0:
                lag.write_text(str(left-1))
                sys.exit(0)
            sys.exit(1)
        if args[1].startswith('gui/') and os.environ.get('PIBOT_TEST_NO_GUI') == '1': sys.exit(1)
    elif args[0] == 'bootstrap' and '.cleanup' in Path(args[2]).read_text():
        import html
        job = [html.unescape(value) for value in re.findall(r'<string>(.*?)</string>', Path(args[2]).read_text())][1:]
        subprocess.run(job, check=True)
    elif args[0] == 'bootstrap': mark(port(root/'config.toml'), {'version':'0.1.0'})
    elif args[0] == 'list': print('PID\tStatus\tLabel\n7\t0\tcom.apple.container.apiserver\n8\t0\tcom.example.other')
    elif args[0] == 'bootout' and ('com.apple.container' in args[1] or args[1].endswith('.cleanup')): pass
    elif args[0] == 'bootout':
        (base/('port-'+port(root/'config.toml'))).unlink(missing_ok=True)
        if os.environ.get('PIBOT_TEST_BOOTOUT_LAG'): (base/'bootout-lag').write_text(os.environ['PIBOT_TEST_BOOTOUT_LAG'])
    else: sys.exit(91)
else: sys.exit(92)
'''


# Stands in for Pi Bot's own parser, which its repository tests.
CONFIG_MODULE = r'''export function parseConfig(text) {
  if (text.includes('UNREADABLE')) throw new Error('invalid');
  const section = /^\[environment\]\n((?:(?!\[).*\n)*)/m.exec(text)[1];
  const value = (key) => { const m = new RegExp(`^${key} = (".*")$`, 'm').exec(section); return m ? JSON.parse(m[1]) : undefined; };
  return { environment: { backend: value('backend'), binary: value('binary'), install_root: value('install_root'), app_root: value('app_root') },
           paths: { database: JSON.parse(/^data_dir = (".*")$/m.exec(text)[1]) + '/pi-bot.sqlite' } };
}
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
        for name in ('node', 'npm', 'pnpm', 'systemctl', 'launchctl', 'curl', 'uname', 'ldd', 'getconf', 'loginctl', 'sw_vers', 'pkgutil', 'container-stub'):
            file = self.bin/name
            file.write_text(STUB)
            file.chmod(0o755)
        self.runtimes = self.base/'runtimes'
        self.runtimes.mkdir()
        archive(self.base/'node.tar.gz', {'node-v26.13.0-linux-x64/bin/node':STUB,
            'node-v26.13.0-linux-x64/bin/npm':STUB})
        self.checksum = hashlib.sha256((self.base/'node.tar.gz').read_bytes()).hexdigest()
        self.bundle = self.base/'bundle.tar.gz'
        self.tooling = ROOT/'pi-bot/tooling'
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
            PIBOT_TEST_BASE=str(self.base), PIBOT_TEST_REAL_NODE=NODE, PIBOT_TEST_ROOT=str(self.root),
            PI_BOT_RUNTIME_SEARCH_PATH=str(self.runtimes))
        self.make_bundle('a'*40)

    def tearDown(self):
        self.temp.cleanup()

    def make_bundle(self, commit):
        lock = 'lockfileVersion: 9\n'
        archive(self.bundle, {'manifest.json':json.dumps({'commit':commit, 'version':'0.1.0',
            'protocol':1, 'lockSha256':hashlib.sha256(lock.encode()).hexdigest()}),
            'package.json':'{"private":true}', 'pnpm-lock.yaml':lock,
            'pnpm-workspace.yaml':'packages: []', 'packages/server/dist/cli.js':'fixture',
            'apps/web/dist/index.html':'fixture', 'packages/server/dist/config.js':CONFIG_MODULE})

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
            if (self.base/'npm-grandchild').exists(): break
            time.sleep(0.1)
        self.assertTrue(started.exists())
        self.assertEqual(self.run_host('cancel-install')['action'], 'cancel-install')
        installer.communicate(timeout=20)
        self.assertNotEqual(installer.returncode, 0)
        self.assertFalse((self.root/'.install-lock').exists())
        self.assertFalse((self.root/'current').exists())
        with self.assertRaises(ProcessLookupError): os.kill(int(started.read_text()), 0)
        with self.assertRaises(ProcessLookupError): os.kill(int((self.base/'npm-grandchild').read_text()), 0)

    def test_cancel_install_without_an_installer_is_a_no_op(self):
        self.install()
        self.assertEqual(self.run_host('cancel-install')['action'], 'cancel-install')

    def add_runtime(self, name):
        # Records what it's asked, unlike the other stubs: this is what removal must leave alone.
        file = self.runtimes/name
        file.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> ' + repr(str(self.base/('runtime-'+name))) + '\n')
        file.chmod(0o755)
        return file

    def environment_of(self):
        text = (self.root/'config.toml').read_text()
        return text[text.index('[environment]'):text.index('[models]')]

    def test_linux_without_docker_has_no_bot_tools(self):
        self.install()
        self.assertIn('backend = "none"', self.environment_of())
        self.assertEqual(self.run_host('inspect')['environment'], 'none')

    def test_linux_with_docker_runs_bot_tools_there(self):
        docker = self.add_runtime('docker')
        self.assertEqual(self.run_host('inspect')['environment'], 'docker')
        self.install()
        self.assertIn('backend = "docker"', self.environment_of())
        self.assertIn('binary = ' + json.dumps(str(docker)), self.environment_of())

    def test_the_health_check_never_starts_a_container_runtime(self):
        self.add_runtime('docker')
        self.install()
        for config in map(json.loads, (self.base/'configs').read_text().splitlines()):
            self.assertIn('[environment]\nbackend = "none"', config)

    def mac(self, **env):
        return dict(PIBOT_TEST_OS='Darwin', PIBOT_TEST_ARCH='arm64', **env)

    def mac_archive(self):
        archive(self.base/'node.tar.gz', {'node-v26.13.0-darwin-arm64/bin/node':STUB, 'node-v26.13.0-darwin-arm64/bin/npm':STUB})
        self.checksum = hashlib.sha256((self.base/'node.tar.gz').read_bytes()).hexdigest()

    def container_args(self, payload=b'not a real package'):
        (self.base/'container.pkg').write_bytes(payload)
        return ('--container-version', '1.6.1', '--container-sha256', hashlib.sha256(payload).hexdigest())

    @property
    def shared_runtime(self):
        return self.home/'Library/Application Support/Woven Matter Pi Bot/runtime'

    def test_a_current_mac_gets_a_private_apple_container_without_admin(self):
        self.mac_archive()
        self.assertEqual(self.run_host('inspect', **self.mac())['environment'], 'container')
        self.install(extra=self.container_args(), **self.mac())
        env = self.environment_of()
        self.assertIn('backend = "container"', env)
        private = self.shared_runtime/'container/1.6.1'
        self.assertTrue((private/'bin/container').exists())
        self.assertIn('install_root = ' + json.dumps(str(private)), env)
        self.assertIn('app_root = ' + json.dumps(str(self.shared_runtime/'container-data')), env)
        self.assertTrue(any('apple/container/releases/download/1.6.1/container-1.6.1-installer-signed.pkg' in ' '.join(call) for call in self.calls('curl')))

    def test_an_installed_apple_container_is_used_as_it_is(self):
        self.mac_archive()
        container = self.add_runtime('container')
        self.install(extra=self.container_args(), **self.mac())
        env = self.environment_of()
        self.assertIn('binary = ' + json.dumps(str(container)), env)
        self.assertNotIn('install_root', env)
        self.assertFalse(self.shared_runtime.exists())

    def test_apple_package_must_match_and_be_signed_by_apple(self):
        self.mac_archive()
        args = list(self.container_args())
        args[3] = 'a'*64
        self.assertEqual(self.install(extra=tuple(args), success=False, **self.mac())['error'], 'checksum')
        self.assertEqual(self.install(extra=self.container_args(), success=False, PIBOT_TEST_PKG_SIGNER='Developer ID Installer: Someone Else', **self.mac())['error'], 'container')

    def test_older_and_intel_macs_fall_back_to_docker(self):
        self.add_runtime('docker')
        for env in (dict(PIBOT_TEST_OS='Darwin', PIBOT_TEST_ARCH='arm64', PIBOT_TEST_MACOS='15.6'), dict(PIBOT_TEST_OS='Darwin', PIBOT_TEST_ARCH='x86_64')):
            self.assertEqual(self.run_host('inspect', **env)['environment'], 'docker')

    def seed_bots(self, *ids):
        script = "const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync(process.argv[1]);d.exec('CREATE TABLE pibot_bots (id TEXT)');for(const i of process.argv.slice(2))d.prepare('INSERT INTO pibot_bots VALUES (?)').run(i);d.close()"
        subprocess.run([NODE, '-e', script, str(self.root/'data/pi-bot.sqlite'), *ids], check=True)

    def test_removing_data_removes_only_this_installations_bot_containers(self):
        self.add_runtime('docker')
        self.install()
        self.seed_bots('bot-a', 'bot-b')
        self.run_host('uninstall', '--delete-data')
        calls = (self.base/'runtime-docker').read_text().splitlines()
        self.assertEqual(sorted(calls), sorted(['rm -f pi-bot-bot-a', 'volume rm pi-bot-bot-a-workspace', 'rm -f pi-bot-bot-b', 'volume rm pi-bot-bot-b-workspace']))

    def test_keeping_data_keeps_bot_containers(self):
        self.add_runtime('docker')
        self.install()
        self.seed_bots('bot-a')
        self.run_host('uninstall')
        self.assertFalse((self.base/'runtime-docker').exists())

    def scripted_private_cli(self, others='', fails=''):
        # Answers as the runtime would, and records what it's asked.
        cli = self.shared_runtime/'container/1.6.1/bin/container'
        calls = self.base/'private-calls'
        failing = f'case "$*" in {fails}) echo "Error: storage failure" >&2; exit 1 ;; esac' if fails else ''
        cli.write_text(f"""#!/bin/sh
printf '%s\\n' "$*" >> {str(calls)!r}
{failing}
case "$*" in "list --all --quiet") printf '%b' {others!r} ;; esac
""")
        return calls

    def test_removing_the_last_installation_removes_the_shared_runtime(self):
        self.mac_archive()
        self.install(extra=self.container_args(), **self.mac())
        self.seed_bots('bot-a')
        calls = self.scripted_private_cli()
        self.run_host('uninstall', '--delete-data', **self.mac())
        asked = calls.read_text().splitlines()
        self.assertIn('delete --force pi-bot-bot-a', asked)
        self.assertIn('volume delete pi-bot-bot-a-workspace', asked)
        self.assertEqual(asked[-1], 'system stop')
        booted = [call[2] for call in self.calls('launchctl') if call[1] == 'bootout']
        self.assertTrue(any(label.endswith('/com.apple.container.apiserver') for label in booted), booted)
        self.assertFalse(any('com.example.other' in label for label in booted), booted)
        self.assertFalse(self.root.exists())
        self.assertFalse(self.shared_runtime.exists())

    def test_removing_one_installation_keeps_the_runtime_another_uses(self):
        self.mac_archive()
        self.install(extra=self.container_args(), **self.mac())
        self.seed_bots('bot-a')
        (self.shared_runtime/'instances/another-installation').write_text('')
        calls = self.scripted_private_cli()
        self.run_host('uninstall', '--delete-data', **self.mac())
        asked = calls.read_text().splitlines()
        self.assertIn('delete --force pi-bot-bot-a', asked)
        self.assertNotIn('system stop', asked)
        self.assertTrue((self.shared_runtime/'container/1.6.1/bin/container').exists())
        self.assertFalse((self.shared_runtime/'instances'/hashlib.sha256(str(self.root).encode()).hexdigest()).exists())

    def test_containers_it_does_not_know_keep_the_runtime(self):
        self.mac_archive()
        self.install(extra=self.container_args(), **self.mac())
        self.seed_bots('bot-a')
        calls = self.scripted_private_cli('buildkit\\nsomeone-elses\\n')
        self.run_host('uninstall', '--delete-data', **self.mac())
        self.assertNotIn('system stop', calls.read_text().splitlines())
        self.assertTrue(self.shared_runtime.exists())

    def registration(self):
        return self.shared_runtime/'instances'/hashlib.sha256(str(self.root).encode()).hexdigest()

    def prepared_removal(self, **cli):
        self.mac_archive()
        self.install(extra=self.container_args(), **self.mac())
        self.seed_bots('bot-a')
        return self.scripted_private_cli(**cli)

    def test_a_container_that_cannot_be_removed_keeps_everything(self):
        self.prepared_removal(fails='"delete --force pi-bot-bot-a"')
        self.assertEqual(self.run_host('uninstall', '--delete-data', success=False, **self.mac())['error'], 'runtime')
        self.assertTrue((self.root/'data/pi-bot.sqlite').exists())
        self.assertTrue(self.registration().exists())
        self.assertFalse((self.shared_runtime/'.lock').exists())

    def test_a_volume_still_listed_after_a_failed_delete_keeps_everything(self):
        calls = self.prepared_removal(fails='"volume delete pi-bot-bot-a-workspace"')
        cli = self.shared_runtime/'container/1.6.1/bin/container'
        cli.write_text(cli.read_text().replace('"list --all --quiet")', '"volume list --quiet") echo pi-bot-bot-a-workspace ;; "list --all --quiet")'))
        self.assertEqual(self.run_host('uninstall', '--delete-data', success=False, **self.mac())['error'], 'runtime')
        self.assertTrue(self.registration().exists())
        self.assertIn('volume list --quiet', calls.read_text().splitlines())

    def test_a_volume_already_gone_is_not_a_failure(self):
        self.prepared_removal(fails='"volume delete pi-bot-bot-a-workspace"')
        self.run_host('uninstall', '--delete-data', **self.mac())
        self.assertFalse(self.shared_runtime.exists())

    def test_a_failed_listing_never_retires_the_runtime(self):
        calls = self.prepared_removal(fails='"list --all --quiet"')
        self.assertEqual(self.run_host('uninstall', '--delete-data', success=False, **self.mac())['error'], 'runtime')
        self.assertNotIn('system stop', calls.read_text().splitlines())
        self.assertTrue(self.shared_runtime.exists())

    def test_a_runtime_that_will_not_stop_is_not_deleted(self):
        self.prepared_removal(fails='"system stop"')
        self.run_host('uninstall', '--delete-data', **self.mac())
        self.assertFalse(self.root.exists())
        self.assertTrue((self.shared_runtime/'container/1.6.1/bin/container').exists())
        self.assertFalse(self.registration().exists())
        self.assertFalse((self.shared_runtime/'.lock').exists())

    def test_a_failed_first_install_is_not_recorded_as_using_the_runtime(self):
        self.mac_archive()
        self.assertEqual(self.install(extra=self.container_args(), success=False, PIBOT_TEST_BAD_HEALTH='1', **self.mac())['error'], 'health')
        self.assertFalse(self.registration().exists())
        self.assertFalse((self.shared_runtime/'.lock').exists())

    def test_a_cancelled_install_stops_counting_when_removed(self):
        self.mac_archive()
        self.registration().parent.mkdir(parents=True)
        self.registration().write_text('')
        (self.root/'data').mkdir(parents=True)
        (self.root/'.woven-instance').write_text('fixture\n')
        self.run_host('uninstall', '--delete-data', **self.mac())
        self.assertFalse(self.registration().exists())

    def test_a_lock_left_by_a_dead_installer_is_recovered(self):
        self.mac_archive()
        lock = self.shared_runtime/'.lock'
        lock.mkdir(parents=True)
        (lock/'pid').write_text('2147483647')
        self.install(extra=self.container_args(), **self.mac())
        self.assertFalse(lock.exists())

    def test_an_installed_runtime_is_never_stopped(self):
        self.mac_archive()
        self.add_runtime('container')
        self.install(extra=self.container_args(), **self.mac())
        self.seed_bots('bot-a')
        self.run_host('uninstall', '--delete-data', **self.mac())
        asked = (self.base/'runtime-container').read_text().splitlines()
        self.assertIn('delete --force pi-bot-bot-a', asked)
        self.assertNotIn('system stop', asked)

    def test_docker_being_down_keeps_the_data_that_names_the_containers(self):
        docker = self.add_runtime('docker')
        self.install()
        self.seed_bots('bot-a')
        working = docker.read_text()
        docker.write_text('#!/bin/sh\necho "Cannot connect to the Docker daemon" >&2\nexit 1\n')
        self.assertEqual(self.run_host('uninstall', '--delete-data', success=False)['error'], 'runtime')
        self.assertTrue((self.root/'data/pi-bot.sqlite').exists())
        self.assertTrue((self.root/'config.toml').exists())
        docker.write_text(working)
        self.run_host('uninstall', '--delete-data')
        self.assertFalse(self.root.exists())

    def test_missing_containers_are_already_removed(self):
        docker = self.add_runtime('docker')
        self.install()
        self.seed_bots('bot-a')
        docker.write_text('#!/bin/sh\necho "Error response from daemon: No such container" >&2\nexit 1\n')
        self.run_host('uninstall', '--delete-data')
        self.assertFalse(self.root.exists())

    def test_a_docker_that_was_uninstalled_does_not_block_removal(self):
        docker = self.add_runtime('docker')
        self.install()
        self.seed_bots('bot-a')
        docker.unlink()
        self.run_host('uninstall', '--delete-data')
        self.assertFalse(self.root.exists())

    def test_an_unreadable_config_deletes_nothing(self):
        self.add_runtime('docker')
        self.install()
        self.seed_bots('bot-a')
        with (self.root/'config.toml').open('a') as config: config.write('# UNREADABLE\n')
        self.assertEqual(self.run_host('uninstall', '--delete-data', success=False)['error'], 'config')
        self.assertTrue((self.root/'data/pi-bot.sqlite').exists())

    def test_stop_with_nothing_installed_is_already_done(self):
        self.assertEqual(self.run_host('stop')['action'], 'stop')
        self.assertEqual(self.run_host('start', success=False)['error'], 'not_installed')

    def test_macos_restart_waits_for_launchd_to_let_go(self):
        self.mac_archive()
        self.install(service=True, extra=self.container_args(), **self.mac())
        (self.base/'calls').write_text('')
        self.run_host('restart', PIBOT_TEST_BOOTOUT_LAG='2', **self.mac())
        verbs = [call[1] for call in self.calls('launchctl')]
        self.assertEqual(verbs.count('bootout'), 1)
        self.assertEqual(verbs.count('bootstrap'), 1, verbs)
        self.assertGreater(verbs.index('bootstrap'), verbs.index('bootout'))

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
