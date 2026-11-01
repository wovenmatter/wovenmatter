#!/usr/bin/env python3
"""Fail-closed verification of Woven Matter iOS bundles and exported IPAs.

Every check raises VerificationError explicitly. Nothing relies on `assert`, so
`python -O` or PYTHONOPTIMIZE cannot turn a failed check into a pass. Signing
checks read the artifact with codesign and security only; they never sign,
contact Apple, or change local credentials.
"""
import datetime
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile

TEAM = '3M84Q9NAMN'
PROFILES = {
    'dev': ('Woven Matter Dev', 'com.wovenmatter.companion.dev'),
    'distribution': ('Woven Matter', 'com.wovenmatter.companion'),
}
VERSION = re.compile(r'[0-9]+(\.[0-9]+){0,2}')
# Every UI-test environment lookup is compiled only in Debug builds (#if DEBUG). The
# prefixes deliberately also match variants such as WOVENMATTER_UI_FIXTURE_NAMESPACE
# and WOVENMATTER_UI_TAB, so any fixture plumbing in a distribution binary fails.
DEBUG_MARKERS = (b'WOVENMATTER_UI_FIXTURE', b'WOVENMATTER_UI_SCENARIO', b'WOVENMATTER_UI_TAB')
REQUIRED_REASONS = ('UserDefaults', 'FileTimestamp', 'SystemBootTime')
USAGE_DESCRIPTIONS = ('NSMicrophoneUsageDescription', 'NSCameraUsageDescription')
ALLOWED_ENTITLEMENTS = {
    'application-identifier', 'com.apple.developer.team-identifier', 'keychain-access-groups',
    'get-task-allow', 'beta-reports-active',
}
DISTRIBUTION_AUTHORITIES = ('Apple Distribution:', 'iPhone Distribution:')
IPA_ROOTS = ('Payload/', 'Symbols/', 'SwiftSupport/', 'BCSymbolMaps/')


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def load_plist(path, label):
    require(path.is_file(), f'Missing {label}')
    try:
        value = plistlib.loads(path.read_bytes())
    except Exception:
        raise VerificationError(f'Unreadable {label}') from None
    require(isinstance(value, dict), f'Unexpected {label} structure')
    return value


def unexpanded(value):
    if isinstance(value, str):
        return '$(' in value
    if isinstance(value, dict):
        return any(unexpanded(item) for item in value.values())
    if isinstance(value, list):
        return any(unexpanded(item) for item in value)
    return False


def verify_bundle(app, profile):
    """Product identity, version, privacy and resource boundary. Returns (info, notes)."""
    require(profile in PROFILES, f'Unknown profile {profile!r}')
    require(app.is_dir() and app.suffix == '.app', f'Not an app bundle: {app}')
    info = load_plist(app / 'Info.plist', 'Info.plist')
    name, identifier = PROFILES[profile]
    require((info.get('CFBundleDisplayName'), info.get('CFBundleIdentifier')) == (name, identifier),
            f'Wrong iOS product profile: expected {name} / {identifier}')
    require(not unexpanded(info), 'Info.plist contains an unexpanded build setting')
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        value = info.get(key)
        require(isinstance(value, str) and VERSION.fullmatch(value) is not None,
                f'{key} must be one to three period-separated integers')
    executable = info.get('CFBundleExecutable')
    require(isinstance(executable, str) and executable and '/' not in executable and (app / executable).is_file(),
            'Missing app executable')
    modes = info.get('UIBackgroundModes', [])
    require(isinstance(modes, list) and 'processing' not in modes, 'Quick Chat must not request continued processing')
    require(not info.get('BGTaskSchedulerPermittedIdentifiers'), 'Retired phone scheduler is still packaged')
    for key in USAGE_DESCRIPTIONS:
        value = info.get(key)
        require(isinstance(value, str) and value.strip(), f'Missing {key}')
    icon = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}) if isinstance(info.get('CFBundleIcons'), dict) else {}
    require(isinstance(icon, dict) and icon.get('CFBundleIconName') == 'AppIcon' and (app / 'Assets.car').is_file(),
            'The AppIcon asset catalog is not compiled into the bundle')
    require(not any(app.rglob('*.wasm')), 'Embedded Python/WASM must not ship in Quick Chat')
    require(not any('EmbeddedExecution' in path.name for path in app.rglob('*')),
            'Retired embedded execution resources are still packaged')
    require((app / 'LUCIDE_LICENSE.txt').is_file(), 'Missing bundled icon license')
    privacy = load_plist(app / 'PrivacyInfo.xcprivacy', 'privacy manifest')
    require(privacy.get('NSPrivacyTracking') is False, 'The privacy manifest must declare no tracking')
    require(privacy.get('NSPrivacyTrackingDomains', []) == [], 'The privacy manifest must not list tracking domains')
    rows = privacy.get('NSPrivacyAccessedAPITypes')
    require(isinstance(rows, list), 'Missing required-reason API declarations')
    reasons = {row.get('NSPrivacyAccessedAPIType'): row.get('NSPrivacyAccessedAPITypeReasons') for row in rows if isinstance(row, dict)}
    for category in REQUIRED_REASONS:
        value = reasons.get('NSPrivacyAccessedAPICategory' + category)
        require(isinstance(value, list) and value and all(isinstance(item, str) and item for item in value),
                f'Missing required-reason API declaration for {category}')
    if profile == 'distribution':
        binary = (app / executable).read_bytes()
        require(not any(marker in binary for marker in DEBUG_MARKERS),
                'Debug-only UI fixtures are compiled into the distribution binary')
    notes = []
    compliance = info.get('ITSAppUsesNonExemptEncryption')
    if compliance is None:
        notes.append('Export compliance: ITSAppUsesNonExemptEncryption is not declared; App Store Connect asks for each uploaded build.')
    else:
        require(isinstance(compliance, bool), 'ITSAppUsesNonExemptEncryption must be a Boolean')
        notes.append(f'Export compliance: ITSAppUsesNonExemptEncryption = {str(compliance).lower()}.')
    return info, notes


def check_entitlements(entitlements, identifier):
    require(isinstance(entitlements, dict) and entitlements, 'The app has no signed entitlements')
    require(entitlements.get('application-identifier') == f'{TEAM}.{identifier}', 'Signed application identifier does not match the product')
    require(entitlements.get('com.apple.developer.team-identifier') == TEAM, 'Signed team identifier does not match the Woven Matter team')
    require(entitlements.get('get-task-allow') in (None, False), 'Distribution signing must not allow debugging (get-task-allow)')
    unexpected = sorted(set(entitlements) - ALLOWED_ENTITLEMENTS)
    require(not unexpected, 'Unexpected signed entitlements: ' + ', '.join(unexpected))
    groups = entitlements.get('keychain-access-groups', [])
    require(isinstance(groups, list) and all(isinstance(group, str) and group.startswith(TEAM + '.') for group in groups),
            'Keychain access groups must belong to the Woven Matter team')


def check_profile(profile, entitlements, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    require(isinstance(profile, dict), 'Unreadable provisioning profile')
    require(TEAM in profile.get('TeamIdentifier', []), 'Provisioning profile belongs to another team')
    granted = profile.get('Entitlements', {})
    require(isinstance(granted, dict), 'Provisioning profile has no entitlements')
    require(granted.get('application-identifier') == entitlements.get('application-identifier'),
            'Provisioning profile is for another application identifier')
    require(not granted.get('get-task-allow'), 'Provisioning profile is a development profile')
    require(not profile.get('ProvisionedDevices'), 'Provisioning profile is limited to registered devices (ad hoc or development)')
    require(not profile.get('ProvisionsAllDevices'), 'Provisioning profile is an enterprise profile')
    expiry = profile.get('ExpirationDate')
    require(isinstance(expiry, datetime.datetime), 'Provisioning profile has no expiration date')
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    require(expiry > now, 'Provisioning profile has expired')
    for group in entitlements.get('keychain-access-groups', []):
        allowed = granted.get('keychain-access-groups', [])
        require(any(group == item or (item.endswith('*') and group.startswith(item[:-1])) for item in allowed),
                f'Keychain group {group} is not granted by the provisioning profile')


def check_signature_details(details):
    """Parse `codesign -dvvv` output for the signing identity and team."""
    authorities = re.findall(r'^Authority=(.+)$', details, re.MULTILINE)
    teams = re.findall(r'^TeamIdentifier=(.+)$', details, re.MULTILINE)
    require(teams == [TEAM], 'Code signature belongs to another team or is ad hoc')
    require(authorities and authorities[0].startswith(DISTRIBUTION_AUTHORITIES),
            'The app is not signed with an Apple Distribution identity')
    return authorities[0]


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def verify_signature(app, identifier, runner=run):
    code, _, error = runner(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)])
    reason = (error.strip().splitlines() or ['no signature'])[-1]
    require(code == 0, 'Code signature is missing or invalid: ' + reason)
    code, _, details = runner(['codesign', '-dvvv', str(app)])
    require(code == 0, 'Code signature details are unreadable')
    authority = check_signature_details(details)
    code, output, _ = runner(['codesign', '-d', '--entitlements', '-', '--xml', str(app)])
    require(code == 0 and output.strip(), 'Signed entitlements are unreadable')
    try:
        entitlements = plistlib.loads(output.encode())
    except Exception:
        raise VerificationError('Signed entitlements are unreadable') from None
    check_entitlements(entitlements, identifier)
    provision = app / 'embedded.mobileprovision'
    require(provision.is_file(), 'Missing embedded provisioning profile')
    code, output, _ = runner(['security', 'cms', '-D', '-i', str(provision)])
    require(code == 0 and output.strip(), 'Provisioning profile is unreadable')
    try:
        profile = plistlib.loads(output.encode())
    except Exception:
        raise VerificationError('Provisioning profile is unreadable') from None
    check_profile(profile, entitlements)
    nested = [path for folder in ('Frameworks', 'PlugIns', 'Extensions') for path in sorted((app / folder).glob('*'))
              if path.suffix in ('.framework', '.dylib', '.appex')]
    for path in nested:
        code, _, details = runner(['codesign', '-dvvv', str(path)])
        require(code == 0 and re.findall(r'^TeamIdentifier=(.+)$', details, re.MULTILINE) == [TEAM],
                f'Nested code {path.name} is not signed by the Woven Matter team')
    return authority


def extract_ipa(ipa, destination):
    require(ipa.is_file() and ipa.suffix == '.ipa', f'Not an IPA: {ipa}')
    try:
        archive = zipfile.ZipFile(ipa)
    except zipfile.BadZipFile:
        raise VerificationError('The IPA is not a readable archive') from None
    with archive:
        names = archive.namelist()
        for name in names:
            parts = pathlib.PurePosixPath(name).parts
            require(not name.startswith('/') and '..' not in parts and '\\' not in name, f'Unsafe IPA entry: {name}')
            require(name.startswith(IPA_ROOTS), f'Unexpected IPA content outside Payload: {name}')
        apps = {pathlib.PurePosixPath(name).parts[1] for name in names
                if name.startswith('Payload/') and len(pathlib.PurePosixPath(name).parts) > 1}
        require(len(apps) == 1 and next(iter(apps)).endswith('.app'), 'The IPA must contain exactly one app in Payload')
        # Use ditto so code signatures, symlinks and permissions survive extraction.
        archive_path = str(ipa)
    code, _, error = run(['ditto', '-x', '-k', archive_path, str(destination)])
    require(code == 0, 'The IPA could not be extracted: ' + error.strip())
    return destination / 'Payload' / next(iter(apps))


def verify_ipa(ipa):
    with tempfile.TemporaryDirectory(prefix='wovenmatter-ipa-') as temporary:
        app = extract_ipa(ipa, pathlib.Path(temporary))
        info, notes = verify_bundle(app, 'distribution')
        authority = verify_signature(app, PROFILES['distribution'][1])
    return info, notes, authority


def main(arguments):
    try:
        if len(arguments) == 2 and arguments[0] == '--ipa':
            info, notes, authority = verify_ipa(pathlib.Path(arguments[1]))
            summary = (f'Verified exported IPA: Woven Matter {info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]}), '
                       f'{authority}, App Store provisioning, entitlements, privacy manifest and resource boundary.')
        elif len(arguments) in (2, 3) and arguments[1] in PROFILES and arguments[2:] in ([], ['--signed']):
            app, profile = pathlib.Path(arguments[0]), arguments[1]
            info, notes = verify_bundle(app, profile)
            signed = ''
            if arguments[2:] == ['--signed']:
                require(profile == 'distribution', '--signed applies to distribution bundles')
                signed = ', ' + verify_signature(app, PROFILES[profile][1])
            summary = (f'Verified {profile} iOS bundle: {info["CFBundleDisplayName"]} {info["CFBundleShortVersionString"]} '
                       f'({info["CFBundleVersion"]}){signed}, privacy manifest, and Quick Chat resource boundary.')
        else:
            print('usage: scripts/verify-ios-app.sh APP_PATH dev|distribution [--signed]\n'
                  '       scripts/verify-ios-app.sh --ipa EXPORTED_IPA', file=sys.stderr)
            return 64
    except VerificationError as error:
        print(f'iOS verification failed: {error}', file=sys.stderr)
        return 1
    for note in notes:
        print(note)
    print(summary)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
