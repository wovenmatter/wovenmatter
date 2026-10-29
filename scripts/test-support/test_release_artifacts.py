"""Reusable private release bytes: real publish script, offline GitHub/Apple stubs."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_assets', ROOT / 'scripts/release-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)
SHA = 'a' * 40
VERSION, BUILD = '1.2.3', 42
LEGACY, FULL = f'WovenMatter_{VERSION}_arm64.dmg', f'WovenMatter_{VERSION}_{BUILD}_arm64.dmg'
STUB = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['RELEASE_CALLS'], 'a') as log:
    log.write(json.dumps([name, args]) + '\n')
sha = 'a' * 40
state_path = pathlib.Path(os.environ['RELEASE_REMOTE'])
remote = json.loads(state_path.read_text())
if name == 'git':
    if args[:2] == ['remote', 'get-url']: print('git@github-release-agent:wovenmatter/wovenmatter.git')
    elif args[0] == 'rev-parse': print(sha)
    elif args[0] == 'ls-remote': print(sha + '\trefs/tags/v1.2.3^{}')
    elif args[0] not in ('fetch', 'merge-base'): sys.exit(90)
elif name == 'gh':
    if args == ['api', '--hostname', 'github.com', 'user', '--jq', '.login']: print('release-agent')
    elif args[:2] == ['run', 'list']:
        print(json.dumps([dict(headSha=sha, status='completed', conclusion='success', url='fixture')]))
    elif args[:2] == ['release', 'view']:
        print(json.dumps(dict(databaseId=remote['id'], tagName='v1.2.3')))
    elif args == ['api', 'repos/wovenmatter/wovenmatter/releases/%d' % remote['id']]:
        remote['metadata_calls'] += 1
        if remote['metadata_calls'] == remote.get('replace_at'):
            remote['assets'] = remote['replacement']
        state_path.write_text(json.dumps(remote))
        print(json.dumps(dict(id=remote['id'], tag_name='v1.2.3', draft=remote['draft'], prerelease=False,
                              published_at=None if remote['draft'] else 'now', body=remote['body'],
                              assets=[{k: v for k, v in a.items() if k not in ('file', 'serve')} for a in remote['assets']])))
    elif args[0] == 'api' and 'Accept: application/octet-stream' in args:
        identifier = int(args[-1].rsplit('/', 1)[1])
        item = next(a for a in remote['assets'] if a['id'] == identifier)
        payload = pathlib.Path(item.get('serve') or item['file']).read_bytes()
        # Like gh: output containing terminal escape bytes needs explicit consent.
        if b'\x1b' in payload and '--allow-escape-sequences' not in args:
            sys.exit('refusing to print terminal escape sequences')
        sys.stdout.buffer.write(payload)
    elif args[:2] == ['release', 'edit']:
        assert '--draft=false' in args
        remote['draft'] = False
        notes = pathlib.Path(args[args.index('--notes-file') + 1]).read_bytes().decode()
        remote['body'] = dict(crlf=notes.replace('\n', '\r\n'), rstrip=notes.rstrip()).get(remote.get('body_transform'), notes)
        state_path.write_text(json.dumps(remote))
    else: sys.exit(91)
elif name == 'codesign': print('Authority=Developer ID Application: Fixture')
elif name == 'spctl': print('accepted\nsource=Notarized Developer ID')
elif name not in ('xcrun', 'swift'): sys.exit(92)
'''


def release_files(folder, payload):
    """A valid full-only inventory whose two DMG names share identical bytes."""
    folder.mkdir(parents=True)
    for name in (LEGACY, FULL):
        (folder / name).write_bytes(payload)
    prefix = f'https://github.com/wovenmatter/wovenmatter/releases/download/v{VERSION}/'
    (folder / 'latest-mac.json').write_text(json.dumps(dict(
        schema_version=1, version=VERSION, build=BUILD, architecture='arm64', minimum_macos='26.0',
        download_url=prefix + LEGACY, release_url=f'https://github.com/wovenmatter/wovenmatter/releases/tag/v{VERSION}',
        sha256=hashlib.sha256(payload).hexdigest())))
    (folder / 'appcast.xml').write_text(
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
        f'<sparkle:version>{BUILD}</sparkle:version><sparkle:shortVersionString>{VERSION}</sparkle:shortVersionString>'
        f'<enclosure url="{prefix + FULL}" length="{len(payload)}" sparkle:edSignature="fixture"/>'
        '</item></channel></rss>')
    assets.prepare(folder, VERSION, BUILD, SHA)
    return folder


def metadata(folder, first_id):
    return [dict(id=first_id + index, name=path.name, state='uploaded', size=path.stat().st_size,
                 digest='sha256:' + assets.digest(path), updated_at=f't{first_id}', file=str(path))
            for index, path in enumerate(sorted(folder.iterdir()))]


with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    stubs = temp / 'bin'
    stubs.mkdir()
    for name in ('git', 'gh', 'codesign', 'spctl', 'xcrun', 'swift'):
        (stubs / name).write_text(STUB)
        (stubs / name).chmod(0o755)
    calls, state, cache = temp / 'calls', temp / 'remote.json', temp / 'cache'
    # Every byte value, including ESC, as in a compressed disk image.
    original = release_files(temp / 'original', bytes(range(256)) * 1000)
    scope = cache / 'wovenmatter/wovenmatter' / f'7-{SHA}'
    env = dict(os.environ, PATH=str(stubs) + os.pathsep + os.environ['PATH'], RELEASE_CALLS=str(calls),
               RELEASE_REMOTE=str(state), WOVENMATTER_RELEASE_ARTIFACT_CACHE=str(cache))

    def remote(**changes):
        value = dict(id=7, draft=True, body='placeholder', metadata_calls=0, assets=metadata(original, 100))
        value.update(changes)
        state.write_text(json.dumps(value))

    def publish(*options, success=True):
        calls.write_text('')
        result = subprocess.run([str(ROOT / 'scripts/publish-release.sh'), *options, 'v1.2.3', SHA],
                                env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == success, result
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        assert not any(name == 'gh' and args[:1] == ['auth'] for name, args in recorded), 'Authentication command'
        fetches = [args for name, args in recorded if name == 'gh' and 'Accept: application/octet-stream' in args]
        assert all('--allow-escape-sequences' in args for args in fetches), 'Binary output may be altered or refused'
        downloads = [int(args[-1].rsplit('/', 1)[1]) for args in fetches]
        edited = any(name == 'gh' and args[:2] == ['release', 'edit'] for name, args in recorded)
        return downloads, edited, result

    def blob(name):
        return scope / f'sha256-{assets.digest(original / name)}'

    remote()
    downloads, edited, _ = publish('--verify-only')
    # Six assets, two identical DMG names: five downloads, one shared DMG digest.
    assert len(downloads) == 5 and not edited, downloads
    assert blob(LEGACY).read_bytes() == (original / LEGACY).read_bytes(), 'Binary bytes altered'
    assert oct(scope.stat().st_mode & 0o777) == '0o700'
    assert publish('--verify-only')[0] == [], 'Verified bytes were downloaded again'

    # Corrupt, truncated and symlinked bytes are discarded and fetched again.
    for damage in ('corrupt', 'truncated', 'symlink'):
        path = blob(LEGACY)
        content = path.read_bytes()
        path.unlink()
        if damage == 'corrupt':
            path.write_bytes(b'x' * len(content))
        elif damage == 'truncated':
            path.write_bytes(content[:len(content) // 2])
        else:
            decoy = temp / 'decoy'
            decoy.write_bytes(content)
            path.symlink_to(decoy)
        (scope / '.partial-interrupted').write_bytes(content[:10])
        downloads, _, _ = publish('--verify-only')
        assert len(downloads) == 1, (damage, downloads)
        assert not path.is_symlink() and path.read_bytes() == content
        assert not list(scope.glob('.partial-*'))

    # Replaced remote assets are fetched by their new IDs and digests; the shared
    # DMG once, and only the unchanged release-build.json bytes are reused.
    replacement = release_files(temp / 'replacement', b'rebuilt signed disk image' * 1000)
    remote(assets=metadata(replacement, 200))
    downloads, _, _ = publish('--verify-only')
    assert downloads == [200, 201, 203, 204], downloads

    # Served bytes that differ from GitHub's digest are never retained or used.
    tampered = metadata(original, 300)
    for item in tampered:
        if item['name'] == FULL:
            (temp / 'tampered').write_bytes(b'tampered')
            item['serve'] = str(temp / 'tampered')
    remote(assets=tampered)
    for path in scope.glob('sha256-*'):
        path.unlink()
    _, edited, result = publish('--approved-notes', str(original / 'appcast.xml'), success=False)
    assert not edited and 'differ from GitHub metadata' in result.stderr, result.stderr
    assert not list(scope.glob('.partial-*')) and not blob(LEGACY).exists()

    # Malformed or incomplete inventories stop before any download or publication.
    for change in (dict(name='../escape'), dict(name='.hidden'), dict(name='a/b'), dict(state='starter'),
                   dict(digest=None), dict(digest='sha1:' + 'a' * 40), dict(size=-1)):
        broken = metadata(original, 400)
        broken[0].update(change)
        remote(assets=broken)
        downloads, edited, _ = publish('--verify-only', success=False)
        assert downloads == [] and not edited, change
    duplicate = metadata(original, 500)
    duplicate[1]['name'] = duplicate[0]['name']
    remote(assets=duplicate)
    assert publish('--verify-only', success=False)[:2] == ([], False)
    # A public release is refused before any asset download, in both modes.
    for options in (['--verify-only'], ['--approved-notes', str(original / 'appcast.xml')]):
        for path in scope.glob('sha256-*'):
            path.unlink()
        remote(draft=False)
        downloads, edited, result = publish(*options, success=False)
        assert downloads == [] and not edited and 'not a private draft' in result.stderr, result.stderr

    # Replacement while downloading or verifying fails verification itself, and
    # replacement immediately before publication is refused.
    for options in (['--verify-only'], ['--approved-notes', str(original / 'appcast.xml')]):
        remote(replace_at=2, replacement=metadata(replacement, 600))
        _, edited, result = publish(*options, success=False)
        assert not edited and 'changed after verification' in result.stderr, (options, result.stderr)
        assert 'Verified private release' not in result.stdout

    # The approved text is compared exactly, including meaningful trailing spaces
    # (a Markdown line break); only CRLF line endings are tolerated.
    notes = temp / 'notes.md'
    notes.write_bytes(b'This release makes notes easier to find.  \nOn two lines.\n\n- Faster search.\n')
    remote(body_transform='rstrip')
    _, edited, result = publish('--approved-notes', str(notes), success=False)
    assert edited and 'differs from approved text' in result.stderr, result.stderr
    assert scope.exists(), 'Bytes removed before confirming publication'
    # Assets changed after publication are reported, not hidden.
    remote(replace_at=3, replacement=metadata(replacement, 700))
    _, edited, result = publish('--approved-notes', str(notes), success=False)
    assert edited and 'changed after verification' in result.stderr, result.stderr
    remote(body_transform='crlf')
    downloads, edited, result = publish('--approved-notes', str(notes))
    assert edited and downloads == [] and json.loads(state.read_text())['body'] == notes.read_text().replace('\n', '\r\n')
    assert not scope.exists(), 'Published release bytes retained'
    remote()
    publish('--approved-notes', str(notes))
    assert json.loads(state.read_text())['body'].encode() == notes.read_bytes()
print('Release artifact cache: shared digest single download, verified reuse, corrupt/partial/symlink recovery, '
      'remote replacement and tampering, malformed inventories, pre-publication change refusal and approved-body readback passed.')
