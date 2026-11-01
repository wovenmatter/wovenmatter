"""The update manifest generator and the release validator agree on one exact
contract, including the device setup capability the app advertises."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_assets', ROOT / 'scripts/release-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)
SHA = 'a' * 40
VERSION, BUILD = '1.2.3', 42
LEGACY, FULL = f'WovenMatter_{VERSION}_arm64.dmg', f'WovenMatter_{VERSION}_{BUILD}_arm64.dmg'
MISSING = object()


def rejected(action):
    try:
        action()
    except AssertionError:
        return True
    return False


with open(ROOT / 'app/App/Info.plist', 'rb') as source:
    advertised = plistlib.load(source)['WovenMatterDeviceSetupVersion']
assert type(advertised) is int and advertised >= 0
assert assets.device_setup_version() == advertised

with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    folder = temp / 'release'
    folder.mkdir()
    payload = b'signed disk image' * 100
    for name in (LEGACY, FULL):
        (folder / name).write_bytes(payload)
    prefix = f'https://github.com/wovenmatter/wovenmatter/releases/download/v{VERSION}/'
    (folder / 'appcast.xml').write_text(
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
        f'<sparkle:version>{BUILD}</sparkle:version><sparkle:shortVersionString>{VERSION}</sparkle:shortVersionString>'
        f'<enclosure url="{prefix + FULL}" length="{len(payload)}" sparkle:edSignature="fixture"/>'
        '</item></channel></rss>')
    manifest_path = folder / 'latest-mac.json'
    # The real production generator's output is accepted as is.
    subprocess.run([str(ROOT / 'scripts/generate-release-manifest.sh'), VERSION, str(BUILD),
                    str(folder / LEGACY), str(manifest_path)], check=True)
    generated = json.loads(manifest_path.read_text())
    assert generated['device_setup_version'] == advertised
    assets.prepare(folder, VERSION, BUILD, SHA)

    # Any other capability value, type or shape is rejected. Checksums are
    # regenerated each time, so only the manifest contract can fail.
    variants = [MISSING, True, False, None, -1, advertised + 1, str(advertised), float(advertised), [advertised]]
    for value in variants:
        manifest = dict(generated)
        if value is MISSING:
            del manifest['device_setup_version']
        else:
            manifest['device_setup_version'] = value
        manifest_path.write_text(json.dumps(manifest))
        assert rejected(lambda: assets.prepare(folder, VERSION, BUILD, SHA)), f'Accepted device_setup_version={value!r}'
    # The contract is exact: an unknown field is rejected, not ignored.
    manifest_path.write_text(json.dumps(dict(generated, future_capability=1)))
    assert rejected(lambda: assets.prepare(folder, VERSION, BUILD, SHA)), 'Accepted an unknown manifest field'
    manifest_path.write_text(json.dumps(generated))
    assets.prepare(folder, VERSION, BUILD, SHA)

    # The advertised capability itself must be a non-negative integer.
    for value in (True, -1, '1', 1.5):
        info = temp / 'Info.plist'
        info.write_bytes(plistlib.dumps(dict(WovenMatterDeviceSetupVersion=value)))
        assert rejected(lambda: assets.device_setup_version(info)), f'Accepted app capability {value!r}'
    info.write_bytes(plistlib.dumps({}))
    assert assets.device_setup_version(info) == 0

print('Update manifest contract: generator output accepted; missing, boolean, negative, mismatched, '
      'mistyped and unknown capability metadata rejected.')
