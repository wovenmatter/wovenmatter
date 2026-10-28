#!/usr/bin/env python3
"""Verify the full-only update reconstructs exactly the same signed app."""
import argparse
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def run(*args):
    return subprocess.check_output([str(a) for a in args])


@contextmanager
def mounted_app(dmg):
    mounted = plistlib.loads(run('hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', dmg))
    entities = mounted['system-entities']
    mounts = [Path(e['mount-point']) for e in entities if 'mount-point' in e]
    devices = [e['dev-entry'] for e in entities if 'dev-entry' in e]
    try:
        apps = [app for mount in mounts for app in mount.glob('*.app')]
        if len(apps) != 1:
            raise ValueError('Expected exactly one application in update disk image')
        yield apps[0]
    finally:
        if devices:
            run('hdiutil', 'detach', devices[0])


def tree(app):
    """Compare code, resources, tickets, modes and links; ignore filesystem dates."""
    result = {}
    for path in sorted(app.rglob('*')):
        mode = path.lstat().st_mode
        relative = str(path.relative_to(app))
        if stat.S_ISLNK(mode):
            payload = os.readlink(path)
        elif stat.S_ISREG(mode):
            h = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    h.update(chunk)
            payload = h.hexdigest()
        elif stat.S_ISDIR(mode):
            payload = ''
        else:
            raise ValueError(f'Unsupported bundle member: {relative}')
        result[relative] = (stat.S_IFMT(mode), stat.S_IMODE(mode), payload)
    return result


def trust(app, notarized):
    run('codesign', '--verify', '--deep', '--strict', app)
    if notarized:
        run('xcrun', 'stapler', 'validate', app)
        run('spctl', '--assess', '--type', 'execute', app)


def verify(folder, notarized=True):
    items = ET.parse(folder / 'appcast.xml').findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected one update item')
    item = items[0]
    if item.find(SPARKLE + 'deltas') is not None or any(folder.glob('*.delta')):
        raise ValueError('Full-only release must not contain delta updates')
    name = urllib.parse.unquote(urllib.parse.urlsplit(item.find('enclosure').attrib['url']).path.rsplit('/', 1)[1])
    if Path(name).name != name or name in ('', '.', '..'):
        raise ValueError('Invalid update filename')
    with mounted_app(folder / name) as full, tempfile.TemporaryDirectory(prefix='wovenmatter-reconstruction-') as temp:
        trust(full, notarized)
        info = plistlib.loads((full / 'Contents/Info.plist').read_bytes())
        if info['CFBundleVersion'] != item.findtext(SPARKLE + 'version') or info['CFBundleShortVersionString'] != item.findtext(SPARKLE + 'shortVersionString'):
            raise ValueError('Full update version differs from feed')
        # Reconstruct the app as an installer would, preserving modes, links and tickets.
        rebuilt = Path(temp) / full.name
        run('ditto', full, rebuilt)
        trust(rebuilt, notarized)
        if tree(rebuilt) != tree(full):
            raise ValueError('Full update does not reconstruct the complete signed app')
    print('Full update reconstruction verified, with no deltas' + (', with Apple trust checks.' if notarized else ', with fixture signatures.'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    verify(args.folder)
