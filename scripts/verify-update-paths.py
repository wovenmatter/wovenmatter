#!/usr/bin/env python3
"""Verify full and delta payloads reconstruct exactly the same signed app."""
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


def verify(folder, history, tools, notarized=True):
    items = ET.parse(folder / 'appcast.xml').findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected one update item')
    item = items[0]
    def asset(enclosure):
        name = urllib.parse.unquote(urllib.parse.urlsplit(enclosure.attrib['url']).path.rsplit('/', 1)[1])
        if Path(name).name != name or name in ('', '.', '..'):
            raise ValueError('Invalid update filename')
        return folder / name
    with mounted_app(asset(item.find('enclosure'))) as full:
        trust(full, notarized)
        expected = tree(full)
        info = plistlib.loads((full / 'Contents/Info.plist').read_bytes())
        if info['CFBundleVersion'] != item.findtext(SPARKLE + 'version') or info['CFBundleShortVersionString'] != item.findtext(SPARKLE + 'shortVersionString'):
            raise ValueError('Full update version differs from feed')
        count = 0
        for enclosure in item.findall(SPARKLE + 'deltas/enclosure'):
            old = enclosure.attrib[SPARKLE + 'deltaFrom']
            if not old.isdigit() or int(old) <= 0:
                raise ValueError('Invalid delta base')
            candidates = list(history.glob(f'WovenMatter_*_{old}_arm64.dmg'))
            if len(candidates) != 1:
                raise ValueError(f'Missing or ambiguous delta base {old}')
            with mounted_app(candidates[0]) as base, tempfile.TemporaryDirectory(prefix='wovenmatter-reconstruction-') as temp:
                rebuilt = Path(temp) / full.name
                run(tools / 'bin/BinaryDelta', 'apply', base, rebuilt, asset(enclosure))
                trust(rebuilt, notarized)
                if tree(rebuilt) != expected:
                    raise ValueError(f'Delta {old} does not reconstruct the complete full-update app')
            count += 1
        print(f'Full update and {count} delta reconstruction(s) verified' + (' with Apple trust checks.' if notarized else ' with fixture signatures.'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('history', type=Path)
    parser.add_argument('tools', type=Path)
    args = parser.parse_args()
    verify(args.folder, args.history, args.tools)
