"""Cache integrity and invalidation tests, without credentials or upstream access."""
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

downloads = load('downloads', 'cached-download.py')
browser = load('browser', 'browser-build-cache.py')
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    archive = b'locked upstream archive'
    expected = hashlib.sha256(archive).hexdigest()
    calls = []
    def fetch(command, **kwargs):
        calls.append(command)
        Path(command[-1]).write_bytes(archive)
    with patch.object(downloads.subprocess, 'run', side_effect=fetch):
        path = downloads.download('https://example.invalid/archive', 'sha256', expected, root / 'downloads')
        assert len(calls) == 1
        assert downloads.download('https://example.invalid/archive', 'sha256', expected, root / 'downloads') == path
        assert len(calls) == 1
        path.write_bytes(b'corrupt restore')
        downloads.download('https://example.invalid/archive', 'sha256', expected, root / 'downloads')
        assert len(calls) == 2 and path.read_bytes() == archive
        # A verified hit marks the current pin so the producer can prune superseded archives.
        os.utime(path, (1, 1))
        downloads.download('https://example.invalid/archive', 'sha256', expected, root / 'downloads')
        assert len(calls) == 2 and path.stat().st_mtime > 1
        try:
            downloads.download('https://example.invalid/archive', 'sha256', '0' * 64, root / 'downloads')
            raise AssertionError('Unpinned download accepted')
        except ValueError:
            pass
        assert not list((root / 'downloads').glob('.download-*'))
    build, cache, restored = root / 'build', root / 'browser', root / 'restored'
    for name in browser.PRODUCTS:
        path = build / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(name.encode())
        path.chmod(0o755)
    assert browser.transfer('save', cache, build)
    assert not cache.exists(), 'A release consumer must not write the shared cache'
    with patch.dict(os.environ, WOVENMATTER_WRITE_BROWSER_CACHE='1'):
        assert browser.transfer('save', cache, build)
    assert browser.transfer('restore', cache, restored)
    assert (restored / 'WovenBrowserHelper').stat().st_mode == (build / 'WovenBrowserHelper').stat().st_mode
    (cache / 'WovenBrowserHelper').write_bytes(b'corrupt')
    assert not browser.transfer('restore', cache, root / 'bad')
    assert not (root / 'bad').exists()
    source = root / 'source'
    (source / 'app/Browser').mkdir(parents=True)
    (source / 'scripts').mkdir()
    (source / 'app/Browser/Helper.cc').write_text('first')
    for name in ('prepare-browser.sh', 'browser-build-cache.py'):
        (source / 'scripts' / name).write_text('script')
    with patch.object(browser, 'ROOT', source), patch.object(browser.subprocess, 'check_output', return_value=b'toolchain 1'):
        original = browser.key('arm64', 'cmake')
        assert browser.key('x86_64', 'cmake') != original
        with patch.dict(os.environ, CXXFLAGS='-DCHANGED'):
            assert browser.key('arm64', 'cmake') != original
        (source / 'app/Browser/Helper.cc').write_text('second')
        assert browser.key('arm64', 'cmake') != original

# Component keys: one input family changes only the caches that consume it.
TOOLS = r'''#!/usr/bin/env python3
import os, pathlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
if name == 'uname': print('arm64')
elif name == 'xcrun' and '--show-sdk-path' in args: print(os.environ['FIXTURE_SDK'])
elif name == 'cmake' and os.environ.get('FIXTURE_CMAKE_FAILS'): sys.exit(1)
else: print(name, ' '.join(args), os.environ.get('FIXTURE_TOOLCHAIN', 'xcode 26'))
'''
INPUTS = ('app/Browser/cef-version.json', 'app/Browser/Helper.cc', 'default-agent/.node-version',
          'default-agent/package.json', 'default-agent/package-lock.json', 'scripts/prepare-default-agent.sh',
          'app/Updater/sparkle-version.json', 'app/Automation/cua-version.json', 'app/Package.resolved',
          'app/Package.swift', 'shared/Package.swift', 'app/WovenMatter.xcodeproj/project.pbxproj',
          'scripts/build-release.sh', 'scripts/warm-release-compiler.sh', 'scripts/prepare-browser.sh',
          'app/Sources/Feature.swift')
with tempfile.TemporaryDirectory() as temp:
    repo, tools = Path(temp) / 'repo', Path(temp) / 'bin'
    tools.mkdir()
    for name in ('uname', 'xcodebuild', 'xcrun', 'cmake'):
        (tools / name).write_text(TOOLS)
        (tools / name).chmod(0o755)
    for name in INPUTS:
        (repo / name).parent.mkdir(parents=True, exist_ok=True)
        (repo / name).write_text(name)
    for name in ('release-cache-key.sh', 'browser-build-cache.py', 'cached-download.py'):
        shutil.copy2(ROOT / 'scripts' / name, repo / 'scripts' / name)
    subprocess.run(['git', '-C', str(repo), 'init', '-q'], check=True)
    subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
    # macOS's python3 shim honors SDKROOT, so the fixture reports the real SDK there.
    real_xcrun = shutil.which('xcrun')
    sdk = subprocess.check_output([real_xcrun, '--sdk', 'macosx', '--show-sdk-path'], text=True).strip() if real_xcrun else '/fixture/sdk'
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], FIXTURE_SDK=sdk)
    for name in ('CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET'):
        env.pop(name, None)
    def keys(**changes):
        output = subprocess.check_output([str(repo / 'scripts/release-cache-key.sh')], env=dict(env, **changes), text=True)
        return dict(line.split('=', 1) for line in output.splitlines())
    baseline = keys()
    assert all(baseline[name].startswith(baseline[name + '_fallback']) for name in ('downloads', 'swiftpm', 'npm', 'compiler'))
    def changed(name, **changes):
        path = repo / name if name else None
        if path:
            previous = path.read_text()
            path.write_text(previous + ' changed')
        try:
            current = keys(**changes)
        finally:
            if path:
                path.write_text(previous)
        return {key for key in baseline if current[key] != baseline[key]}
    assert changed('default-agent/.node-version') == {'downloads'}
    assert changed('default-agent/package-lock.json') == {'npm'}
    assert changed('app/Package.resolved') == {'swiftpm', 'compiler'}
    assert changed('app/WovenMatter.xcodeproj/project.pbxproj') == {'compiler'}
    assert changed('app/Browser/Helper.cc') == {'browser'}
    assert changed('app/Browser/cef-version.json') == {'downloads', 'browser'}
    # Individual sources are keyed by Xcode's CAS and the workflow's commit suffix.
    assert changed('app/Sources/Feature.swift') == set()
    assert changed(None, FIXTURE_TOOLCHAIN='xcode 27') == {'browser', 'compiler', 'compiler_fallback'}
    assert keys() == baseline
    # A failed input aborts rather than emitting a shared constant key.
    failed = subprocess.run([str(repo / 'scripts/release-cache-key.sh')], env=dict(env, FIXTURE_CMAKE_FAILS='1'),
                            capture_output=True, text=True)
    assert failed.returncode != 0 and 'browser=' not in failed.stdout, failed

# The signed tag consumer restores exactly what the trusted main producer saves.
def cache_steps(path):
    lines, steps = path.read_text().splitlines(), []
    for index, line in enumerate(lines):
        match = re.match(r'(\s*)- uses: actions/cache(/\w+)?@', line)
        if not match:
            continue
        step, block, depth = dict(action=match[2] or 'cache'), None, 0
        for following in lines[index + 1:]:
            indent = len(following) - len(following.lstrip())
            if following.strip() and indent <= len(match[1]):
                break
            if block and indent > depth:
                step[block] = (step[block] + '\n' + following.strip()).strip()
                continue
            entry = re.match(r'\s*([a-z-]+): ?(.*)', following)
            if entry:
                step[entry[1]] = '' if entry[2] == '|' else entry[2]
                block, depth = (entry[1] if entry[2] == '|' else None), indent
        steps.append(step)
    return steps
signature = lambda step: (step['path'], step['key'], step.get('restore-keys', ''))
producer = cache_steps(ROOT / '.github/workflows/release-cache.yml')
consumer = cache_steps(ROOT / '.github/workflows/release.yml')
assert consumer and all(step['action'] == '/restore' for step in consumer), 'Release tags must never save caches'
restores = [step for step in producer if step['action'] == '/restore']
assert sorted(map(signature, consumer)) == sorted(map(signature, restores))
saves = [step for step in producer if step['action'] == '/save']
assert {(s['path'], s['key']) for s in saves} == {(s['path'], s['key']) for s in restores}
emitted = {line.split('=', 1)[0] for line in subprocess.check_output(
    ['grep', '-o', r"printf '[a-z_]*=", str(ROOT / 'scripts/release-cache-key.sh')], text=True).replace("printf '", '').splitlines()}
used = set(re.findall(r'steps\.inputs\.outputs\.([a-z_]+)', '\n'.join(map(str, producer + consumer))))
assert used == emitted, (used, emitted)
assert 'secrets.' not in (ROOT / '.github/workflows/release-cache.yml').read_text()
print('Release cache: verified hits, pin marking, corruption recovery, pin rejection, read-only consumer, '
      'source/architecture/flags invalidation, independent component keys and producer/consumer agreement passed.')
