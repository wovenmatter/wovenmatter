#!/usr/bin/env python3
"""Private verification, durable recovery, and feed-last same-version delivery.

No version tag moves, description edits, or new public releases. Retries reuse
original verified artifacts; signing/notarization/DMG bytes are not reproducible.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location('release_assets', Path(__file__).with_name('release-assets.py'))
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)
REPO = 'wovenmatter/wovenmatter'
READY = 'staging-ready.json'
ROLLBACK = 'rollback-index.json'

def run(*args):
    return subprocess.check_output(args, text=True).strip()

def gh(*args):
    return run('gh', *args, '--repo', REPO)

def release(tag):
    command = ['gh', 'release', 'view', tag, '--json', 'databaseId,tagName,isDraft,isPrerelease,body,assets', '--repo', REPO]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise subprocess.CalledProcessError(result.returncode, command, result.stdout, result.stderr)
    return json.loads(result.stdout)

def optional_release(tag):
    try:
        return release(tag)
    except subprocess.CalledProcessError as error:
        # Only gh's explicit missing-release result permits creating a draft. A
        # network/auth/rate-limit failure must not create a duplicate release.
        if error.returncode == 1 and (error.stderr or '').strip() == 'release not found':
            return None
        raise

def upload(tag, files, clobber=False):
    gh('release', 'upload', tag, *(str(p) for p in files), *(['--clobber'] if clobber else []))

def download(tag, name, destination):
    gh('release', 'download', tag, '--pattern', name, '--output', str(destination))

def uploaded_assets(tag):
    # /releases/tags is documented for published releases. Resolve the draft's ID.
    identifier = release(tag)['databaseId']
    assert isinstance(identifier, int) and identifier > 0
    info = json.loads(run('gh', 'api', f'repos/{REPO}/releases/{identifier}'))
    return {a['name']: a for a in info['assets']}

def failed_upload(item):
    # GitHub can leave an empty starter after an upload transport failure. This
    # is not a published immutable artifact; never replace a completed upload.
    return bool(item and item.get('state') == 'starter' and item['size'] == 0 and not item.get('digest'))

def discard_failed_upload(tag, name):
    if failed_upload(uploaded_assets(tag).get(name)):
        gh('release', 'delete-asset', tag, name, '--yes')
        return True
    return False

def verify_uploaded(tag, folder, exact=False):
    uploaded = uploaded_assets(tag)
    local = {p.name: p for p in folder.iterdir() if p.is_file()}
    if exact:
        assert uploaded.keys() == local.keys(), 'Unexpected private draft inventory'
    for name, path in local.items():
        assert uploaded[name]['size'] == path.stat().st_size, f'Uploaded size mismatch: {name}'
        assert uploaded[name]['digest'] == 'sha256:' + assets.digest(path), f'Uploaded digest mismatch: {name}'

def describe(path, tag=None, asset=None):
    record = dict(sha256=assets.digest(path), size=path.stat().st_size)
    if tag is not None:
        record.update(tag=tag, asset=asset)
    return record

def check_file(path, record):
    assert path.stat().st_size == record['size'] and assets.digest(path) == record['sha256'], f'Invalid retained artifact: {path.name}'

def validate_reused(folder, version, revision, build):
    record = assets.verify(folder, version, revision)
    assert record['build'] == build
    run('swift', str(Path(__file__).with_name('verify-update-signatures.swift')), str(folder))
    tools = Path(run(str(Path(__file__).with_name('prepare-sparkle-tools.sh'))))
    run(str(tools / 'bin/sign_update'), '--verify', '--ed-key-file', os.environ['WOVENMATTER_SPARKLE_PRIVATE_KEY'], str(folder / 'appcast.xml'))
    # An authenticated ready record preserves the initial notarized build; repeat
    # independent public-key and Developer ID/notarization checks before reuse.
    dmg = str(folder / record['full_asset'])
    run('codesign', '--verify', '--strict', dmg)
    run('xcrun', 'stapler', 'validate', dmg)
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', dmg)

def restore_tagged(folder, version, revision, build):
    """Resume an ordinary private tag's complete artifacts without rebuilding."""
    tag = 'v' + version
    private = optional_release(tag)
    if private is None:
        return False
    assert private['isDraft'], 'Tagged release is already public; refusing to rebuild'
    uploaded = uploaded_assets(tag)
    assert all(item.get('state') == 'uploaded' or failed_upload(item) for item in uploaded.values()), 'Invalid private upload state'
    names = set(uploaded)
    complete = {name for name, item in uploaded.items() if not failed_upload(item)}
    if not {'SHA256SUMS.txt', 'release-build.json'}.issubset(complete):
        return False
    with tempfile.TemporaryDirectory() as temporary:
        index = Path(temporary)
        download(tag, 'SHA256SUMS.txt', index / 'SHA256SUMS.txt')
        download(tag, 'release-build.json', index / 'release-build.json')
        verify_uploaded(tag, index)
        record = json.loads((index / 'release-build.json').read_text())
        assert record['source_revision'] == revision and record['version'] == version and record['build'] == build
        expected = {'SHA256SUMS.txt'}
        for line in (index / 'SHA256SUMS.txt').read_text().splitlines():
            match = re.fullmatch(r'[0-9a-f]{64}  ([A-Za-z0-9_.-]+)', line)
            assert match, 'Invalid retained checksum inventory'
            assert match[1] not in expected, 'Duplicate retained asset'
            expected.add(match[1])
        if not expected.issubset(complete):
            return False  # Interrupted upload, never a complete signed release.
        assert expected == names, 'Unexpected assets on private tagged release'
    folder.mkdir(parents=True, exist_ok=True)
    for name in sorted(expected):
        download(tag, name, folder / name)
    validate_reused(folder, version, revision, build)
    verify_uploaded(tag, folder, exact=True)
    return True


def restore_staged(folder, version, revision, build):
    tag = f'v{version}-build{build}'
    private = optional_release(tag)
    if private is None:
        return False
    assert private['isDraft'], 'Update verification release must remain private'
    names = {a['name'] for a in private['assets']}
    if READY in names and discard_failed_upload(tag, READY):
        names.remove(READY)
    if READY not in names:
        # An interrupted initial upload can be rebuilt only before any promotion.
        public_names = {a['name'] for a in release('v' + version)['assets']}
        assert ROLLBACK not in names and f'WovenMatter_{version}_{build}_arm64.dmg' not in public_names, 'Incomplete staging record requires recovery'
        return False
    folder.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        index = Path(temporary) / READY
        download(tag, READY, index)
        verify_uploaded(tag, index.parent)
        ready = json.loads(index.read_text())
    assert ready['version'] == version and ready['build'] == build and ready['source_revision'] == revision
    for name, record in ready['files'].items():
        assert re.fullmatch(r'[A-Za-z0-9_.-]+', name) and name not in (READY, ROLLBACK)
        destination = folder / name
        download(tag, name, destination)
        check_file(destination, record)
    validate_reused(folder, version, revision, build)
    verify_uploaded(tag, folder)
    return True

def prepare_private(folder, version, revision, build):
    tag = f'v{version}-build{build}'
    private = optional_release(tag)
    if private is None:
        gh('release', 'create', tag, '--draft', '--title', f'Private v{version} build {build}',
           '--notes', f'Artifact verification and recovery record for accepted main {revision}.')
    else:
        assert private['isDraft']
        assert not any(a['name'] in (READY, ROLLBACK) for a in private['assets'])
        # Only incomplete, unreferenced initial staging may be replaced.
        assert f'WovenMatter_{version}_{build}_arm64.dmg' not in {a['name'] for a in release('v' + version)['assets']}
        for asset in private['assets']:
            gh('release', 'delete-asset', tag, asset['name'], '--yes')
    upload(tag, sorted(folder.iterdir()))
    verify_uploaded(tag, folder, exact=True)
    with tempfile.TemporaryDirectory() as temporary:
        index = Path(temporary) / READY
        index.write_text(json.dumps(dict(version=version, build=build, source_revision=revision,
            files={p.name: describe(p) for p in folder.iterdir() if p.is_file()}), indent=2))
        upload(tag, [index])
        verify_uploaded(tag, index.parent)

def load_rollback(tag, target, folder, mutable):
    if ROLLBACK not in {a['name'] for a in release(tag)['assets']}:
        return None
    if discard_failed_upload(tag, ROLLBACK):
        return None
    index = folder / ROLLBACK
    download(tag, ROLLBACK, index)
    with tempfile.TemporaryDirectory() as temporary:
        shutil.copyfile(index, Path(temporary) / ROLLBACK)
        verify_uploaded(tag, Path(temporary))
    snapshot = json.loads(index.read_text())
    assert snapshot['target'] == target
    assert set(snapshot['files']).issubset(mutable)
    assert mutable[0] in snapshot['files'] and 'latest-mac.json' in snapshot['files']
    for name, record in snapshot['files'].items():
        assert record['tag'] in (tag, target)
        assert re.fullmatch(r'[A-Za-z0-9_.-]+', record['asset'])
        download(record['tag'], record['asset'], folder / name)
        check_file(folder / name, record)
    return snapshot

def prepare_rollback(tag, target, original, folder, mutable, version, build):
    snapshot = load_rollback(tag, target, folder, mutable)
    if snapshot is not None:
        return snapshot
    names = {a['name'] for a in original['assets']}
    for name in mutable:
        if name in names:
            download(target, name, folder / name)
    old = json.loads((folder / 'latest-mac.json').read_text())
    assert old['version'] == version and old['build'] < build
    assert assets.digest(folder / mutable[0]) == old['sha256']
    prior = f'WovenMatter_{version}_{old["build"]}_arm64.dmg'
    snapshot = dict(target=target, original_tag=run('git', 'rev-parse', target + '^{commit}'),
                    notes_sha256=hashlib.sha256(original['body'].encode()).hexdigest(), files={})
    for name in mutable:
        source = folder / name
        if not source.exists():
            continue
        with tempfile.TemporaryDirectory() as temporary:
            if name == mutable[0]:
                # The large prior app is retained once under a public immutable URL.
                destination = Path(temporary) / prior
                shutil.copyfile(source, destination)
                if prior not in names or discard_failed_upload(target, prior):
                    upload(target, [destination])
                verify_uploaded(target, Path(temporary))
                snapshot['files'][name] = describe(source, target, prior)
            else:
                destination = Path(temporary) / ('rollback-' + name)
                shutil.copyfile(source, destination)
                upload(tag, [destination], clobber=True)
                verify_uploaded(tag, Path(temporary))
                snapshot['files'][name] = describe(source, tag, destination.name)
    # Commit the durable rollback snapshot before touching any current alias/feed.
    index = folder / ROLLBACK
    index.write_text(json.dumps(snapshot, indent=2))
    upload(tag, [index])
    with tempfile.TemporaryDirectory() as temporary:
        shutil.copyfile(index, Path(temporary) / ROLLBACK)
        verify_uploaded(tag, Path(temporary))
    return snapshot

def promote(folder, version, revision, record):
    build = record['build']
    target, tag = 'v' + version, f'v{version}-build{build}'
    original = release(target)
    assert not original['isDraft'] and not original['isPrerelease']
    assert json.loads(run('gh', 'api', f'repos/{REPO}/releases/latest'))['tag_name'] == target
    names = {a['name'] for a in original['assets']}
    if 'release-build.json' in names:
        current = json.loads(gh('release', 'download', target, '--pattern', 'release-build.json', '--output', '-'))
        assert current['build'] <= build, 'Refusing to replace a newer build'
        if current['build'] == build:
            assert current['source_revision'] == revision
            try:
                verify_uploaded(target, folder)
            except (AssertionError, KeyError):
                pass  # Interrupted promotion: resume, do not treat metadata as commit.
            else:
                print('This exact verified update build is already public.')
                return
    mutable = [f'WovenMatter_{version}_arm64.dmg', 'SHA256SUMS.txt', 'latest-mac.json', 'release-build.json', 'appcast.xml']
    with tempfile.TemporaryDirectory(prefix='wovenmatter-update-rollback-') as temporary:
        backup = Path(temporary)
        snapshot = prepare_rollback(tag, target, original, backup, mutable, version, build)
        assert run('git', 'rev-parse', target + '^{commit}') == snapshot['original_tag']
        assert hashlib.sha256(release(target)['body'].encode()).hexdigest() == snapshot['notes_sha256']
        for path in folder.iterdir():
            if path.name in mutable:
                continue
            if path.name not in names or discard_failed_upload(target, path.name):
                upload(target, [path])
            else:
                with tempfile.TemporaryDirectory() as check:
                    shutil.copyfile(path, Path(check) / path.name)
                    verify_uploaded(target, Path(check))
        assert json.loads(run('gh', 'api', f'repos/{REPO}/releases/latest'))['tag_name'] == target
        try:
            for name in mutable:
                upload(target, [folder / name], clobber=True)
            verify_uploaded(target, folder)
            for name in ('latest-mac.json', 'appcast.xml'):
                destination = backup / ('verify-' + name)
                download(target, name, destination)
                assert assets.digest(destination) == assets.digest(folder / name)
            assert run('git', 'rev-parse', target + '^{commit}') == snapshot['original_tag']
            assert hashlib.sha256(release(target)['body'].encode()).hexdigest() == snapshot['notes_sha256']
        except BaseException as failure:
            errors = []
            for name in mutable:
                try:
                    if name in snapshot['files']:
                        upload(target, [backup / name], clobber=True)
                    elif name in {a['name'] for a in release(target)['assets']}:
                        gh('release', 'delete-asset', target, name, '--yes')
                except Exception as error:
                    errors.append(f'{name}: {error}')
            if errors:
                raise RuntimeError(f'Promotion failed; durable recovery snapshot is in private draft {tag}: {ROLLBACK}. ' + '; '.join(errors)) from failure
            raise
    print(f'Published verified v{version} build {build}; original version tag and approved notes preserved.')

def main(folder, version, refresh):
    revision = run('git', 'rev-parse', 'HEAD')
    run('git', 'merge-base', '--is-ancestor', revision, 'origin/main')
    record = assets.verify(folder, version, revision)
    if not refresh:
        assert release('v' + version)['isDraft'], 'Refusing to replace a public tagged release'
        upload('v' + version, sorted(folder.iterdir()), clobber=True)
        verify_uploaded('v' + version, folder, exact=True)
        return
    build = record['build']
    assert run('git', 'branch', '--show-current') in ('main', '')
    assert run('git', 'rev-parse', f'v{version}-build{build}' + '^{commit}') == revision
    with tempfile.TemporaryDirectory(prefix='wovenmatter-reuse-update-') as temporary:
        retained = Path(temporary)
        if restore_staged(retained, version, revision, build):
            folder = retained
            record = assets.verify(folder, version, revision)
        else:
            prepare_private(folder, version, revision, build)
        promote(folder, version, revision, record)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('folder', type=Path)
    parser.add_argument('version')
    parser.add_argument('--refresh', action='store_true')
    parser.add_argument('--restore-staged', action='store_true')
    parser.add_argument('--restore-tagged', action='store_true')
    args = parser.parse_args()
    if args.restore_staged or args.restore_tagged:
        revision = run('git', 'rev-parse', 'HEAD')
        build = int(run('git', 'rev-list', '--count', 'HEAD'))
        restore = restore_tagged if args.restore_tagged else restore_staged
        raise SystemExit(0 if restore(args.folder, args.version, revision, build) else 3)
    main(args.folder, args.version, args.refresh)
