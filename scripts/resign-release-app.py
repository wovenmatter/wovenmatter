#!/usr/bin/env python3
"""Replace the ad-hoc signatures of an app compiled on a maintainer Mac with
Developer ID, innermost code first, keeping each item's identifier and
entitlements. Code that already carries a vendor's Developer ID signature is
left untouched, as is Sparkle (sign-release-updater.sh signs it and the app).

--check-entitlements confirms the signed app kept the entitlements its sources
declare, so a lost JIT or virtualization entitlement fails before notarization.
"""
import os
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MAGIC = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
BUNDLES = ('.app', '.framework', '.xpc', '.appex', '.bundle', '.plugin')
SPARKLE = Path('Contents/Frameworks/Sparkle.framework')

def macho(path):
    with path.open('rb') as source:
        return source.read(4) in MAGIC

def needs_signature(path):
    result = subprocess.run(['codesign', '-dvv', str(path)], capture_output=True, text=True)
    details = result.stdout + result.stderr
    return result.returncode != 0 or 'Signature=adhoc' in details

def code_items(app):
    items = []
    for directory, folders, files in os.walk(app):  # never follows symlinks
        here = Path(directory)
        for name in folders:
            path = here / name
            if name.endswith(BUNDLES) and not path.is_symlink():
                items.append(path)
        for name in files:
            path = here / name
            if not path.is_symlink() and macho(path):
                items.append(path)
    inside = lambda path: path.relative_to(app)
    items = [p for p in items if p != app and SPARKLE not in (inside(p), *inside(p).parents)]
    # Deepest first: nested code is sealed before anything that contains it.
    return sorted(items, key=lambda p: (-len(inside(p).parts), str(p)))

def resign(app, identity):
    signed = 0
    for path in code_items(app):
        if not needs_signature(path):
            continue
        subprocess.run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp',
                        '--preserve-metadata=identifier,entitlements', str(path)], check=True)
        signed += 1
    print(f'Re-signed {signed} ad-hoc code items with {identity}.')

def entitlements(path):
    result = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(path)],
                            capture_output=True, check=True)
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}

def check(app):
    product = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
    expected = {
        app: 'app/App/WovenMatter.entitlements',
        app / 'Contents/Resources/default-agent/bin/node': 'default-agent/node-entitlements.plist',
    }
    for suffix in ('', ' (GPU)', ' (Renderer)', ' (Plugin)', ' (Alerts)'):
        expected[app / f'Contents/Frameworks/{product} Helper{suffix}.app'] = 'app/Browser/Helper.entitlements'
    vm_helper = app / 'Contents/Helpers/WovenMatterVMHelper'
    if vm_helper.exists():
        expected[vm_helper] = 'app/VMHelper/WovenMatterVMHelper.entitlements'
    failures = []
    for path, source in expected.items():
        declared = plistlib.loads((ROOT / source).read_bytes())
        if not path.exists():
            failures.append(f'{path.relative_to(app.parent)}: missing')
        elif entitlements(path) != declared:
            failures.append(f'{path.relative_to(app.parent)}: entitlements differ from {source}')
    if failures:
        raise SystemExit('Release entitlement check failed:\n' + '\n'.join(failures))
    print(f'Entitlements match their sources for {len(expected)} signed items.')

if __name__ == '__main__':
    arguments = sys.argv[1:]
    if len(arguments) == 2 and arguments[0] == '--check-entitlements':
        check(Path(arguments[1]))
    elif len(arguments) == 2 and not arguments[0].startswith('-'):
        resign(Path(arguments[0]), arguments[1])
    else:
        raise SystemExit('usage: resign-release-app.py APP IDENTITY | --check-entitlements APP')
