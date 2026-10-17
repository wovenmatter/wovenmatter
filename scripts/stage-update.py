#!/usr/bin/env python3
"""Stage verified artifacts privately; explicitly requested refreshes promote to an existing release.

Never moves a version tag, edits release notes, or publishes a new release.
Immutable build assets precede the legacy alias; the signed feed is committed last.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.parse
import importlib.util

spec = importlib.util.spec_from_file_location('release_assets', Path(__file__).with_name('release-assets.py'))
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)
REPO = 'wovenmatter/wovenmatter'

def run(*args):
    return subprocess.check_output(args, text=True).strip()

def gh(*args):
    return run('gh', *args, '--repo', REPO)

def release(tag):
    return json.loads(gh('release', 'view', tag, '--json', 'tagName,isDraft,isPrerelease,body,assets'))

def upload(tag, files, clobber=False):
    gh('release', 'upload', tag, *(str(p) for p in files), *(['--clobber'] if clobber else []))

def verify_uploaded(tag, folder, exact=False):
    info = json.loads(run('gh', 'api', f'repos/{REPO}/releases/tags/{urllib.parse.quote(tag, safe="")}'))
    uploaded = {a['name']: a for a in info['assets']}
    local = {p.name: p for p in folder.iterdir() if p.is_file()}
    if exact:
        assert uploaded.keys() == local.keys(), 'Unexpected private draft inventory'
    for name, path in local.items():
        assert uploaded[name]['size'] == path.stat().st_size, f'Uploaded size mismatch: {name}'
        assert uploaded[name]['digest'] == 'sha256:' + assets.digest(path), f'Uploaded digest mismatch: {name}'

def main(folder, version, refresh):
    revision = run('git', 'rev-parse', 'HEAD')
    run('git', 'merge-base', '--is-ancestor', revision, 'origin/main')
    record = assets.verify(folder, version, revision)
    build = record['build']
    target = 'v' + version
    if not refresh:
        draft = release(target)
        assert draft['isDraft'], 'Refusing to replace a public tagged release'
        upload(target, sorted(folder.iterdir()), clobber=True)
        verify_uploaded(target, folder, exact=True)
        print(f'Verified private draft {target}; description approval is required before publication.')
        return

    assert run('git', 'branch', '--show-current') in ('main', ''), 'Refresh must run from accepted main'
    original = release(target)
    assert not original['isDraft'] and not original['isPrerelease']
    assert json.loads(run('gh', 'api', f'repos/{REPO}/releases/latest'))['tag_name'] == target, 'Cannot refresh an older release'
    original_tag = run('git', 'rev-parse', target + '^{commit}')
    legacy = f'WovenMatter_{version}_arm64.dmg'
    published_names = {a['name'] for a in original['assets']}
    # A retry after a successful refresh is a read-only success, never a downgrade.
    if 'release-build.json' in published_names:
        current = json.loads(gh('release', 'download', target, '--pattern', 'release-build.json', '--output', '-'))
        assert current['build'] <= build, 'Refusing to replace a newer build'
        if current['build'] == build:
            assert current['source_revision'] == revision
            verify_uploaded(target, folder)
            print('This exact update build is already public.')
            return

    # Each refresh has a separate immutable source tag and a verified private draft.
    staging_tag = f'v{version}-build{build}'
    staged_sha = run('git', 'rev-parse', staging_tag + '^{commit}')
    assert staged_sha == revision, 'Immutable update source tag differs'
    try:
        draft = release(staging_tag)
        assert draft['isDraft']
    except subprocess.CalledProcessError:
        gh('release', 'create', staging_tag, '--draft', '--title', f'Private v{version} build {build}',
           '--notes', f'Artifact verification and rollback record for accepted main {revision}.')
    upload(staging_tag, sorted(folder.iterdir()), clobber=True)
    verify_uploaded(staging_tag, folder, exact=True)

    mutable = [legacy, 'SHA256SUMS.txt', 'release-build.json', 'latest-mac.json', 'appcast.xml']
    with tempfile.TemporaryDirectory(prefix='wovenmatter-update-rollback-') as temporary:
        backup = Path(temporary)
        for name in mutable:
            if name in published_names:
                gh('release', 'download', target, '--pattern', name, '--dir', str(backup))
        old_manifest = json.loads((backup / 'latest-mac.json').read_text())
        assert old_manifest['version'] == version and old_manifest['build'] < build
        assert assets.digest(backup / legacy) == old_manifest['sha256']
        # Preserve the original downloadable build before touching its compatibility alias.
        prior_asset = f'WovenMatter_{version}_{old_manifest["build"]}_arm64.dmg'
        if prior_asset not in published_names:
            shutil.copyfile(backup / legacy, backup / prior_asset)
            upload(target, [backup / prior_asset])
        immutable = [p for p in folder.iterdir() if p.name not in mutable]
        for path in immutable:
            if path.name not in published_names:
                upload(target, [path])
            else:
                # No --clobber for immutable names, even on a retry.
                with tempfile.TemporaryDirectory() as check:
                    shutil.copyfile(path, Path(check) / path.name)
                    verify_uploaded(target, Path(check))
        # Recheck just before promotion. All workflows share one publication lock.
        assert release(target)['body'] == original['body'], 'Release description changed during preparation'
        assert json.loads(run('gh', 'api', f'repos/{REPO}/releases/latest'))['tag_name'] == target
        try:
            for name in mutable:
                upload(target, [folder / name], clobber=True)
            verify_uploaded(target, folder)
            for name in ('latest-mac.json', 'appcast.xml'):
                remote = backup / ('verify-' + name)
                gh('release', 'download', target, '--pattern', name, '--output', str(remote))
                assert assets.digest(remote) == assets.digest(folder / name)
            assert run('git', 'rev-parse', target + '^{commit}') == original_tag
            assert release(target)['body'] == original['body']
        except BaseException as failure:
            # Try every restoration even if the service rejects an individual request.
            restoration_errors = []
            for name in mutable:
                try:
                    if (backup / name).exists():
                        upload(target, [backup / name], clobber=True)
                    elif name in {a['name'] for a in release(target)['assets']}:
                        gh('release', 'delete-asset', target, name, '--yes')
                except Exception as error:
                    restoration_errors.append(f"{name}: {error}")
            if restoration_errors:
                raise RuntimeError(f"Promotion failed; restore from private draft {staging_tag}. "
                                   + "; ".join(restoration_errors)) from failure
            raise
    print(f'Published verified v{version} build {build}; original version tag and approved notes preserved.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('folder', type=Path)
    parser.add_argument('version')
    parser.add_argument('--refresh', action='store_true')
    args = parser.parse_args()
    main(args.folder, args.version, args.refresh)
