#!/usr/bin/env python3
"""Upload verified release artifacts to the private draft for that version."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('release_assets', Path(__file__).with_name('release-assets.py'))
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)
REPO = 'wovenmatter/wovenmatter'

def run(*args):
    return subprocess.check_output(args, text=True).strip()

def gh(*args):
    return run('gh', *args, '--repo', REPO)

def release(tag):
    return json.loads(gh('release', 'view', tag, '--json', 'databaseId,isDraft,assets'))

def uploaded_assets(tag):
    # /releases/tags is documented for published releases. Resolve the draft's ID.
    identifier = release(tag)['databaseId']
    assert isinstance(identifier, int) and identifier > 0
    info = json.loads(run('gh', 'api', f'repos/{REPO}/releases/{identifier}'))
    return {a['name']: a for a in info['assets']}

def verify_uploaded(tag, folder):
    uploaded = uploaded_assets(tag)
    local = {p.name: p for p in folder.iterdir() if p.is_file()}
    assert uploaded.keys() == local.keys(), 'Unexpected private draft inventory'
    for name, path in local.items():
        assert uploaded[name]['size'] == path.stat().st_size, f'Uploaded size mismatch: {name}'
        assert uploaded[name]['digest'] == 'sha256:' + assets.digest(path), f'Uploaded digest mismatch: {name}'

def main(folder, version):
    revision = run('git', 'rev-parse', 'HEAD')
    run('git', 'merge-base', '--is-ancestor', revision, 'origin/main')
    assets.verify(folder, version, revision)
    tag = 'v' + version
    assert release(tag)['isDraft'], 'Refusing to replace a public release'
    gh('release', 'upload', tag, *(str(p) for p in sorted(folder.iterdir())), '--clobber')
    verify_uploaded(tag, folder)
    print(f'Private draft {tag} holds the verified artifacts for {revision}.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('folder', type=Path)
    parser.add_argument('version')
    args = parser.parse_args()
    main(args.folder, args.version)
