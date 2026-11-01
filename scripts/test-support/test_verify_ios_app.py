"""The iOS artifact verifier must fail closed, including under Python optimization.

Fixtures are synthetic bundles: no Xcode build, signing identity, or Apple service
is used. Each defect runs through the real command-line entry point with normal,
`-O` and PYTHONOPTIMIZE interpreters, so a check written as `assert` would pass
silently and fail this test.
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
ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/verify-ios-app.py'
spec = importlib.util.spec_from_file_location('verify_ios_app', SCRIPT)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

INTERPRETERS = [
    ([sys.executable, '-I'], {}),
    ([sys.executable, '-I', '-O'], {}),
    ([sys.executable], {'PYTHONOPTIMIZE': '2'}),
]


def fail(message):
    raise SystemExit('FAIL: ' + message)


def write_plist(path, value):
    path.write_bytes(plistlib.dumps(value))


def make_app(directory, profile='distribution'):
    name, identifier = verifier.PROFILES[profile]
    app = directory / 'WovenMatterCompanion.app'
    app.mkdir(parents=True)
    write_plist(app / 'Info.plist', {
        'CFBundleDisplayName': name, 'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'WovenMatterCompanion',
        'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '19',
        'NSMicrophoneUsageDescription': 'Dictation.', 'NSCameraUsageDescription': 'Pairing.',
        'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}},
    })
    write_plist(app / 'PrivacyInfo.xcprivacy', {
        'NSPrivacyTracking': False, 'NSPrivacyTrackingDomains': [],
        'NSPrivacyAccessedAPITypes': [
            {'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategory' + category, 'NSPrivacyAccessedAPITypeReasons': ['X.1']}
            for category in verifier.REQUIRED_REASONS],
    })
    (app / 'WovenMatterCompanion').write_bytes(b'\xcf\xfa\xed\xfe release binary')
    (app / 'Assets.car').write_bytes(b'car')
    (app / 'LUCIDE_LICENSE.txt').write_text('ISC')
    return app


def edit_plist(path, change):
    value = plistlib.loads(path.read_bytes())
    change(value)
    write_plist(path, value)


def mutations():
    yield 'wrong product', lambda app: edit_plist(app / 'Info.plist', lambda v: v.update(CFBundleIdentifier='com.example.other'))
    yield 'unexpanded build setting', lambda app: edit_plist(app / 'Info.plist', lambda v: v.update(CFBundleVersion='$(CURRENT_PROJECT_VERSION)'))
    yield 'invalid build number', lambda app: edit_plist(app / 'Info.plist', lambda v: v.update(CFBundleVersion='19a'))
    yield 'background processing', lambda app: edit_plist(app / 'Info.plist', lambda v: v.update(UIBackgroundModes=['processing']))
    yield 'scheduler identifiers', lambda app: edit_plist(app / 'Info.plist', lambda v: v.update(BGTaskSchedulerPermittedIdentifiers=['a']))
    yield 'missing camera purpose', lambda app: edit_plist(app / 'Info.plist', lambda v: v.pop('NSCameraUsageDescription'))
    yield 'non-boolean export compliance', lambda app: edit_plist(app / 'Info.plist', lambda v: v.update(ITSAppUsesNonExemptEncryption='NO'))
    yield 'missing icon catalog', lambda app: (app / 'Assets.car').unlink()
    yield 'missing executable', lambda app: (app / 'WovenMatterCompanion').unlink()
    yield 'nested wasm', lambda app: ((app / 'Frameworks/Runtime.framework').mkdir(parents=True), (app / 'Frameworks/Runtime.framework/python.wasm').write_bytes(b'w'))
    yield 'nested embedded execution', lambda app: ((app / 'PlugIns').mkdir(), (app / 'PlugIns/EmbeddedExecution_Resources.bundle').mkdir())
    yield 'missing license', lambda app: (app / 'LUCIDE_LICENSE.txt').unlink()
    yield 'tracking privacy manifest', lambda app: edit_plist(app / 'PrivacyInfo.xcprivacy', lambda v: v.update(NSPrivacyTracking=True))
    yield 'empty required reason', lambda app: edit_plist(app / 'PrivacyInfo.xcprivacy', lambda v: v['NSPrivacyAccessedAPITypes'][1].update(NSPrivacyAccessedAPITypeReasons=[]))
    yield 'debug fixtures', lambda app: (app / 'WovenMatterCompanion').write_bytes(b'binary WOVENMATTER_UI_FIXTURE binary')
    yield 'fixture namespace lookup', lambda app: (app / 'WovenMatterCompanion').write_bytes(b'binary WOVENMATTER_UI_FIXTURE_NAMESPACE\0binary')
    yield 'fixture tab lookup', lambda app: (app / 'WovenMatterCompanion').write_bytes(b'binary WOVENMATTER_UI_TAB\0binary')


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
        result = run_cli(prefix, env, [str(valid), 'distribution'])
        if result.returncode != 0 or 'Verified distribution iOS bundle: Woven Matter 0.1.0 (19)' not in result.stdout:
            fail(f'valid fixture was rejected under {prefix} {env}: {result.stderr}')
        if 'not declared' not in result.stdout:
            fail('missing export-compliance declaration was not reported')
        expect_failure(run_cli(prefix, env, [str(valid), 'dev']), 'distribution bundle as dev')
    dev = make_app(base / 'dev', 'dev')
    (dev / 'WovenMatterCompanion').write_bytes(b'WOVENMATTER_UI_FIXTURE')
    if run_cli(*INTERPRETERS[1], [str(dev), 'dev']).returncode != 0:
        fail('a Debug bundle with fixtures was rejected for the dev profile')
    for index, (label, mutate) in enumerate(mutations()):
        app = make_app(base / f'case-{index}')
        mutate(app)
        for prefix, env in INTERPRETERS:
            expect_failure(run_cli(prefix, env, [str(app), 'distribution']), f'{label} ({prefix[1:]} {env})')
    for prefix, env in INTERPRETERS:
        if run_cli(prefix, env, [str(valid)]).returncode != 64:
            fail('incomplete arguments were not rejected with usage')

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


rejected(lambda: verifier.check_entitlements({**entitlements, 'get-task-allow': True}, identifier), 'debuggable signing')
rejected(lambda: verifier.check_entitlements({**entitlements, 'application-identifier': 'OTHER.' + identifier}, identifier), 'foreign app identifier')
rejected(lambda: verifier.check_entitlements({**entitlements, 'com.apple.developer.icloud-services': ['CloudKit']}, identifier), 'unexpected entitlement')
rejected(lambda: verifier.check_entitlements({**entitlements, 'keychain-access-groups': ['OTHER.shared']}, identifier), 'foreign keychain group')
rejected(lambda: verifier.check_entitlements({}, identifier), 'missing entitlements')
rejected(lambda: verifier.check_profile({**profile, 'ProvisionedDevices': ['udid']}, entitlements, now=now), 'ad hoc profile')
rejected(lambda: verifier.check_profile({**profile, 'ProvisionsAllDevices': True}, entitlements, now=now), 'enterprise profile')
rejected(lambda: verifier.check_profile({**profile, 'TeamIdentifier': ['OTHER']}, entitlements, now=now), 'foreign profile')
rejected(lambda: verifier.check_profile({**profile, 'ExpirationDate': datetime.datetime(2026, 1, 1)}, entitlements, now=now), 'expired profile')
rejected(lambda: verifier.check_profile({**profile, 'Entitlements': {**profile['Entitlements'], 'get-task-allow': True}}, entitlements, now=now), 'development profile')
rejected(lambda: verifier.check_profile({**profile, 'Entitlements': {**profile['Entitlements'], 'keychain-access-groups': ['OTHER.*']}}, entitlements, now=now), 'ungranted keychain group')
rejected(lambda: verifier.check_signature_details(details.replace('Apple Distribution', 'Apple Development')), 'development identity')
rejected(lambda: verifier.check_signature_details('Signature=adhoc\nTeamIdentifier=not set\n'), 'ad hoc signature')

# The preparation helper refuses unsafe requests before any build, signing or export.
with tempfile.TemporaryDirectory() as temporary:
    stubs = pathlib.Path(temporary) / 'bin'
    stubs.mkdir()
    for tool, body in [('xcodebuild', 'echo xcodebuild must not run >&2; exit 99'), ('security', 'exit 0')]:
        (stubs / tool).write_text('#!/bin/sh\n' + body + '\n')
        (stubs / tool).chmod(0o755)
    env = {**os.environ, 'PATH': f'{stubs}:/usr/bin:/bin'}
    helper = str(ROOT / 'scripts/prepare-ios-testflight.sh')
    existing = pathlib.Path(temporary) / 'existing'
    existing.mkdir()
    fresh = str(pathlib.Path(temporary) / 'fresh')
    for arguments, code in [
        (['--archive', fresh], 64), (['--archive', fresh, '--build-number', '19a'], 64),
        (['--archive', fresh, '--build-number', '0'], 64), (['--archive', str(existing), '--build-number', '19'], 69),
        (['--archive', fresh, '--build-number', '19'], 69), (['--unsigned-build', str(existing)], 64), (['--upload'], 64),
    ]:
        result = subprocess.run(['bash', helper] + arguments, capture_output=True, text=True, env=env)
        if result.returncode != code or 'xcodebuild must not run' in result.stderr:
            fail(f'prepare-ios-testflight {arguments} returned {result.returncode}: {result.stderr}')
    if pathlib.Path(fresh).exists():
        fail('a refused archive request created its output directory')
    plan = subprocess.run(['bash', helper, '--plan'], capture_output=True, text=True, env=env)
    if plan.returncode != 0 or 'Committed build number:' not in plan.stdout or 'identities for 3M84Q9NAMN in this keychain: 0' not in plan.stdout:
        fail('the plan did not report version, build and signing readiness: ' + plan.stdout + plan.stderr)
export_options = plistlib.loads((ROOT / 'ios/Config/ExportOptions.plist').read_bytes())
if export_options.get('destination') != 'export' or export_options.get('manageAppVersionAndBuildNumber') is not False:
    fail('export options must export locally and keep the explicit build number')
print('iOS verifier passed: valid fixtures accepted; bundle, IPA and signing defects rejected with and without Python optimization.')
