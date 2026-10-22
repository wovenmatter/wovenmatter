#!/usr/bin/env python3
"""Real full/delta refresh and upgrade round trips, without provider or production access."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from unittest.mock import patch as mock_patch

VERSION = os.environ.get('WOVENMATTER_TEST_TARGET_VERSION', '0.3.1')
assert VERSION in ('0.3.0', '0.3.1')
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
    info['CFBundleShortVersionString'] = VERSION
    (new / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    (new / 'Contents/Resources/config').write_text('new')
    run('codesign', '--force', '--sign', '-', new)
    for build, app in ((1, base), (2, new)):
        run('hdiutil', 'create', '-quiet', '-srcfolder', app.parent, '-format', 'UDZO', archives / f'WovenMatter_{"0.3.0" if build == 1 else VERSION}_{build}_arm64.dmg')
    run(tools / 'bin/generate_appcast', '--ed-key-file', keyfile,
        '--download-url-prefix', f'https://github.com/wovenmatter/wovenmatter/releases/download/v{VERSION}/',
        '--versions', '2', '--maximum-versions', '1', '--delta-compression', 'lzfse', '-o', archives / 'appcast.xml', archives)
    # An early delta pass may overlap outer-container notarization. Rebuild the
    # feed against changed final archive bytes while preserving the delta file.
    prepared = next(archives.glob('*.delta'))
    prepared_inode, prepared_bytes = prepared.stat().st_ino, prepared.read_bytes()
    final_archive = archives / f'WovenMatter_{VERSION}_2_arm64.dmg'
    final_archive.unlink()
    run('hdiutil', 'create', '-quiet', '-srcfolder', new.parent, '-format', 'UDZO',
        '-volname', 'Final image', '-imagekey', 'zlib-level=1', final_archive)
    (archives / 'appcast.xml').unlink()
    run(tools / 'bin/generate_appcast', '--ed-key-file', keyfile,
        '--download-url-prefix', f'https://github.com/wovenmatter/wovenmatter/releases/download/v{VERSION}/',
        '--versions', '2', '--maximum-versions', '1', '--delta-compression', 'lzfse', '-o', archives / 'appcast.xml', archives)
    assert prepared.stat().st_ino == prepared_inode and prepared.read_bytes() == prepared_bytes
    run('python3', ROOT / 'scripts/normalize-update-feed.py', archives, VERSION, '2')
    run(tools / 'bin/sign_update', '--ed-key-file', keyfile, archives / 'appcast.xml')
    run(tools / 'bin/sign_update', '--verify', '--ed-key-file', keyfile, archives / 'appcast.xml')
    shutil.copyfile(archives / 'appcast.xml', output / 'appcast.xml')
    full = output / f'WovenMatter_{VERSION}_2_arm64.dmg'
    shutil.copyfile(archives / full.name, full)
    shutil.copyfile(full, output / f'WovenMatter_{VERSION}_arm64.dmg')
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
    path_spec = importlib.util.spec_from_file_location('update_paths', ROOT / 'scripts/verify-update-paths.py')
    paths = importlib.util.module_from_spec(path_spec)
    path_spec.loader.exec_module(paths)
    paths.verify(output, archives, tools, notarized=False)
    # Reject a changed delta before it can supply an installed app.
    patch_output = output / patch.name
    patch_bytes = patch_output.read_bytes()
    patch_output.write_bytes(b'not a delta')
    fails(lambda: paths.verify(output, archives, tools, notarized=False))
    patch_output.write_bytes(patch_bytes)
    run(ROOT / 'scripts/generate-release-manifest.sh', VERSION, '2', output / f'WovenMatter_{VERSION}_arm64.dmg', output / 'latest-mac.json')
    assets.prepare(output, VERSION, 2, 'a' * 40)
    run('swift', ROOT / 'scripts/verify-update-signatures.swift', output, public)
    # Exercise the real retained-artifact validator too. Only the fixture's
    # public signing identity and Apple notarization/Gatekeeper services differ
    # from production; metadata, checksums and both Ed25519 checks run for real.
    stage_spec = importlib.util.spec_from_file_location('stage', ROOT / 'scripts/stage-update.py')
    stage = importlib.util.module_from_spec(stage_spec)
    stage_spec.loader.exec_module(stage)
    trust_checks = []
    def reuse_run(*args):
        if args[0] == 'swift':
            return run(*args, public)
        if str(args[0]).endswith('/prepare-sparkle-tools.sh'):
            return str(tools)
        if args[0] in ('codesign', 'xcrun', 'spctl'):
            trust_checks.append(args)
            return ''
        return run(*args)
    with mock_patch.dict(os.environ, WOVENMATTER_SPARKLE_PRIVATE_KEY=str(keyfile)), mock_patch.object(stage, 'run', side_effect=reuse_run):
        stage.validate_reused(output, VERSION, 'a' * 40, 2)
        assert [call[0] for call in trust_checks] == ['codesign', 'xcrun', 'spctl']
        feed = output / 'appcast.xml'
        signed = feed.read_bytes()
        feed.write_bytes(signed.replace(b'<channel>', b'<channel><!-- tampered retained feed -->', 1))
        assets.prepare(output, VERSION, 2, 'a' * 40)
        fails(lambda: stage.validate_reused(output, VERSION, 'a' * 40, 2))
        feed.write_bytes(signed)
        assets.prepare(output, VERSION, 2, 'a' * 40)
    fails(lambda: assets.verify(output, VERSION, 'b' * 40))
    original = full.read_bytes()
    full.write_bytes(original + b'tampered')
    fails(lambda: assets.verify(output, VERSION, 'a' * 40))
    fails(lambda: run('swift', ROOT / 'scripts/verify-update-signatures.swift', output, public))
    full.write_bytes(original)
    print(f'Delta round trip passed: {patch.stat().st_size:,} bytes instead of {full.stat().st_size:,}; target version {VERSION}, updated build, signature and source checks enforced.')
