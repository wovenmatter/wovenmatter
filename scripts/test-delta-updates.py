#!/usr/bin/env python3
"""A real same-version delta round trip, with no provider, Apple, or production access."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('assets', ROOT / 'scripts/release-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)

def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()

def fails(action):
    try:
        action()
    except (AssertionError, ValueError, subprocess.CalledProcessError):
        return
    raise AssertionError('Invalid update was accepted')

with tempfile.TemporaryDirectory(prefix='wovenmatter-delta-test-') as temp:
    root = Path(temp)
    archives, output = root / 'archives', root / 'output'
    archives.mkdir()
    output.mkdir()
    tools = Path(os.environ.get('WOVENMATTER_TEST_SPARKLE_TOOLS') or run(ROOT / 'scripts/prepare-sparkle-tools.sh'))
    # A temporary signing identity, unrelated to the production release key.
    keyfile = root / 'key'
    public = run('swift', '-e', 'import Foundation; import CryptoKit; let k = Curve25519.Signing.PrivateKey(); try k.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8); print(k.publicKey.rawRepresentation.base64EncodedString())', keyfile)
    base = root / 'base/Woven Matter.app'
    (base / 'Contents/MacOS').mkdir(parents=True)
    (base / 'Contents/Resources').mkdir()
    shutil.copyfile('/usr/bin/true', base / 'Contents/MacOS/Probe')
    (base / 'Contents/MacOS/Probe').chmod(0o755)
    # Unchanged large runtime data must be reused instead of shipped in the patch.
    (base / 'Contents/Resources/runtime').write_bytes(os.urandom(12 * 1024 * 1024))
    (base / 'Contents/Resources/config').write_text('old')
    info = dict(CFBundleIdentifier='wovenmatter.tests.delta', CFBundleName='Woven Matter',
                CFBundleExecutable='Probe', CFBundlePackageType='APPL',
                CFBundleShortVersionString='0.3.0', CFBundleVersion='1', LSMinimumSystemVersion='26.0',
                SUFeedURL='https://example.invalid/appcast.xml', SUPublicEDKey=public,
                SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)
    (base / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run('codesign', '--force', '--sign', '-', base)
    new = root / 'new/Woven Matter.app'
    shutil.copytree(base, new, symlinks=True)
    info['CFBundleVersion'] = '2'
    (new / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    (new / 'Contents/Resources/config').write_text('new')
    run('codesign', '--force', '--sign', '-', new)
    for build, app in ((1, base), (2, new)):
        run('hdiutil', 'create', '-quiet', '-srcfolder', app.parent, '-format', 'UDZO', archives / f'WovenMatter_0.3.0_{build}_arm64.dmg')
    run(tools / 'bin/generate_appcast', '--ed-key-file', keyfile,
        '--download-url-prefix', 'https://github.com/wovenmatter/wovenmatter/releases/download/v0.3.0/',
        '--versions', '2', '--maximum-versions', '1', '-o', archives / 'appcast.xml', archives)
    run('python3', ROOT / 'scripts/normalize-update-feed.py', archives, '0.3.0', '2')
    run(tools / 'bin/sign_update', '--ed-key-file', keyfile, archives / 'appcast.xml')
    run(tools / 'bin/sign_update', '--verify', '--ed-key-file', keyfile, archives / 'appcast.xml')
    shutil.copyfile(archives / 'appcast.xml', output / 'appcast.xml')
    full = output / 'WovenMatter_0.3.0_2_arm64.dmg'
    shutil.copyfile(archives / full.name, full)
    shutil.copyfile(full, output / 'WovenMatter_0.3.0_arm64.dmg')
    patches = list(archives.glob('*.delta'))
    assert len(patches) == 1, 'No usable delta generated'
    patch = patches[0]
    shutil.copyfile(patch, output / patch.name)
    assert patch.stat().st_size < full.stat().st_size // 10, 'Unchanged runtime was downloaded again'
    reconstructed = root / 'reconstructed/Woven Matter.app'
    reconstructed.parent.mkdir()
    run(tools / 'bin/BinaryDelta', 'apply', base, reconstructed, patch)
    run('codesign', '--verify', '--deep', '--strict', reconstructed)
    assert (reconstructed / 'Contents/Info.plist').read_bytes() == (new / 'Contents/Info.plist').read_bytes()
    assert (reconstructed / 'Contents/Resources/config').read_text() == 'new'
    assert assets.digest(reconstructed / 'Contents/Resources/runtime') == assets.digest(base / 'Contents/Resources/runtime')
    run(ROOT / 'scripts/generate-release-manifest.sh', '0.3.0', '2', output / 'WovenMatter_0.3.0_arm64.dmg', output / 'latest-mac.json')
    assets.prepare(output, '0.3.0', 2, 'a' * 40)
    run('swift', ROOT / 'scripts/verify-update-signatures.swift', output, public)
    fails(lambda: assets.verify(output, '0.3.0', 'b' * 40))
    original = full.read_bytes()
    full.write_bytes(original + b'tampered')
    fails(lambda: assets.verify(output, '0.3.0', 'a' * 40))
    fails(lambda: run('swift', ROOT / 'scripts/verify-update-signatures.swift', output, public))
    full.write_bytes(original)
    print(f'Delta round trip passed: {patch.stat().st_size:,} bytes instead of {full.stat().st_size:,}; same visible version, updated build, signature and source checks enforced.')
