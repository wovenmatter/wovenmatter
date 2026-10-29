"""Release phases: real build-release.sh in a temporary tagged repository, stubbed tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['PHASE_CALLS'], 'a') as log:
    log.write(json.dumps([name, args]) + '\n')
if name == 'uname': print('Darwin' if args == ['-s'] else 'arm64')
elif name == 'security': print('  1) ABC "Developer ID Application: Fixture (TEAM)"')
elif name == 'xcodebuild':
    if os.environ.get('PHASE_CACHE_FAILS') == '1' and 'COMPILATION_CACHE_ENABLE_CACHING=YES' in args: sys.exit(1)
    app = pathlib.Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Release/Woven Matter.app/Contents'
    app.mkdir(parents=True, exist_ok=True)
    (app / 'Info.plist').write_text('fixture')
elif name == 'xcrun' and args[:2] == ['notarytool', 'submit']:
    print(json.dumps(dict(id='fixture', status=os.environ.get('PHASE_NOTARY', 'Accepted'))))
elif name == 'ditto':
    target = pathlib.Path(args[-1])
    if args[0] == '-c': target.write_bytes(b'zip')
    else: target.mkdir(parents=True)
elif name in ('create-release-dmg.sh',): pathlib.Path(args[1]).write_bytes(b'dmg')
'''
PHASES = ['compile', 'seal', 'notarize-app', 'package', 'notarize-dmg', 'feed']

with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    repo, stubs, work = temp / 'repo', temp / 'bin', temp / 'work'
    (repo / 'scripts').mkdir(parents=True)
    stubs.mkdir()
    shutil.copy2(ROOT / 'scripts/build-release.sh', repo / 'scripts/build-release.sh')
    for name in ('uname', 'security', 'xcodebuild', 'codesign', 'xcrun', 'spctl', 'ditto'):
        (stubs / name).write_text(TOOL)
        (stubs / name).chmod(0o755)
    for name in ('sign-release-updater.sh', 'validate-native-app.sh', 'create-release-dmg.sh',
                 'generate-release-manifest.sh', 'generate-update-feed.sh',
                 'validate-release-metadata.py', 'validate-release-code.py'):
        (repo / 'scripts' / name).write_text(TOOL)
        (repo / 'scripts' / name).chmod(0o755)
    git = ['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid']
    subprocess.run(git + ['init', '-q'], check=True)
    subprocess.run(git + ['add', '.'], check=True)
    subprocess.run(git + ['commit', '-qm', 'fixture'], check=True)
    subprocess.run(git + ['tag', 'v1.2.3'], check=True)
    revision = subprocess.check_output(git + ['rev-parse', 'HEAD'], text=True).strip()
    calls, summary = temp / 'calls', temp / 'summary.md'
    base = dict(os.environ, PATH=str(stubs) + os.pathsep + os.environ['PATH'], PHASE_CALLS=str(calls),
                WOVENMATTER_RELEASE_WORK_DIR=str(work), WOVENMATTER_RELEASE_OUTPUT_DIR=str(temp / 'dist'),
                WOVENMATTER_TEAM_ID='TEAM', WOVENMATTER_NOTARY_KEYCHAIN_PROFILE='fixture',
                WOVENMATTER_COMPILER_CACHE=str(temp / 'cas'), WOVENMATTER_RELEASE_ALLOW_UNTAGGED='0',
                GITHUB_ACTIONS='true', GITHUB_STEP_SUMMARY=str(summary))
    for name in ('PHASE_NOTARY', 'PHASE_CACHE_FAILS', 'WOVENMATTER_BUILD_NUMBER', 'WOVENMATTER_SIGNING_IDENTITY'):
        base.pop(name, None)

    def phase(name, expected=0, **env):
        calls.write_text('')
        arguments = name if isinstance(name, list) else [name]
        result = subprocess.run([str(repo / 'scripts/build-release.sh'), '1.2.3', *arguments],
                                env=dict(base, **env), capture_output=True, text=True)
        assert result.returncode == expected, (name, result)
        return [json.loads(line) for line in calls.read_text().splitlines()], result

    def ran(recorded, tool, *prefix):
        return any(n == tool and a[:len(prefix)] == list(prefix) for n, a in recorded)

    def timings():
        return [json.loads(line) for line in (work / 'release-timings.jsonl').read_text().splitlines()]

    # The workflow's separate steps, in order, each a fresh process.
    order = []
    for name in PHASES:
        recorded, result = phase(name)
        order += [n for n, _ in recorded if n not in ('uname', 'security')]
        assert f'release-timing {{"phase":"{name}","result":"ok"' in result.stdout
    first = lambda tool: order.index(tool)
    assert first('xcodebuild') < first('sign-release-updater.sh') < first('xcrun') \
        < first('create-release-dmg.sh') < first('generate-update-feed.sh'), order
    records = timings()
    assert [r['phase'] for r in records] == PHASES and all(r['result'] == 'ok' for r in records)
    assert all(r['version'] == '1.2.3' and r['build'] == 1 and r['revision'] == revision for r in records)
    assert all(f'Phase {name} ok after' in summary.read_text() for name in PHASES)
    # A completed phase is never repeated, and nothing follows the final phase twice.
    phase('seal', 65)
    phase('feed', 65)

    # Later phases accept only the packaged output directory and signing identity,
    # however the same directory is spelled; nothing reaches Apple or the feed otherwise.
    for name in PHASES[:4]:
        phase(name)
    other = str(temp / 'other-dist')
    recorded, result = phase('notarize-dmg', 65, WOVENMATTER_RELEASE_OUTPUT_DIR=other)
    assert not ran(recorded, 'xcrun') and 'requires completed phase package' in result.stderr
    recorded, _ = phase('notarize-dmg', 65, WOVENMATTER_SIGNING_IDENTITY='Developer ID Application: Other')
    assert not ran(recorded, 'xcrun')
    phase('notarize-dmg', WOVENMATTER_RELEASE_OUTPUT_DIR=str(temp / 'dist') + '/./')
    recorded, _ = phase('feed', 65, WOVENMATTER_RELEASE_OUTPUT_DIR=other)
    assert not ran(recorded, 'generate-release-manifest.sh') and not ran(recorded, 'generate-update-feed.sh')
    phase('feed')

    # Out-of-order work never reaches packaging tools.
    phase('compile')
    recorded, result = phase('package', 65)
    assert not ran(recorded, 'create-release-dmg.sh') and 'requires completed phase notarize-app' in result.stderr

    # Rejected notarization stops before stapling and invalidates the work directory.
    phase('seal')
    recorded, _ = phase('notarize-app', 65, PHASE_NOTARY='Invalid')
    assert ran(recorded, 'xcrun', 'notarytool', 'log') and not ran(recorded, 'xcrun', 'stapler')
    assert timings()[-1]['phase'] == 'notarize-app' and timings()[-1]['result'] == 'failed'
    recorded, _ = phase('notarize-app', 65)
    assert not ran(recorded, 'xcrun', 'notarytool', 'submit'), 'A failed phase was resumed'
    phase('package', 65)

    # A failed cached compile retries once, clean and uncached.
    recorded, _ = phase('compile', PHASE_CACHE_FAILS='1')
    builds = [a for n, a in recorded if n == 'xcodebuild']
    assert len(builds) == 2 and 'COMPILATION_CACHE_ENABLE_CACHING=NO' in builds[1]

    # Work from one source is refused for another; untagged sources are refused.
    subprocess.run(git + ['commit', '-q', '--allow-empty', '-m', 'later'], check=True)
    phase('seal', 65, WOVENMATTER_RELEASE_ALLOW_UNTAGGED='1')
    recorded, _ = phase('compile', 65)
    assert not ran(recorded, 'xcodebuild')
    subprocess.run(git + ['reset', '-q', '--hard', 'v1.2.3'], check=True)
    (repo / 'scripts/build-release.sh').write_text((repo / 'scripts/build-release.sh').read_text() + '\n')
    phase('compile', 65)
    subprocess.run(git + ['checkout', '-q', '--', 'scripts/build-release.sh'], check=True)

    # Missing team ID, invalid phase names, and a complete local run.
    recorded, _ = phase('compile', 1, WOVENMATTER_TEAM_ID='')
    assert not ran(recorded, 'xcodebuild')
    # Only one exact phase name: never a silent successful no-op.
    for invalid in ('everything', 'compile seal', 'Compile', '', ' compile', ['compile', 'seal'], ['all', 'extra']):
        recorded, _ = phase(invalid, 64)
        assert not ran(recorded, 'xcodebuild'), invalid
    phase('all')
    assert [r['phase'] for r in timings()] == PHASES
print('Release phases: ordered steps, per-phase timings, no repeated or out-of-order phases, notarization '
      'rejection invalidates work, cached-compile retry, source/tag/clean binding passed.')
