"""Offline release publication contract: real script, stubbed external services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
STUB = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, subprocess, sys, tempfile
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['RELEASE_CALLS'], 'a') as log:
    log.write(json.dumps([name, args]) + '\n')
def payload(dest, corrupt=False):
    asset = 'WovenMatter_1.2.3_arm64.dmg'
    (dest / asset).write_bytes(b'corrupt' if corrupt else b'fixture')
    subprocess.run([os.environ['RELEASE_MANIFEST_SCRIPT'], '1.2.3', '1', str(dest / asset), str(dest / 'latest-mac.json')], check=True)
    (dest / 'SHA256SUMS.txt').write_text(''.join(hashlib.sha256((dest / n).read_bytes()).hexdigest() + '  ' + n + '\n' for n in [asset, 'latest-mac.json']))
sha = 'a' * 40
if name == 'git':
    if args[:2] == ['remote', 'get-url']:
        print('git@github-release-agent:wovenmatter/wovenmatter.git')
    elif args[0] == 'rev-parse': print(sha)
    elif args[0] == 'ls-remote': print(sha + '\trefs/tags/v1.2.3^{}')
    elif args[0] not in ('fetch', 'merge-base'): sys.exit(90)
elif name == 'gh':
    if args[0] == 'api':
        if 'user' in args: print('release-agent')
        else:
            if os.environ.get('RELEASE_METADATA_FAIL') == '1': sys.exit(1)
            metadata_calls = sum(1 for line in pathlib.Path(os.environ['RELEASE_CALLS']).read_text().splitlines() if '/releases/tags/' in line)
            offset = 100 if os.environ.get('RELEASE_NEW_ASSET_ID') == '1' or (os.environ.get('RELEASE_ASSET_DRIFT') == '1' and metadata_calls > 1) else 0
            with tempfile.TemporaryDirectory() as folder:
                dest = pathlib.Path(folder)
                payload(dest)
                assets = [dict(id=index + offset, name=path.name, size=path.stat().st_size,
                               digest=None if os.environ.get('RELEASE_MISSING_DIGEST') == '1' else 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest(),
                               updated_at='fixture', state='uploaded') for index, path in enumerate(sorted(dest.iterdir()), 1)]
                print(json.dumps(dict(id=123, tag_name='v1.2.3', draft=True, assets=assets)))
    elif args[:2] == ['run', 'list']:
        print(json.dumps([dict(headSha=sha, status='completed', conclusion='success', url='fixture')]))
    elif args[:2] == ['release', 'view']:
        published = pathlib.Path(os.environ['RELEASE_PUBLISHED']).exists()
        print(json.dumps(dict(tagName='v1.2.3', isDraft=not published, publishedAt='now' if published else None, url='fixture', assets=[dict(name=n) for n in ['SHA256SUMS.txt', 'WovenMatter_1.2.3_arm64.dmg', 'latest-mac.json']])))
    elif args[:2] == ['release', 'download']:
        dest = pathlib.Path(args[args.index('--dir') + 1])
        payload(dest, os.environ.get('RELEASE_CORRUPT_DOWNLOAD') == '1')
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
               RELEASE_CALLS=str(calls), RELEASE_PUBLISHED=str(published),
               RELEASE_MANIFEST_SCRIPT=str(ROOT / 'scripts/generate-release-manifest.sh'),
               WOVENMATTER_PUBLISH_CACHE_DIR=str(temp / 'cached-downloads'))
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
    # Second verification reuses the exact bytes, but still assesses signatures.
    recorded = run(['--verify-only'], True)
    assert not any(name == 'gh' and args[:2] == ['release', 'download'] for name, args in recorded)
    cached_dmg = next((temp / 'cached-downloads').glob('*/WovenMatter_1.2.3_arm64.dmg'))
    cached_dmg.write_bytes(b'tampered')
    recorded = run(['--verify-only'], True)
    assert any(name == 'gh' and args[:2] == ['release', 'download'] for name, args in recorded)
    env['RELEASE_NEW_ASSET_ID'] = '1'
    recorded = run(['--verify-only'], True)
    assert any(name == 'gh' and args[:2] == ['release', 'download'] for name, args in recorded)
    env.pop('RELEASE_NEW_ASSET_ID')
    env['RELEASE_MISSING_DIGEST'] = '1'
    for _ in range(2):
        recorded = run(['--verify-only'], True)
        assert any(name == 'gh' and args[:2] == ['release', 'download'] for name, args in recorded)
    env['RELEASE_CORRUPT_DOWNLOAD'] = '1'
    env.pop('RELEASE_MISSING_DIGEST')
    env['RELEASE_NEW_ASSET_ID'] = '1'
    # Force a fresh metadata identity rather than selecting a warm cache.
    for path in (temp / 'cached-downloads').glob('*/WovenMatter_1.2.3_arm64.dmg'):
        path.write_bytes(b'tampered')
    run(['--verify-only'], False)
    env.pop('RELEASE_CORRUPT_DOWNLOAD')
    env.pop('RELEASE_NEW_ASSET_ID')
    notes = temp / 'approved notes.md'
    for text in ('', '  \n', 'Signed and notarized Apple Silicon release.\n'):
        notes.write_text(text)
        assert run(['--approved-notes', str(notes)], False) == []
        assert not published.exists()
    assert run(['--approved-notes', str(temp / 'missing')], False) == []
    body = 'This release improves workspace navigation.\n\n- Find your notes faster.\n\n[Full changelog](https://github.com/wovenmatter/wovenmatter/compare/v1.2.2...v1.2.3)\n'
    notes.write_text(body)
    run(['--verify-only'], True)
    env['RELEASE_METADATA_FAIL'] = '1'
    recorded = run(['--approved-notes', str(notes)], False)
    assert not published.exists()
    assert not any(name == 'gh' and args[:2] == ['release', 'download'] for name, args in recorded)
    env.pop('RELEASE_METADATA_FAIL')
    env['RELEASE_FAIL_VERIFY'] = '1'
    run(['--approved-notes', str(notes)], False)
    assert not published.exists()
    env.pop('RELEASE_FAIL_VERIFY')
    env['RELEASE_ASSET_DRIFT'] = '1'
    run(['--approved-notes', str(notes)], False)
    assert not published.exists()
    env.pop('RELEASE_ASSET_DRIFT')
    recorded = run(['--approved-notes', str(notes)], True)
    assert published.read_text() == body
    edit_index = next(i for i, (name, args) in enumerate(recorded) if name == 'gh' and args[:2] == ['release', 'edit'])
    assert any(name == 'spctl' for name, _ in recorded[:edit_index])
    assert not any(name == 'gh' and args[:2] == ['release', 'download'] for name, args in recorded)
print('Release approval checks passed: default private, explicit verification, invalid notes rejected, approved text published after verification; exact asset reuse, tamper/replacement/missing-digest/download-corruption/drift checks.')
