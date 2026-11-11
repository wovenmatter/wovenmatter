"""The iOS artifact verifier and TestFlight helper must fail closed.

Fixtures are synthetic bundles: no Xcode build, signing identity, API key or
Apple service is used. Each defect runs through the real command-line entry
point with normal, `-O` and PYTHONOPTIMIZE interpreters, so a check written as
`assert` would pass silently and fail this test. The helper runs with stubbed
xcodebuild, xcrun, security and date, so it can never build, sign or upload.
"""
import datetime
import importlib.util
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True  # Loading the verifier must not leave caches in the source tree.
_fixture_spec = importlib.util.spec_from_file_location('ios_app_fixture', pathlib.Path(__file__).resolve().parent / 'ios_app_fixture.py')
fixture = importlib.util.module_from_spec(_fixture_spec)
_fixture_spec.loader.exec_module(fixture)
ROOT, SCRIPT, verifier = fixture.ROOT, fixture.SCRIPT, fixture.verifier
write_plist, make_app, VERSION, BUILD = fixture.write_plist, fixture.make_app, fixture.VERSION, fixture.BUILD

INTERPRETERS = [
    ([sys.executable, '-I'], {}),
    ([sys.executable, '-I', '-O'], {}),
    ([sys.executable], {'PYTHONOPTIMIZE': '2'}),
]


def fail(message):
    raise SystemExit('FAIL: ' + message)


def edit_plist(path, change):
    value = plistlib.loads(path.read_bytes())
    change(value)
    write_plist(path, value)


def privacy(change):
    return lambda app: edit_plist(app / 'PrivacyInfo.xcprivacy', change)


def reasons(value):
    return value['NSPrivacyAccessedAPITypes']


def collected(value):
    return value['NSPrivacyCollectedDataTypes']


def nested_binary(app, data):
    (app / 'Frameworks/Runtime.framework').mkdir(parents=True)
    (app / 'Frameworks/Runtime.framework/Runtime').write_bytes(b'\xcf\xfa\xed\xfe' + data)


def mutations():
    info = lambda change: lambda app: edit_plist(app / 'Info.plist', change)
    yield 'wrong product', info(lambda v: v.update(CFBundleIdentifier='com.example.other'))
    yield 'dev identity in Release', info(lambda v: v.update(CFBundleIdentifier='com.wovenmatter.companion.dev'))
    yield 'dev name in Release', info(lambda v: v.update(CFBundleDisplayName='Woven Matter Dev'))
    yield 'unexpanded build setting', info(lambda v: v.update(CFBundleDisplayName='$(WOVENMATTER_DISPLAY_NAME)'))
    yield 'unexpanded version', info(lambda v: v.update(CFBundleVersion='$(CURRENT_PROJECT_VERSION)'))
    yield 'invalid build number', info(lambda v: v.update(CFBundleVersion='19a'))
    yield 'four-part build number', info(lambda v: v.update(CFBundleVersion='.'.join(['20261111', '1', '2', '3'])))  # Joined, so the public-tree scan does not read an address.
    yield 'leading-zero build number', info(lambda v: v.update(CFBundleVersion='20261111.090507'))
    yield 'iPhone only', info(lambda v: v.update(UIDeviceFamily=[1]))
    yield 'background processing', info(lambda v: v.update(UIBackgroundModes=['processing']))
    yield 'scheduler identifiers', info(lambda v: v.update(BGTaskSchedulerPermittedIdentifiers=['a']))
    yield 'missing camera purpose', info(lambda v: v.pop('NSCameraUsageDescription'))
    yield 'empty microphone purpose', info(lambda v: v.update(NSMicrophoneUsageDescription=' '))
    yield 'missing export compliance', info(lambda v: v.pop('ITSAppUsesNonExemptEncryption'))
    yield 'non-exempt encryption', info(lambda v: v.update(ITSAppUsesNonExemptEncryption=True))
    yield 'string export compliance', info(lambda v: v.update(ITSAppUsesNonExemptEncryption='NO'))
    yield 'wrong icon name', info(lambda v: v.update(CFBundleIcons={'CFBundlePrimaryIcon': {'CFBundleIconName': 'Other'}}))
    yield 'missing icon catalog', lambda app: (app / 'Assets.car').unlink()
    yield 'missing executable', lambda app: (app / 'WovenMatterCompanion').unlink()
    yield 'nested wasm', lambda app: ((app / 'Frameworks/Runtime.framework').mkdir(parents=True), (app / 'Frameworks/Runtime.framework/python.wasm').write_bytes(b'w'))
    yield 'nested embedded execution', lambda app: ((app / 'PlugIns').mkdir(), (app / 'PlugIns/EmbeddedExecution_Resources.bundle').mkdir())
    yield 'missing license', lambda app: (app / 'LUCIDE_LICENSE.txt').unlink()
    yield 'missing privacy manifest', lambda app: (app / 'PrivacyInfo.xcprivacy').unlink()
    yield 'tracking privacy manifest', privacy(lambda v: v.update(NSPrivacyTracking=True))
    yield 'tracking domains', privacy(lambda v: v.update(NSPrivacyTrackingDomains=['example.com']))
    yield 'empty required reason', privacy(lambda v: reasons(v)[1].update(NSPrivacyAccessedAPITypeReasons=[]))
    yield 'wrong reason code', privacy(lambda v: reasons(v)[0].update(NSPrivacyAccessedAPITypeReasons=['1C8F.1']))
    yield 'missing required reason', privacy(lambda v: reasons(v).pop())
    yield 'undocumented disk space', privacy(lambda v: reasons(v).append(
        {'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryDiskSpace', 'NSPrivacyAccessedAPITypeReasons': ['E174.1']}))
    yield 'repeated required reason', privacy(lambda v: reasons(v).append(dict(reasons(v)[0])))
    yield 'missing collected data', privacy(lambda v: collected(v).pop(0))
    yield 'undocumented collected data', privacy(lambda v: collected(v).append(
        {'NSPrivacyCollectedDataType': 'NSPrivacyCollectedDataTypeEmailAddress', 'NSPrivacyCollectedDataTypeLinked': True,
         'NSPrivacyCollectedDataTypeTracking': False, 'NSPrivacyCollectedDataTypePurposes': ['NSPrivacyCollectedDataTypePurposeAppFunctionality']}))
    yield 'tracking data type', privacy(lambda v: collected(v)[0].update(NSPrivacyCollectedDataTypeTracking=True))
    yield 'analytics linked', privacy(lambda v: collected(v)[3].update(NSPrivacyCollectedDataTypeLinked=True))
    yield 'wrong purpose', privacy(lambda v: collected(v)[2].update(NSPrivacyCollectedDataTypePurposes=['NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising']))
    yield 'debug fixtures', lambda app: (app / 'WovenMatterCompanion').write_bytes(b'\xcf\xfa\xed\xfe WOVENMATTER_UI_FIXTURE binary')
    yield 'fixture namespace lookup', lambda app: (app / 'WovenMatterCompanion').write_bytes(b'\xcf\xfa\xed\xfe WOVENMATTER_UI_FIXTURE_NAMESPACE\0binary')
    yield 'fixture scenario lookup', lambda app: (app / 'WovenMatterCompanion').write_bytes(b'\xcf\xfa\xed\xfe WOVENMATTER_UI_SCENARIO\0binary')
    yield 'fixture tab lookup', lambda app: (app / 'WovenMatterCompanion').write_bytes(b'\xcf\xfa\xed\xfe WOVENMATTER_UI_TAB\0binary')
    yield 'development tailnet', lambda app: (app / 'WovenMatterCompanion').write_bytes(b'\xcf\xfa\xed\xfe WOVENMATTER_DEV_TAILNET\0')
    yield 'fixtures in nested framework', lambda app: nested_binary(app, b' WOVENMATTER_UI_FIXTURE\0')


def run_cli(prefix, extra_env, arguments):
    env = {key: value for key, value in os.environ.items() if not key.startswith('PYTHON')}
    env.update(extra_env)
    return subprocess.run(prefix + [str(SCRIPT)] + arguments, capture_output=True, text=True, env=env)


def expect_failure(result, label):
    if result.returncode == 0 or 'Verified' in result.stdout:
        fail(f'{label} passed verification: {result.stdout}{result.stderr}')
    if 'iOS verification failed' not in result.stderr:
        fail(f'{label} did not report a verification failure: {result.stderr}')


with tempfile.TemporaryDirectory() as temporary:
    base = pathlib.Path(temporary)
    valid = make_app(base / 'valid')
    for prefix, env in INTERPRETERS:
        for extra in ([], ['--version', VERSION], ['--version', VERSION, '--build', BUILD]):
            result = run_cli(prefix, env, [str(valid), 'distribution'] + extra)
            if result.returncode != 0 or f'Verified distribution iOS bundle: Woven Matter {VERSION} ({BUILD})' not in result.stdout:
                fail(f'valid fixture was rejected under {prefix} {env} {extra}: {result.stderr}')
        expect_failure(run_cli(prefix, env, [str(valid), 'dev']), 'distribution bundle as dev')
        expect_failure(run_cli(prefix, env, [str(valid), 'distribution', '--version', '0.1.0']), 'unexpected version')
        expect_failure(run_cli(prefix, env, [str(valid), 'distribution', '--build', '18']), 'unexpected build number')
    dev = make_app(base / 'dev', 'dev')
    (dev / 'WovenMatterCompanion').write_bytes(b'\xcf\xfa\xed\xfe WOVENMATTER_UI_FIXTURE')
    if run_cli(*INTERPRETERS[1], [str(dev), 'dev']).returncode != 0:
        fail('a Debug bundle with fixtures was rejected for the dev profile')
    for index, (label, mutate) in enumerate(mutations()):
        app = make_app(base / f'case-{index}')
        mutate(app)
        for prefix, env in INTERPRETERS:
            expect_failure(run_cli(prefix, env, [str(app), 'distribution']), f'{label} ({prefix[1:]} {env})')
    for arguments in ([str(valid)], [str(valid), 'dev', '--signed'], [str(valid), 'distribution', '--build'],
                      [str(valid), 'distribution', '--version', '1', '--version', '1'], ['--ipa'], []):
        for prefix, env in INTERPRETERS:
            if run_cli(prefix, env, arguments).returncode != 64:
                fail(f'incomplete arguments {arguments} were not rejected with usage')

    # Exported artifact structure is checked before any signature is trusted.
    def ipa(name, entries):
        path = base / name
        with zipfile.ZipFile(path, 'w') as archive:
            for entry, data in entries:
                archive.writestr(entry, data)
        return path
    payload = [(f'Payload/WovenMatterCompanion.app/{path.relative_to(valid)}', path.read_bytes())
               for path in sorted(valid.rglob('*')) if path.is_file()]
    for label, entries in [
        ('zip traversal', payload + [('Payload/../escape.txt', b'x')]),
        ('content outside Payload', payload + [('extra/readme.txt', b'x')]),
        ('two apps', payload + [('Payload/Other.app/Info.plist', b'x')]),
        ('empty payload', [('Symbols/a.symbols', b'x')]),
    ]:
        for prefix, env in INTERPRETERS:
            expect_failure(run_cli(prefix, env, ['--ipa', str(ipa(label.replace(' ', '-') + '.ipa', entries))]), label)
    not_zip = base / 'broken.ipa'
    not_zip.write_bytes(b'not a zip')
    expect_failure(run_cli(*INTERPRETERS[2], ['--ipa', str(not_zip)]), 'unreadable IPA')
    if sys.platform == 'darwin' and shutil.which('ditto') and shutil.which('codesign'):
        # A well-formed but unsigned export reaches the signature checks and fails there.
        for prefix, env in INTERPRETERS:
            result = run_cli(prefix, env, ['--ipa', str(ipa('unsigned.ipa', payload))])
            expect_failure(result, 'unsigned IPA')
            if 'Code signature is missing or invalid' not in result.stderr:
                fail('unsigned IPA failed for an unexpected reason: ' + result.stderr)

# Signing policy, checked against representative codesign and profile data.
identifier = verifier.PROFILES['distribution'][1]
entitlements = {'application-identifier': f'{verifier.TEAM}.{identifier}', 'com.apple.developer.team-identifier': verifier.TEAM,
                'keychain-access-groups': [f'{verifier.TEAM}.{identifier}'], 'get-task-allow': False, 'beta-reports-active': True}
now = datetime.datetime(2026, 11, 1, tzinfo=datetime.timezone.utc)
profile = {'TeamIdentifier': [verifier.TEAM], 'ExpirationDate': datetime.datetime(2027, 11, 1),
           'Entitlements': {'application-identifier': entitlements['application-identifier'],
                            'keychain-access-groups': [f'{verifier.TEAM}.*'], 'get-task-allow': False, 'beta-reports-active': True}}
verifier.check_entitlements(entitlements, identifier)
verifier.check_profile(profile, entitlements, now=now)
details = 'Executable=/x\nAuthority=Apple Distribution: Example (3M84Q9NAMN)\nAuthority=Apple Worldwide Developer Relations Certification Authority\nTeamIdentifier=3M84Q9NAMN\n'
if not verifier.check_signature_details(details).startswith('Apple Distribution:'):
    fail('distribution authority was not reported')


def rejected(check, label):
    try:
        check()
    except verifier.VerificationError:
        return
    fail(label + ' was accepted')


granted = profile['Entitlements']
rejected(lambda: verifier.check_entitlements({**entitlements, 'get-task-allow': True}, identifier), 'debuggable signing')
rejected(lambda: verifier.check_entitlements({**entitlements, 'application-identifier': 'OTHER.' + identifier}, identifier), 'foreign app identifier')
rejected(lambda: verifier.check_entitlements(entitlements, identifier + '.dev'), 'Dev app identifier')
rejected(lambda: verifier.check_entitlements({**entitlements, 'com.apple.developer.icloud-services': ['CloudKit']}, identifier), 'unexpected entitlement')
rejected(lambda: verifier.check_entitlements({**entitlements, 'keychain-access-groups': ['OTHER.shared']}, identifier), 'foreign keychain group')
rejected(lambda: verifier.check_entitlements({}, identifier), 'missing entitlements')
rejected(lambda: verifier.check_profile({**profile, 'ProvisionedDevices': ['udid']}, entitlements, now=now), 'ad hoc profile')
rejected(lambda: verifier.check_profile({**profile, 'ProvisionsAllDevices': True}, entitlements, now=now), 'enterprise profile')
rejected(lambda: verifier.check_profile({**profile, 'TeamIdentifier': ['OTHER']}, entitlements, now=now), 'foreign profile')
rejected(lambda: verifier.check_profile({**profile, 'ExpirationDate': datetime.datetime(2026, 1, 1)}, entitlements, now=now), 'expired profile')
rejected(lambda: verifier.check_profile({**profile, 'Entitlements': {**granted, 'get-task-allow': True}}, entitlements, now=now), 'development profile')
rejected(lambda: verifier.check_profile({**profile, 'Entitlements': {**granted, 'beta-reports-active': False}}, entitlements, now=now), 'profile without TestFlight')
rejected(lambda: verifier.check_profile({**profile, 'Entitlements': {**granted, 'keychain-access-groups': ['OTHER.*']}}, entitlements, now=now), 'ungranted keychain group')
rejected(lambda: verifier.check_signature_details(details.replace('Apple Distribution', 'Apple Development')), 'development identity')
rejected(lambda: verifier.check_signature_details('Signature=adhoc\nTeamIdentifier=not set\n'), 'ad hoc signature')

# The committed manifest, Info.plist and export options are what the verifier requires.
verifier.check_privacy(plistlib.loads((ROOT / 'ios/Config/PrivacyInfo.xcprivacy').read_bytes()))
source_info = plistlib.loads((ROOT / 'ios/Config/Info.plist').read_bytes())
if source_info.get('ITSAppUsesNonExemptEncryption') is not False or source_info.get('CFBundleDisplayName') != '$(WOVENMATTER_DISPLAY_NAME)':
    fail('ios/Config/Info.plist must declare exempt encryption and take its name from the build configuration')
export_options = plistlib.loads((ROOT / 'ios/Config/ExportOptions.plist').read_bytes())
if (export_options.get('method'), export_options.get('destination'), export_options.get('teamID'),
        export_options.get('manageAppVersionAndBuildNumber')) != ('app-store-connect', 'export', verifier.TEAM, False):
    fail('export options must export an App Store Connect IPA locally and keep the stamped build number')

# The helper refuses unsafe requests before any build, signing, export or upload.
with tempfile.TemporaryDirectory() as temporary:
    work = pathlib.Path(temporary)
    stubs = work / 'bin'
    stubs.mkdir()
    identities = work / 'identities'
    identities.write_text('  0 valid identities found\n')
    for tool, body in [
        ('xcodebuild', 'echo xcodebuild must not run >&2; exit 99'),
        ('xcrun', 'echo xcrun must not run >&2; exit 99'),
        ('security', f'cat "{identities}"'),
        ('date', 'echo 20261111090507'),
    ]:
        (stubs / tool).write_text('#!/bin/sh\n' + body + '\n')
        (stubs / tool).chmod(0o755)
    key = work / 'AuthKey_ABCDE12345.p8'
    key.write_text('SYNTHETIC-KEY-NOT-REAL\n')  # Only its presence is checked; it is never read.
    base_env = {'PATH': f'{stubs}:/usr/bin:/bin', 'HOME': str(work / 'home'), 'LC_ALL': 'C'}
    with_key = {**base_env, 'ASC_KEY_ID': 'ABCDE12345', 'ASC_ISSUER_ID': '57246542-96fe-1a63-e053-0824d011072a', 'ASC_KEY_PATH': str(key)}
    helper = str(ROOT / 'scripts/prepare-ios-testflight.sh')
    existing = work / 'existing'
    existing.mkdir()
    fresh = str(work / 'fresh')

    def helper_run(arguments, env):
        return subprocess.run(['bash', helper] + arguments, capture_output=True, text=True, env=env)

    def refuses(arguments, env, code, message):
        result = helper_run(arguments, env)
        if result.returncode != code or message not in result.stderr or 'must not run' in result.stderr:
            fail(f'prepare-ios-testflight {arguments} returned {result.returncode}: {result.stderr}')
        if pathlib.Path(fresh).exists():
            fail(f'a refused request {arguments} created its output directory')

    no_identity = 'No Apple Distribution signing identity'
    refuses([], base_env, 64, 'usage:')
    refuses(['--archive'], base_env, 64, 'usage:')
    refuses(['--archive', fresh, '--build-number', '19'], base_env, 64, 'usage:')
    refuses(['--upload'], with_key, 64, 'usage:')
    refuses(['--unsigned-build', str(existing)], base_env, 64, 'existing artifacts are never overwritten')
    refuses(['--archive', fresh], base_env, 69, no_identity)
    refuses(['--archive', fresh], with_key, 69, no_identity)
    refuses(['--upload', fresh], base_env, 69, 'API key: not configured')
    refuses(['--upload', fresh], {**with_key, 'ASC_KEY_ID': 'bad id'}, 69, 'ASC_KEY_ID')
    refuses(['--upload', fresh], {**with_key, 'ASC_ISSUER_ID': 'issuer'}, 69, 'ASC_ISSUER_ID')
    refuses(['--upload', fresh], {**with_key, 'ASC_KEY_PATH': str(work / 'missing.p8')}, 69, 'no readable private key')
    standard = {key: value for key, value in with_key.items() if key != 'ASC_KEY_PATH'}
    refuses(['--upload', fresh], standard, 69, 'private_keys/AuthKey_ABCDE12345.p8')
    refuses(['--upload', fresh], with_key, 69, no_identity)
    identities.write_text('  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Distribution: Example (3M84Q9NAMN)"\n')
    refuses(['--archive', str(existing)], base_env, 64, 'existing artifacts are never overwritten')
    refuses(['--upload', str(existing)], with_key, 64, 'existing artifacts are never overwritten')
    for env, ready in [(base_env, 'not configured'), (with_key, f'ready (ABCDE12345, {key})')]:
        plan = helper_run(['--plan'], env)
        if (plan.returncode != 0 or f'Version:        {VERSION}' not in plan.stdout or 'now it would be 20261111.90507' not in plan.stdout
                or f'identities for {verifier.TEAM} in this keychain: 1' not in plan.stdout or ready not in plan.stdout
                or 'SYNTHETIC-KEY' in plan.stdout + plan.stderr):
            fail('the plan did not report version, build number, signing and key readiness: ' + plan.stdout + plan.stderr)
print('iOS verifier passed: valid fixtures accepted; bundle, privacy, IPA, signing and helper defects '
      'rejected with and without Python optimization.')
