#!/usr/bin/env python3
"""Reuse only unsigned browser products from the trusted main cache producer."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ('libWovenBrowser.a', 'libcef_dll_wrapper/libcef_dll_wrapper.a', 'WovenBrowserHelper')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def key(architecture, cmake):
    h = hashlib.sha256()
    for path in sorted((ROOT / 'app/Browser').rglob('*')):
        if path.is_file():
            h.update(str(path.relative_to(ROOT)).encode() + b'\0' + path.read_bytes())
    for name in ('scripts/prepare-browser.sh', 'scripts/browser-build-cache.py'):
        h.update((ROOT / name).read_bytes())
    for command in (['xcodebuild', '-version'], ['xcrun', '--sdk', 'macosx', '--show-sdk-version'],
                    ['xcrun', 'clang', '--version'], [cmake, '--version']):
        h.update(subprocess.check_output(command))
    for variable in ('CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET'):
        h.update(variable.encode() + b'=' + os.environ.get(variable, '').encode())
    h.update(architecture.encode())
    return h.hexdigest()


def transfer(mode, entry, build):
    if mode == 'restore':
        try:
            manifest = json.loads((entry / 'manifest.json').read_text())
            if set(manifest) != set(PRODUCTS):
                return False
            for name in PRODUCTS:
                path = entry / name
                if path.is_symlink() or not path.is_file() or digest(path) != manifest[name]:
                    return False
            for name in PRODUCTS:
                target = build / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(entry / name, target)
            return True
        except (OSError, ValueError):
            return False
    if os.environ.get('WOVENMATTER_WRITE_BROWSER_CACHE') != '1':
        return True
    # Never save a signed helper or an assembled app; preparation signs copies.
    entry.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name in PRODUCTS:
        target = entry / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(build / name, target)
        manifest[name] = digest(target)
    (entry / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True))
    return True


if __name__ == '__main__':
    if sys.argv[1] == 'key':
        print(key(sys.argv[2], sys.argv[3]))
    else:
        sys.exit(0 if transfer(sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])) else 1)
