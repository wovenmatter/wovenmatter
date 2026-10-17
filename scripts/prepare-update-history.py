#!/usr/bin/env python3
"""Fetch at most five previously published Sparkle builds, never draft artifacts."""
import json
from pathlib import Path
import re
import subprocess
import sys

REPO = 'wovenmatter/wovenmatter'
def gh(*args):
    return subprocess.check_output(['gh', *args, '--repo', REPO], text=True)

def main(folder):
    folder.mkdir(parents=True, exist_ok=True)
    releases = json.loads(gh('release', 'list', '--exclude-drafts', '--exclude-pre-releases', '--limit', '6', '--json', 'tagName,isDraft,isPrerelease'))
    count = 0
    for release in releases:
        if release['isDraft'] or release['isPrerelease']:
            continue
        tag = release['tagName']
        if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
            continue
        info = json.loads(gh('release', 'view', tag, '--json', 'assets'))
        names = {a['name'] for a in info['assets']}
        if 'release-build.json' not in names:
            continue  # The original updater cannot consume deltas.
        record = json.loads(gh('release', 'download', tag, '--pattern', 'release-build.json', '--output', '-'))
        version = record['version']
        if not re.fullmatch(r'\d+\.\d+\.\d+', version):
            raise ValueError('Invalid published update version')
        builds = sorted(set(record.get('supported_builds', [record['build']])), reverse=True)
        for build in builds:
            if not isinstance(build, int) or build <= 0:
                raise ValueError('Invalid published update build')
            asset = f'WovenMatter_{version}_{build}_arm64.dmg'
            if asset not in names:
                raise ValueError('Published delta base is missing')
            gh('release', 'download', tag, '--pattern', asset, '--dir', str(folder))
            count += 1
            if count == 5:
                break
        if count == 5:
            break
    print(f'Prepared {count} published delta base(s).')

if __name__ == '__main__':
    main(Path(sys.argv[1]))
