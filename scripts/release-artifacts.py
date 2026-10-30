#!/usr/bin/env python3
"""Private local bytes for draft verification and publication.

Only bytes are retained, never a verification result. Each use reads fresh,
authenticated GitHub asset metadata, rehashes every materialized copy, and the
caller repeats all checksum, provenance, signature and Apple trust checks.
Assets with equal GitHub-reported SHA-256 and size are downloaded once.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

# A leading dot is rejected, so names can never be '.', '..' or hidden files.
NAME = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_.-]*')
REPOSITORY = re.compile(r'([A-Za-z0-9_][A-Za-z0-9_.-]*)/([A-Za-z0-9_][A-Za-z0-9_.-]*)')
SHA = re.compile(r'[0-9a-f]{40}')


def gh(*args):
    return subprocess.run(['gh', *args], check=True, capture_output=True, text=True).stdout


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def snapshot(repository, tag):
    """Current release identity and exact uploaded asset metadata."""
    view = json.loads(gh('release', 'view', tag, '--repo', repository, '--json', 'databaseId,tagName'))
    identifier = view['databaseId']
    assert type(identifier) is int and identifier > 0 and view['tagName'] == tag, 'Unexpected release identity'
    # /releases/tags does not resolve drafts; read the resolved release by ID.
    info = json.loads(gh('api', f'repos/{repository}/releases/{identifier}'))
    assert info['id'] == identifier and info['tag_name'] == tag, 'Release identity changed'
    assets = []
    for item in info['assets']:
        name = item['name']
        assert isinstance(name, str) and NAME.fullmatch(name), f'Invalid release asset name: {name!r}'
        assert item['state'] == 'uploaded', f'Incomplete release asset: {name}'
        assert type(item['id']) is int and item['id'] > 0, f'Invalid asset ID: {name}'
        assert type(item['size']) is int and item['size'] >= 0, f'Invalid asset size: {name}'
        match = re.fullmatch(r'sha256:([0-9a-f]{64})', item.get('digest') or '')
        assert match, f'GitHub reports no SHA-256 digest for {name}'
        assets.append(dict(id=item['id'], name=name, size=item['size'], sha256=match[1],
                           updated_at=item['updated_at']))
    names = [a['name'] for a in assets]
    assert len(names) == len(set(names)), 'Duplicate release asset names'
    return dict(repository=repository, tag=tag, release_id=identifier, draft=info['draft'],
                prerelease=info['prerelease'], assets=sorted(assets, key=lambda a: a['name'])), info


def private_directory(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    status = os.lstat(path)
    assert stat.S_ISDIR(status.st_mode) and status.st_uid == os.getuid(), f'Unsafe cache directory: {path}'
    path.chmod(0o700)
    return path


def scope(root, record, source):
    owner, name = REPOSITORY.fullmatch(record['repository']).groups()
    assert SHA.fullmatch(source), 'Invalid source revision'
    directory = private_directory(root)
    for part in (owner, name, f'{record["release_id"]}-{source}'):
        directory = private_directory(directory / part)
    return directory


def matches(path, asset):
    try:
        status = os.lstat(path)
    except FileNotFoundError:
        return False
    return stat.S_ISREG(status.st_mode) and status.st_size == asset['size'] and digest(path) == asset['sha256']


def clone(source, target):
    # APFS clones are copy-on-write; every copy is rehashed before use.
    if sys.platform == 'darwin' and subprocess.run(['cp', '-c', str(source), str(target)]).returncode == 0:
        return
    target.unlink(missing_ok=True)
    shutil.copyfile(source, target)


def download(repository, asset, blob):
    fd, name = tempfile.mkstemp(prefix='.partial-', dir=blob.parent)
    partial = Path(name)
    try:
        with os.fdopen(fd, 'wb') as output:
            # The immutable asset-ID endpoint, through the existing gh credential.
            # Compressed images contain ESC bytes; gh otherwise refuses to write
            # terminal escape sequences, so request its exact raw output.
            subprocess.run(['gh', 'api', '--allow-escape-sequences', '-H', 'Accept: application/octet-stream',
                            f'repos/{repository}/releases/assets/{asset["id"]}'], stdout=output, check=True)
        if not matches(partial, asset):
            raise ValueError(f'Downloaded bytes differ from GitHub metadata: {asset["name"]}')
        os.replace(partial, blob)
    finally:
        partial.unlink(missing_ok=True)


def fetch(repository, tag, source, destination, record_path, root):
    record, _ = snapshot(repository, tag)
    # Refuse a public release or a lost draft before writing or downloading bytes.
    assert record['draft'] is True, f'{tag} is not a private draft; refusing publication'
    destination.mkdir(parents=True, exist_ok=True)
    assert not any(destination.iterdir()), 'Destination must be empty'
    directory = scope(root, record, source)
    downloaded = reused = 0
    with (directory / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for leftover in directory.glob('.partial-*'):
            leftover.unlink()
        for asset in record['assets']:
            blob = directory / f'sha256-{asset["sha256"]}'
            target = destination / asset['name']
            if os.path.lexists(blob) and matches(blob, asset):
                clone(blob, target)
                if matches(target, asset):
                    reused += 1
                    continue
            # Corrupt, partial, replaced or missing bytes: discard and fetch again.
            target.unlink(missing_ok=True)
            blob.unlink(missing_ok=True)
            download(repository, asset, blob)
            downloaded += 1
            clone(blob, target)
            if not matches(target, asset):
                raise ValueError(f'Local copy differs from GitHub metadata: {asset["name"]}')
    record['source_revision'] = source
    record_path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print(f'Release assets: {downloaded} downloaded, {reused} reused from rehashed local bytes.')


def unchanged(record_path, draft):
    """Fail if the release, its draft state, or any asset changed since fetch."""
    expected = json.loads(record_path.read_text())
    current, info = snapshot(expected['repository'], expected['tag'])
    assert current['release_id'] == expected['release_id'], 'Release was replaced'
    # A replaced upload has a new ID and digest. Upload times are compared only
    # before publication, in case publishing refreshes asset timestamps.
    fields = ('id', 'name', 'size', 'sha256') + (('updated_at',) if draft else ())
    identity = lambda assets: [{k: a[k] for k in fields} for a in assets]
    assert identity(current['assets']) == identity(expected['assets']), 'Release assets changed after verification'
    assert current['prerelease'] == expected['prerelease'], 'Release prerelease state changed'
    assert current['draft'] is draft, 'Unexpected release draft state'
    return expected, info


def published(record_path, notes, root):
    expected, info = unchanged(record_path, False)
    assert info.get('published_at'), 'Release has no publication time'
    # Exact text; only GitHub's CRLF line-ending normalization is tolerated.
    newlines = lambda text: text.replace('\r\n', '\n')
    approved = notes.read_bytes().decode('utf-8')  # No universal-newline translation.
    assert newlines(info.get('body') or '') == newlines(approved), 'Published description differs from approved text'
    directory = scope(root, expected, expected['source_revision'])
    shutil.rmtree(directory)
    print('Published release matches the verified assets and approved description; local bytes removed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    command = commands.add_parser('fetch')
    command.add_argument('repository')
    command.add_argument('tag')
    command.add_argument('source')
    command.add_argument('destination', type=Path)
    command.add_argument('record', type=Path)
    command = commands.add_parser('unchanged')
    command.add_argument('record', type=Path)
    command = commands.add_parser('published')
    command.add_argument('record', type=Path)
    command.add_argument('notes', type=Path)
    args = parser.parse_args()
    root = Path(os.environ.get('WOVENMATTER_RELEASE_ARTIFACT_CACHE',
                               str(Path.home() / 'Library/Caches/WovenMatter/ReleaseArtifacts')))
    try:
        if args.command == 'fetch':
            assert REPOSITORY.fullmatch(args.repository), 'Invalid repository'
            fetch(args.repository, args.tag, args.source, args.destination, args.record, root)
        elif args.command == 'unchanged':
            unchanged(args.record, True)
        else:
            published(args.record, args.notes, root)
    except (AssertionError, ValueError, KeyError) as error:
        sys.exit(f'Release asset verification failed: {error}')
