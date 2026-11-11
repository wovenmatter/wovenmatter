"""Synthetic iOS app bundles that scripts/verify-ios-app.py accepts.

No Xcode build, signing identity or Apple service is used. Load this file by
path (tests run with -I, so the script directory is not on sys.path).
"""
import importlib.util
import pathlib
import plistlib
import sys

sys.dont_write_bytecode = True  # Loading the verifier must not leave caches in the source tree.
ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/verify-ios-app.py'
_spec = importlib.util.spec_from_file_location('verify_ios_app', SCRIPT)
verifier = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verifier)
VERSION, BUILD = '0.0.1', '20261111.183402'


def write_plist(path, value):
    path.write_bytes(plistlib.dumps(value))


def privacy_manifest():
    return {
        'NSPrivacyTracking': False, 'NSPrivacyTrackingDomains': [],
        'NSPrivacyAccessedAPITypes': [
            {'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategory' + category,
             'NSPrivacyAccessedAPITypeReasons': list(reasons)}
            for category, reasons in verifier.REQUIRED_REASONS.items()],
        'NSPrivacyCollectedDataTypes': [
            {'NSPrivacyCollectedDataType': 'NSPrivacyCollectedDataType' + kind,
             'NSPrivacyCollectedDataTypeLinked': linked, 'NSPrivacyCollectedDataTypeTracking': False,
             'NSPrivacyCollectedDataTypePurposes': ['NSPrivacyCollectedDataTypePurpose' + purpose for purpose in purposes]}
            for kind, (linked, purposes) in verifier.COLLECTED_DATA.items()],
    }


def make_app(directory, profile='distribution'):
    name, identifier = verifier.PROFILES[profile]
    app = directory / 'WovenMatter.app'
    app.mkdir(parents=True)
    write_plist(app / 'Info.plist', {
        'CFBundleDisplayName': name, 'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'WovenMatter',
        'CFBundleShortVersionString': VERSION, 'CFBundleVersion': BUILD, 'UIDeviceFamily': [1, 2],
        'NSMicrophoneUsageDescription': 'Dictation.', 'NSCameraUsageDescription': 'Pairing.',
        'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}},
        'ITSAppUsesNonExemptEncryption': False,
    })
    write_plist(app / 'PrivacyInfo.xcprivacy', privacy_manifest())
    (app / 'WovenMatter').write_bytes(b'\xcf\xfa\xed\xfe release binary')
    (app / 'Assets.car').write_bytes(b'car')
    (app / 'LUCIDE_LICENSE.txt').write_text('ISC')
    return app
