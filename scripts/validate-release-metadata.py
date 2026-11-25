#!/usr/bin/env python3
"""Validate the release metadata Xcode wrote into a built app's Info.plist."""
import argparse
from pathlib import Path
import plistlib
import re

PUBLIC_KEY = 'fuIqCE9IUmecB8Hjj44IcBz2XrVX/fMxenjhsTJIglI='

def verify(path, version, build, revision):
    assert re.fullmatch(r'\d+\.\d+\.\d+', version)
    assert isinstance(build, int) and build > 0
    assert re.fullmatch(r'[0-9a-f]{40}', revision)
    info = plistlib.loads(path.read_bytes())
    expected = dict(CFBundleIdentifier='wovenmatter.desktop', CFBundleShortVersionString=version,
        CFBundleVersion=str(build), WovenMatterSourceRevision=revision,
        SUFeedURL='https://github.com/wovenmatter/wovenmatter/releases/latest/download/appcast.xml',
        SUPublicEDKey=PUBLIC_KEY, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
        SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=True)
    for key, value in expected.items():
        actual = info.get(key)
        if type(actual) is not type(value) or actual != value:
            raise ValueError(f'Release metadata {key}: expected {value!r}, got {actual!r}')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['verify'])
    parser.add_argument('version')
    parser.add_argument('build', type=int)
    parser.add_argument('revision')
    parser.add_argument('--plist', type=Path)
    args = parser.parse_args()
    if args.plist is None:
        parser.error('verify requires --plist')
    verify(args.plist, args.version, args.build, args.revision)
    print(f'Release metadata verified: {args.version} build {args.build} at {args.revision}.')
