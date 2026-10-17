#!/usr/bin/env python3
"""Exact update inventory and provenance validation, shared by draft and refresh paths."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
PUBLIC_KEY = 'fuIqCE9IUmecB8Hjj44IcBz2XrVX/fMxenjhsTJIglI='

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def inventory(folder):
    return sorted(p.name for p in folder.iterdir() if p.is_file() and p.name != 'SHA256SUMS.txt')

def prepare(folder, version, build, revision, history=None):
    asset = f'WovenMatter_{version}_{build}_arm64.dmg'
    previous = [] if history is None else [int(match[1]) for p in history.glob('*.dmg')
        if (match := re.fullmatch(r'WovenMatter_' + re.escape(version) + r'_([1-9]\d*)_arm64\.dmg', p.name))]
    record = dict(schema_version=1, version=version, build=build, source_revision=revision,
                  full_asset=asset, public_ed_key=PUBLIC_KEY, supported_builds=sorted(set([*previous, build])),
                  delta_assets=sorted(p.name for p in folder.glob('*.delta')))
    (folder / 'release-build.json').write_text(json.dumps(record, indent=2) + '\n')
    (folder / 'SHA256SUMS.txt').write_text(''.join(f'{digest(folder / name)}  {name}\n' for name in inventory(folder)))
    verify(folder, version, revision)

def verify(folder, version, revision):
    record = json.loads((folder / 'release-build.json').read_text())
    build = record['build']
    assert isinstance(build, int) and not isinstance(build, bool) and build > 0
    assert record['schema_version'] == 1 and record['version'] == version
    assert record['source_revision'] == revision and re.fullmatch('[0-9a-f]{40}', revision)
    assert record['public_ed_key'] == PUBLIC_KEY
    supported = record['supported_builds']
    assert supported == sorted(set(supported)) and 1 <= len(supported) <= 6
    assert supported[-1] == build and all(isinstance(b, int) and 0 < b <= build for b in supported)
    asset = f'WovenMatter_{version}_{build}_arm64.dmg'
    assert record['full_asset'] == asset
    legacy = f'WovenMatter_{version}_arm64.dmg'
    deltas = record['delta_assets']
    assert len(deltas) == len(set(deltas))
    assert all(re.fullmatch(r'[A-Za-z0-9_.-]+\.delta', name) for name in deltas)
    expected = sorted([asset, legacy, 'latest-mac.json', 'appcast.xml', 'release-build.json', *deltas])
    assert inventory(folder) == expected, 'Unexpected release asset inventory'
    checksums = {}
    for line in (folder / 'SHA256SUMS.txt').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_.-]+)', line)
        assert match and match[2] not in checksums, 'Invalid checksum inventory'
        checksums[match[2]] = match[1]
    assert sorted(checksums) == expected, 'Incomplete checksum inventory'
    for name, sha in checksums.items():
        assert digest(folder / name) == sha, f'Checksum mismatch: {name}'
    assert checksums[asset] == checksums[legacy], 'Compatibility DMG differs from signed update'
    manifest = json.loads((folder / 'latest-mac.json').read_text())
    prefix = f'https://github.com/wovenmatter/wovenmatter/releases/download/v{version}/'
    assert manifest == dict(schema_version=1, version=version, build=build, architecture='arm64',
                           minimum_macos='26.0', download_url=prefix + legacy,
                           release_url=f'https://github.com/wovenmatter/wovenmatter/releases/tag/v{version}',
                           sha256=checksums[legacy])
    items = ET.parse(folder / 'appcast.xml').findall('./channel/item')
    assert len(items) == 1, 'Feed must contain exactly the current build'
    item = items[0]
    assert item.findtext(SPARKLE + 'version') == str(build)
    assert item.findtext(SPARKLE + 'shortVersionString') == version
    enclosures = item.findall('enclosure') + item.findall(SPARKLE + 'deltas/enclosure')
    assert sorted(e.attrib['url'].removeprefix(prefix) for e in enclosures) == sorted([asset, *deltas])
    for enclosure in enclosures:
        name = enclosure.attrib['url'].removeprefix(prefix)
        assert enclosure.attrib['url'] == prefix + name
        assert int(enclosure.attrib['length']) == (folder / name).stat().st_size
        assert enclosure.attrib.get(SPARKLE + 'edSignature'), 'Unsigned update enclosure'
    print(f'Verified update inventory: v{version} build {build} at {revision}.')
    return record

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['prepare', 'verify'])
    parser.add_argument('folder', type=Path)
    parser.add_argument('version')
    parser.add_argument('revision')
    parser.add_argument('--build', type=int)
    parser.add_argument('--history', type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('Invalid version')
    if args.mode == 'prepare':
        prepare(args.folder, args.version, args.build, args.revision, args.history)
    else:
        verify(args.folder, args.version, args.revision)
