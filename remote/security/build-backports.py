#!/usr/bin/env python3
"""Build reviewed patches against authenticated Debian stable sources.

Only selected runtime debs and their provenance leave this build stage. A source
update or patch mismatch fails the build and requires a maintenance review.
"""
import hashlib
import grp
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
OUT = Path('/security-output')
OUT.mkdir()
os.environ.update(DEBIAN_FRONTEND='noninteractive', DEBEMAIL='security-maintenance@wovenmatter.invalid',
                  DEBFULLNAME='Woven Matter security maintenance')
BUILD_ENV = ('env', 'HOME=/home/wm-build',
             'DEBEMAIL=security-maintenance@wovenmatter.invalid',
             'DEBFULLNAME=Woven Matter security maintenance')
BUILD_UID = pwd.getpwnam('wm-build').pw_uid
BUILD_GID = grp.getgrnam('wm-build').gr_gid


def run(*args, cwd=None, **kwargs):
    try:
        subprocess.run(args, cwd=cwd, check=True, **kwargs)
    except subprocess.CalledProcessError:
        if cwd:
            for log in sorted(Path(cwd).rglob('test-suite.log')):
                print(f'===== {log} =====', file=sys.stderr)
                print(log.read_text(errors='replace'), file=sys.stderr)
        raise


def run_build(*args, cwd=None, **kwargs):
    run('runuser', '--user', 'wm-build', '--', *BUILD_ENV, *args,
        cwd=cwd, **kwargs)


manifest = json.loads((ROOT / 'backports.json').read_text())
requested = {name for name in os.environ.get('WM_SECURITY_PACKAGES', '').split(',') if name}
available = {package['source'] for package in manifest}
if requested - available:
    raise RuntimeError('Unknown requested security source: ' + ', '.join(sorted(requested - available)))
packages = [package for package in manifest if not requested or package['source'] in requested]

for package in packages:
    name, version = package['source'], package['version']
    work = Path('/build') / name
    work.mkdir(parents=True)
    Path('/build').chmod(0o755)
    work.chmod(0o755)
    profile = ['--build-profiles=nopython'] if name == 'libxml2' else []
    run('apt-get', 'build-dep', '-y', '--no-install-recommends', *profile,
        name + '=' + version)
    # apt verifies source hashes against the signed Debian Sources index.
    shutil.chown(work, user='_apt')
    run('apt-get', 'source', name + '=' + version, cwd=work)
    source = next(p for p in work.iterdir() if p.is_dir())
    os.chown(work, BUILD_UID, BUILD_GID, follow_symlinks=False)
    for path in work.rglob('*'):
        os.chown(path, BUILD_UID, BUILD_GID, follow_symlinks=False)
    if name == 'libxml2':
        run_build('bash', str(ROOT / 'check-libxml-asan.sh'), str(source), 'vulnerable')
    for patch in package['patches']:
        path = ROOT / patch['file']
        if hashlib.sha256(path.read_bytes()).hexdigest() != patch['sha256']:
            raise RuntimeError('Patch checksum mismatch: ' + str(path))
        run_build('patch', '-p1', '--batch', '--fuzz=0', '-i', str(path), cwd=source)
    if name == 'libxml2':
        run_build('bash', str(ROOT / 'check-libxml-asan.sh'), str(source), 'fixed')
    run_build('dch', '--newversion', version + '+wmsecurity1', '--distribution', 'trixie',
              '--force-distribution', 'Reviewed upstream security backports; see backports.json.',
              cwd=source)
    build_profile = ['-Pnopython'] if name == 'libxml2' else []
    # Linux is retiring UDP-Lite. The 2.41.5 lsfd fixtures can block forever
    # when that protocol is unavailable inside Docker; 2.41.6 split those
    # cases into skippable tests. Debian's rules do not forward TS_OPTS, so
    # build with its test hook disabled and immediately run the libmount,
    # mount, and nsenter integration suites that cover the repaired privilege
    # boundaries. Runtime smoke tests cover the split debs.
    build_env = ['DEB_BUILD_OPTIONS=nocheck'] if name == 'util-linux' else []
    run_build(*build_env, 'dpkg-buildpackage', '-b', '-us', '-uc', '-j4',
              *build_profile, cwd=source)
    if name == 'util-linux':
        run_build('bash', 'tests/run.sh', f'--srcdir={source}',
                  f'--builddir={source}', '--parallel=1', '--nonroot',
                  '--show-diff', '--verbose', 'libmount', 'mount', 'nsenter',
                  cwd=source)
    for binary in package['binaries']:
        matches = list(work.glob(binary + '_*.deb'))
        if len(matches) != 1:
            raise RuntimeError('Expected one runtime package: ' + binary)
        shutil.copy2(matches[0], OUT)
    provenance = OUT / 'provenance' / name
    provenance.mkdir(parents=True)
    for pattern in ('*.dsc', '*.buildinfo', '*.changes'):
        for path in work.glob(pattern):
            shutil.copy2(path, provenance)
    # Keep the authenticated source checksum record, not unused build artifacts.
    shutil.rmtree(work)
(OUT / 'provenance' / 'backports.json').write_text(json.dumps(packages, indent=2) + '\n')
