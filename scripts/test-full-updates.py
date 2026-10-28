#!/usr/bin/env python3
"""A real same-version full-only update round trip, with no provider, Apple, or production access."""
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

with tempfile.TemporaryDirectory(prefix='wovenmatter-update-test-') as temp:
    root = Path(temp)
    archives, output = root / 'archives', root / 'output'
    archives.mkdir()
    output.mkdir()
    tools = Path(os.environ.get('WOVENMATTER_TEST_SPARKLE_TOOLS') or run(ROOT / 'scripts/prepare-sparkle-tools.sh'))
    # A temporary signing identity, unrelated to the production release key.
    keyfile = root / 'key'
    public = run('swift', '-e', 'import Foundation; import CryptoKit; let k = Curve25519.Signing.PrivateKey(); try k.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8); print(k.publicKey.rawRepresentation.base64EncodedString())', keyfile)
    new = root / 'new/Woven Matter.app'
    (new / 'Contents/MacOS').mkdir(parents=True)
    (new / 'Contents/Resources').mkdir()
    shutil.copyfile('/usr/bin/true', new / 'Contents/MacOS/Probe')
    (new / 'Contents/MacOS/Probe').chmod(0o755)
    (new / 'Contents/Resources/runtime').write_bytes(os.urandom(12 * 1024 * 1024))
    (new / 'Contents/Resources/config').write_text('new')
    info = dict(CFBundleIdentifier='wovenmatter.tests.update', CFBundleName='Woven Matter',
                CFBundleExecutable='Probe', CFBundlePackageType='APPL',
                CFBundleShortVersionString='0.3.0', CFBundleVersion='2', LSMinimumSystemVersion='26.0',
                SUFeedURL='https://example.invalid/appcast.xml', SUPublicEDKey=public,
                SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)
    (new / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run('codesign', '--force', '--sign', '-', new)
    run('hdiutil', 'create', '-quiet', '-srcfolder', new.parent, '-format', 'UDZO', archives / 'WovenMatter_0.3.0_2_arm64.dmg')
    # Same generator flags as production: only the new archive, and no deltas.
    run(tools / 'bin/generate_appcast', '--ed-key-file', keyfile,
        '--download-url-prefix', 'https://github.com/wovenmatter/wovenmatter/releases/download/v0.3.0/',
        '--maximum-versions', '1', '--maximum-deltas', '0', '--versions', '2', '-o', archives / 'appcast.xml', archives)
    assert not list(archives.glob('*.delta')), 'Full-only generation produced a delta'
    run(tools / 'bin/sign_update', '--ed-key-file', keyfile, archives / 'appcast.xml')
    run(tools / 'bin/sign_update', '--verify', '--ed-key-file', keyfile, archives / 'appcast.xml')
    shutil.copyfile(archives / 'appcast.xml', output / 'appcast.xml')
    full = output / 'WovenMatter_0.3.0_2_arm64.dmg'
    shutil.copyfile(archives / full.name, full)
    shutil.copyfile(full, output / 'WovenMatter_0.3.0_arm64.dmg')
    path_spec = importlib.util.spec_from_file_location('update_paths', ROOT / 'scripts/verify-update-paths.py')
    paths = importlib.util.module_from_spec(path_spec)
    path_spec.loader.exec_module(paths)
    paths.verify(output, notarized=False)
    run(ROOT / 'scripts/generate-release-manifest.sh', '0.3.0', '2', output / 'WovenMatter_0.3.0_arm64.dmg', output / 'latest-mac.json')
    assets.prepare(output, '0.3.0', 2, 'a' * 40)
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
        stage.validate_reused(output, '0.3.0', 'a' * 40, 2)
        assert [call[0] for call in trust_checks] == ['codesign', 'xcrun', 'spctl']
        feed = output / 'appcast.xml'
        signed = feed.read_bytes()
        feed.write_bytes(signed.replace(b'<channel>', b'<channel><!-- tampered retained feed -->', 1))
        assets.prepare(output, '0.3.0', 2, 'a' * 40)
        fails(lambda: stage.validate_reused(output, '0.3.0', 'a' * 40, 2))
        feed.write_bytes(signed)
        assets.prepare(output, '0.3.0', 2, 'a' * 40)
    fails(lambda: assets.verify(output, '0.3.0', 'b' * 40))
    original = full.read_bytes()
    full.write_bytes(original + b'tampered')
    fails(lambda: assets.verify(output, '0.3.0', 'a' * 40))
    fails(lambda: run('swift', ROOT / 'scripts/verify-update-signatures.swift', output, public))
    full.write_bytes(original)
    # A delta asset is rejected, not silently skipped.
    stray = output / 'WovenMatter_0.3.0_2_from_1_arm64.delta'
    stray.write_bytes(b'delta')
    fails(lambda: assets.verify(output, '0.3.0', 'a' * 40))
    fails(lambda: paths.verify(output, notarized=False))
    stray.unlink()
    print(f'Full-only round trip passed: {full.stat().st_size:,}-byte signed update with no deltas; same visible version, updated build, signature and source checks enforced.')
