"""Offline release publication contract: real script, stubbed external services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
STUB = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['RELEASE_CALLS'], 'a') as log:
    log.write(json.dumps([name, args]) + '\n')
sha = 'a' * 40
if name == 'git':
    if args[:2] == ['remote', 'get-url']:
        print('git@github-release-agent:wovenmatter/wovenmatter.git')
    elif args[0] == 'rev-parse': print(sha)
    elif args[0] == 'ls-remote': print(sha + '\trefs/tags/v1.2.3^{}')
    elif args[0] not in ('fetch', 'merge-base'): sys.exit(90)
elif name == 'gh':
    if args[0] == 'api': print('release-agent')
    elif args[:2] == ['run', 'list']:
        print(json.dumps([dict(headSha=sha, status='completed', conclusion='success', url='fixture')]))
    elif args[:2] == ['release', 'view']:
        published = pathlib.Path(os.environ['RELEASE_PUBLISHED']).exists()
        print(json.dumps(dict(tagName='v1.2.3', isDraft=not published, publishedAt='now' if published else None, url='fixture', assets=[dict(name=n) for n in ['SHA256SUMS.txt', 'WovenMatter_1.2.3_arm64.dmg', 'latest-mac.json']])))
    elif args[:2] == ['release', 'download']:
        dest = pathlib.Path(args[args.index('--dir') + 1])
        asset = 'WovenMatter_1.2.3_arm64.dmg'
        (dest / asset).write_bytes(b'fixture')
        manifest = dict(schema_version=1, version='1.2.3', build=1, architecture='arm64', minimum_macos='26.0', download_url='https://github.com/wovenmatter/wovenmatter/releases/download/v1.2.3/' + asset, release_url='https://github.com/wovenmatter/wovenmatter/releases/tag/v1.2.3', sha256=hashlib.sha256(b'fixture').hexdigest())
        (dest / 'latest-mac.json').write_text(json.dumps(manifest))
        (dest / 'SHA256SUMS.txt').write_text(''.join(hashlib.sha256((dest / n).read_bytes()).hexdigest() + '  ' + n + '\n' for n in [asset, 'latest-mac.json']))
    elif args[:2] == ['release', 'edit']:
        assert '--draft=false' in args
        notes = pathlib.Path(args[args.index('--notes-file') + 1]).read_bytes()
        pathlib.Path(os.environ['RELEASE_PUBLISHED']).write_bytes(notes)
    else: sys.exit(91)
elif name == 'codesign': print('Authority=Developer ID Application: Fixture')
elif name == 'spctl':
    if os.environ.get('RELEASE_FAIL_VERIFY') == '1': sys.exit(1)
    print('accepted\nsource=Notarized Developer ID')
elif name != 'xcrun': sys.exit(92)
'''

with tempfile.TemporaryDirectory() as folder:
    temp = Path(folder)
    for name in ('git', 'gh', 'codesign', 'spctl', 'xcrun'):
        tool = temp / name
        tool.write_text(STUB)
        tool.chmod(0o755)
    calls, published = temp / 'calls', temp / 'published'
    env = dict(os.environ, PATH=str(temp) + os.pathsep + os.environ['PATH'],
               RELEASE_CALLS=str(calls), RELEASE_PUBLISHED=str(published))
    def run(options, success):
        calls.write_text('')
        published.unlink(missing_ok=True)
        result = subprocess.run([str(ROOT / 'scripts/publish-release.sh'), *options,
                                 'v1.2.3', 'a' * 40], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == success, result
        return [json.loads(line) for line in calls.read_text().splitlines()]

    for options in ([], ['--verify-only']):
        recorded = run(options, True)
        assert not published.exists()
        assert any(name == 'spctl' for name, _ in recorded), recorded
        assert not any(name == 'gh' and args[:2] == ['release', 'edit'] for name, args in recorded)
    notes = temp / 'approved notes.md'
    for text in ('', '  \n', 'Signed and notarized Apple Silicon release.\n'):
        notes.write_text(text)
        assert run(['--approved-notes', str(notes)], False) == []
        assert not published.exists()
    assert run(['--approved-notes', str(temp / 'missing')], False) == []
    body = 'This release improves workspace navigation.\n\n- Find your notes faster.\n\n[Full changelog](https://github.com/wovenmatter/wovenmatter/compare/v1.2.2...v1.2.3)\n'
    notes.write_text(body)
    env['RELEASE_FAIL_VERIFY'] = '1'
    run(['--approved-notes', str(notes)], False)
    assert not published.exists()
    env.pop('RELEASE_FAIL_VERIFY')
    recorded = run(['--approved-notes', str(notes)], True)
    assert published.read_text() == body
    edit_index = next(i for i, (name, args) in enumerate(recorded) if name == 'gh' and args[:2] == ['release', 'edit'])
    assert any(name == 'spctl' for name, _ in recorded[:edit_index])
print('Release approval checks passed: default private, explicit verification, invalid notes rejected, approved text published after verification.')
