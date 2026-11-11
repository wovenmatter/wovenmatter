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
    'dev': ('Woven Matter Dev', 'com.wovenmatter.wovenmatter.dev'),
    'distribution': ('Woven Matter', 'com.wovenmatter.wovenmatter'),
}
# Apple's CFBundleVersion/CFBundleShortVersionString: one to three
# period-separated integers, without leading zeros.
VERSION = re.compile(r'(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}')
# Every UI-test environment lookup is compiled only in Debug builds (#if DEBUG). The
# prefixes deliberately also match variants such as WOVENMATTER_UI_FIXTURE_NAMESPACE,
# so any fixture plumbing in a distribution binary fails. The development tailnet
# router, its pairing shortcuts and the device runtime smoke are Debug-only too.
DEBUG_MARKERS = (
    b'WOVENMATTER_UI_FIXTURE', b'WOVENMATTER_UI_SCENARIO', b'WOVENMATTER_UI_TAB',
    b'WOVENMATTER_DEV_TAILNET', b'WOVENMATTER_DEV_PAIR_LINK', b'WOVENMATTER_DEV_TAB',
    b'WOVENMATTER_DEVICE_RUNTIME_SMOKE',
)
# The privacy manifest must declare exactly these required-reason APIs and data
# types (ios/Config/PrivacyInfo.xcprivacy; audit notes in ios/README.md). A new
# use of another required-reason API, or new data leaving the device, must be
# added to the manifest and here in the same change.
REQUIRED_REASONS = {
    'UserDefaults': ['CA92.1'],    # App preferences read and written by this app only.
    'FileTimestamp': ['C617.1'],   # Metadata of files inside the app container.
    'SystemBootTime': ['35F9.1'],  # systemUptime for elapsed time within the app.
}
COLLECTED_DATA = {
    # type: (linked to the user, purposes)
    'OtherUserContent': (True, ['AppFunctionality']),   # Quick Chat content to the chosen model provider.
    'SearchHistory': (True, ['AppFunctionality']),      # Web searches to the chosen search provider.
    'UserID': (False, ['Analytics']),                   # Random library analytics ID, relayed by the Mac.
    'ProductInteraction': (False, ['Analytics']),       # app_opened / app_active signals.
}
USAGE_DESCRIPTIONS = ('NSMicrophoneUsageDescription', 'NSCameraUsageDescription')
ALLOWED_ENTITLEMENTS = {
    'application-identifier', 'com.apple.developer.team-identifier', 'keychain-access-groups',
    'get-task-allow', 'beta-reports-active',
}
DISTRIBUTION_AUTHORITIES = ('Apple Distribution:', 'iPhone Distribution:')
IPA_ROOTS = ('Payload/', 'Symbols/', 'SwiftSupport/', 'BCSymbolMaps/')
MACHO_MAGICS = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf')


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
        return '$(' in value or '${' in value
    if isinstance(value, dict):
        return any(unexpanded(item) for item in value.values())
    if isinstance(value, list):
        return any(unexpanded(item) for item in value)
    return False


def check_privacy(privacy):
    require(privacy.get('NSPrivacyTracking') is False, 'The privacy manifest must declare no tracking')
    require(privacy.get('NSPrivacyTrackingDomains', []) == [], 'The privacy manifest must not list tracking domains')
    rows = privacy.get('NSPrivacyAccessedAPITypes')
    require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows),
            'Missing required-reason API declarations')
    reasons = {}
    for row in rows:
        category = row.get('NSPrivacyAccessedAPIType')
        name = category.removeprefix('NSPrivacyAccessedAPICategory') if isinstance(category, str) else ''
        require(name and name != category and name not in reasons, f'Invalid or repeated required-reason API row: {category!r}')
        reasons[name] = row.get('NSPrivacyAccessedAPITypeReasons')
    for category, expected in REQUIRED_REASONS.items():
        require(category in reasons, f'Missing required-reason API declaration for {category}')
        require(reasons[category] == expected,
                f'Required-reason API {category} must declare {", ".join(expected)}')
    unexpected = sorted(set(reasons) - set(REQUIRED_REASONS))
    require(not unexpected, 'Undocumented required-reason API declarations: ' + ', '.join(unexpected))
    rows = privacy.get('NSPrivacyCollectedDataTypes')
    require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows),
            'Missing collected data type declarations')
    collected = {}
    for row in rows:
        kind = row.get('NSPrivacyCollectedDataType')
        name = kind.removeprefix('NSPrivacyCollectedDataType') if isinstance(kind, str) else ''
        require(name and name != kind and name not in collected, f'Invalid or repeated collected data type row: {kind!r}')
        require(row.get('NSPrivacyCollectedDataTypeTracking') is False, f'{name} must not be used for tracking')
        linked = row.get('NSPrivacyCollectedDataTypeLinked')
        purposes = row.get('NSPrivacyCollectedDataTypePurposes')
        require(isinstance(linked, bool) and isinstance(purposes, list), f'Incomplete declaration for {name}')
        collected[name] = (linked, [str(item).removeprefix('NSPrivacyCollectedDataTypePurpose') for item in purposes])
    for name, expected in COLLECTED_DATA.items():
        require(name in collected, f'Missing collected data type declaration for {name}')
        require(collected[name] == expected, f'Collected data type {name} must be linked={expected[0]}, '
                                             f'purposes={", ".join(expected[1])}')
    unexpected = sorted(set(collected) - set(COLLECTED_DATA))
    require(not unexpected, 'Undocumented collected data type declarations: ' + ', '.join(unexpected))


def macho_files(app):
    for path in sorted(app.rglob('*')):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as handle:
                if handle.read(4) in MACHO_MAGICS:
                    yield path


def verify_bundle(app, profile, version=None, build=None):
    """Product identity, version, privacy and resource boundary. Returns Info.plist."""
    require(profile in PROFILES, f'Unknown profile {profile!r}')
    require(app.is_dir() and app.suffix == '.app', f'Not an app bundle: {app}')
    info = load_plist(app / 'Info.plist', 'Info.plist')
    name, identifier = PROFILES[profile]
    require((info.get('CFBundleDisplayName'), info.get('CFBundleIdentifier')) == (name, identifier),
            f'Wrong iOS product profile: expected {name} / {identifier}, found '
            f'{info.get("CFBundleDisplayName")} / {info.get("CFBundleIdentifier")}')
    require(not unexpanded(info), 'Info.plist contains an unexpanded build setting')
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        value = info.get(key)
        require(isinstance(value, str) and VERSION.fullmatch(value) is not None,
                f'{key} must be one to three period-separated integers')
    require(version is None or info['CFBundleShortVersionString'] == version,
            f'Expected version {version}, found {info["CFBundleShortVersionString"]}')
    require(build is None or info['CFBundleVersion'] == build,
            f'Expected build number {build}, found {info["CFBundleVersion"]}')
    executable = info.get('CFBundleExecutable')
    require(isinstance(executable, str) and executable and '/' not in executable and (app / executable).is_file(),
            'Missing app executable')
    require(info.get('UIDeviceFamily') in (None, [1, 2]), 'The app must target iPhone and iPad')
    modes = info.get('UIBackgroundModes', [])
    require(isinstance(modes, list) and 'processing' not in modes, 'Quick Chat must not request continued processing')
    require(not info.get('BGTaskSchedulerPermittedIdentifiers'), 'Retired phone scheduler is still packaged')
    for key in USAGE_DESCRIPTIONS:
        value = info.get(key)
        require(isinstance(value, str) and value.strip() and not unexpanded(value), f'Missing {key}')
    icons = info.get('CFBundleIcons')
    icon = icons.get('CFBundlePrimaryIcon') if isinstance(icons, dict) else None
    require(isinstance(icon, dict) and icon.get('CFBundleIconName') == 'AppIcon' and (app / 'Assets.car').is_file(),
            'The AppIcon asset catalog is not compiled into the bundle')
    require(not any(app.rglob('*.wasm')), 'Embedded Python/WASM must not ship in Quick Chat')
    require(not any('EmbeddedExecution' in path.name for path in app.rglob('*')),
            'Retired embedded execution resources are still packaged')
    require((app / 'LUCIDE_LICENSE.txt').is_file(), 'Missing bundled icon license')
    check_privacy(load_plist(app / 'PrivacyInfo.xcprivacy', 'privacy manifest'))
    compliance = info.get('ITSAppUsesNonExemptEncryption')
    if profile == 'distribution':
        # Exempt encryption only (HTTPS, signing, hashing, Data Protection, Keychain);
        # see ios/README.md, "Export compliance".
        require(compliance is False, 'Release Info.plist must declare ITSAppUsesNonExemptEncryption = false')
        for path in macho_files(app):
            binary = path.read_bytes()
            found = [marker.decode() for marker in DEBUG_MARKERS if marker in binary]
            require(not found, f'Debug-only fixtures are compiled into {path.relative_to(app)}: {", ".join(found)}')
    else:
        require(compliance in (None, False), 'ITSAppUsesNonExemptEncryption must be false')
    return info


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
    require(granted.get('beta-reports-active') is True, 'Provisioning profile is not an App Store profile (no TestFlight)')
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
    code, _, error = run(['ditto', '-x', '-k', str(ipa), str(destination)])
    require(code == 0, 'The IPA could not be extracted: ' + error.strip())
    return destination / 'Payload' / next(iter(apps))


def verify_ipa(ipa, version=None, build=None):
    with tempfile.TemporaryDirectory(prefix='wovenmatter-ipa-') as temporary:
        app = extract_ipa(ipa, pathlib.Path(temporary))
        info = verify_bundle(app, 'distribution', version, build)
        authority = verify_signature(app, PROFILES['distribution'][1])
    return info, authority


USAGE = ('usage: scripts/verify-ios-app.sh APP_PATH dev|distribution [--signed] [--version V] [--build B]\n'
         '       scripts/verify-ios-app.sh --ipa EXPORTED_IPA [--version V] [--build B]')


def parse(arguments):
    """Returns (target, profile, signed, version, build), or None for a usage error."""
    arguments = list(arguments)
    options = {'--version': None, '--build': None}
    signed = False
    positional = []
    while arguments:
        item = arguments.pop(0)
        if item in options:
            if not arguments or options[item] is not None:
                return None
            options[item] = arguments.pop(0)
        elif item == '--signed' and not signed:
            signed = True
        else:
            positional.append(item)
    if len(positional) == 2 and positional[0] == '--ipa' and not signed:
        return pathlib.Path(positional[1]), 'ipa', True, options['--version'], options['--build']
    if len(positional) == 2 and positional[1] in PROFILES and (not signed or positional[1] == 'distribution'):
        return pathlib.Path(positional[0]), positional[1], signed, options['--version'], options['--build']
    return None


def main(arguments):
    parsed = parse(arguments)
    if parsed is None:
        print(USAGE, file=sys.stderr)
        return 64
    target, profile, signed, version, build = parsed
    try:
        if profile == 'ipa':
            info, authority = verify_ipa(target, version, build)
            summary = (f'Verified exported IPA: Woven Matter {info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]}), '
                       f'{authority}, App Store provisioning, entitlements, privacy manifest, '
                       'export compliance and resource boundary.')
        else:
            info = verify_bundle(target, profile, version, build)
            detail = ', ' + verify_signature(target, PROFILES[profile][1]) if signed else ''
            summary = (f'Verified {profile} iOS bundle: {info["CFBundleDisplayName"]} {info["CFBundleShortVersionString"]} '
                       f'({info["CFBundleVersion"]}){detail}, privacy manifest, export compliance and resource boundary.')
    except VerificationError as error:
        print(f'iOS verification failed: {error}', file=sys.stderr)
        return 1
    print(summary)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
