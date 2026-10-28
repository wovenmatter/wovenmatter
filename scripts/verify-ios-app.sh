#!/usr/bin/env bash
set -euo pipefail
python3 - "$@" <<'PYTHON'
import pathlib, plistlib, sys
if len(sys.argv) != 3 or sys.argv[2] not in ('dev', 'distribution'):
    raise SystemExit('usage: scripts/verify-ios-app.sh APP_PATH [dev|distribution]')
app = pathlib.Path(sys.argv[1])
with (app / 'Info.plist').open('rb') as f: info = plistlib.load(f)
with (app / 'PrivacyInfo.xcprivacy').open('rb') as f: privacy = plistlib.load(f)
profile = sys.argv[2]
expected = ('Woven Matter Dev', 'com.wovenmatter.companion.dev') if profile == 'dev' else ('Woven Matter', 'com.wovenmatter.companion')
assert (info['CFBundleDisplayName'], info['CFBundleIdentifier']) == expected, 'Wrong iOS product profile'
assert 'processing' not in info.get('UIBackgroundModes', []), 'Quick Chat must not request continued processing'
assert not info.get('BGTaskSchedulerPermittedIdentifiers'), 'Retired phone scheduler is still packaged'
assert not list(app.rglob('*.wasm')), 'Embedded Python/WASM must not ship in Quick Chat'
assert not list(app.glob('*EmbeddedExecution*')), 'Retired embedded execution resources are still packaged'
assert (app / 'LUCIDE_LICENSE.txt').is_file(), 'Missing bundled icon license'
assert privacy['NSPrivacyTracking'] is False
reasons = {row['NSPrivacyAccessedAPIType']: row['NSPrivacyAccessedAPITypeReasons'] for row in privacy['NSPrivacyAccessedAPITypes']}
for category in ('UserDefaults', 'FileTimestamp', 'SystemBootTime'):
    assert reasons['NSPrivacyAccessedAPICategory' + category], 'Missing required-reason API declaration'
print(f'Verified {profile} iOS bundle: {expected[0]}, privacy manifest, and Quick Chat resource boundary.')
PYTHON
