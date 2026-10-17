"""Re-sign the real pinned Sparkle helpers inside a disposable app and verify it.

Only the unavailable Developer ID identity/timestamp are substituted. All signing
and nested verification run through Apple's actual codesign, never user apps.
"""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tempfile
import sys

if sys.platform != "darwin":
    print("Skipping native updater-signing fixture outside macOS.")
    raise SystemExit(0)

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='wovenmatter-updater-signing-') as temporary:
    folder = Path(temporary)
    app = folder / 'Probe.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    (app / 'Contents/Frameworks').mkdir()
    shutil.copyfile('/usr/bin/true', app / 'Contents/MacOS/Probe')
    (app / 'Contents/MacOS/Probe').chmod(0o755)
    info = dict(CFBundleIdentifier='wovenmatter.tests.updater-signing', CFBundleExecutable='Probe', CFBundlePackageType='APPL')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    tools = Path(os.environ.get('WOVENMATTER_TEST_SPARKLE_TOOLS') or subprocess.check_output([str(ROOT / 'scripts/prepare-sparkle-tools.sh')], text=True).strip())
    subprocess.run(['ditto', str(tools / 'Sparkle.framework'), str(app / 'Contents/Frameworks/Sparkle.framework')], check=True)
    # Existing Xcode build signatures must be replaced after nested helpers change.
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    wrappers = folder / 'tools'
    wrappers.mkdir()
    wrapper = wrappers / 'codesign'
    wrapper.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
with open(os.environ['SIGNING_TEST_CALLS'], 'a') as f: f.write(json.dumps(args) + '\\n')
args = ['--timestamp=none' if arg == '--timestamp' else arg for arg in args]
if '--sign' in args: args[args.index('--sign') + 1] = '-'
sys.exit(subprocess.call(['/usr/bin/codesign', *args]))
''')
    wrapper.chmod(0o755)
    calls = folder / 'calls'
    subprocess.run([str(ROOT / 'scripts/sign-release-updater.sh'), str(app), 'Developer ID Application: Fixture'], check=True,
                   env=dict(os.environ, PATH=str(wrappers) + os.pathsep + os.environ['PATH'], SIGNING_TEST_CALLS=str(calls)), capture_output=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    import json
    recorded = [json.loads(line) for line in calls.read_text().splitlines()]
    signing = [args for args in recorded if '--sign' in args]
    assert len(signing) == 6
    assert all('--timestamp' in args and args[args.index('--sign') + 1] == 'Developer ID Application: Fixture' for args in signing)
    assert signing[-1][-1] == str(app)
    assert signing[-2][-1].endswith('Sparkle.framework')
    assert '--preserve-metadata=entitlements' in signing[1]
    assert not any('--deep' in args for args in signing)
print('Nested updater signing passed: real framework/helpers/app signatures, entitlement preservation, inside-out sealing; Developer ID/timestamp substituted for this local fixture only.')
