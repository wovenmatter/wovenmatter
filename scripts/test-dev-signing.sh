#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "$repo_root" <<'PY'
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile

# Exercise the launcher with fake tools: no Keychain, signing key, or app access.
root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="woven-dev-signing-",
                                 dir="/private/tmp" if Path("/private/tmp").exists() else None) as temporary:
    fixture = Path(temporary)
    binaries = fixture / "bin"
    binaries.mkdir()
    calls = fixture / "calls.jsonl"
    stub = '''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['DEV_SIGNING_CALLS'], 'a') as log:
    log.write(json.dumps([name, args]) + '\\n')
if name == 'security':
    for index in range(int(os.environ['DEV_SIGNING_IDENTITIES'])):
        print('  %d) %s "Apple Development: Fixture"' % (index + 1, str(index + 1) * 40))
elif name == 'xcodebuild':
    if os.environ.get('DEV_SIGNING_BUILD_FAIL') == '1': sys.exit(65)
    derived = Path(args[args.index('-derivedDataPath') + 1])
    product = next(v.split('=', 1)[1] for v in args if v.startswith('WOVENMATTER_DEV_PRODUCT_NAME='))
    executable = derived / ('Build/Products/Debug/' + product + '.app/Contents/MacOS/' + product)
    executable.parent.mkdir(parents=True, exist_ok=True)
    executable.write_text('fixture')
    executable.chmod(0o755)
    if os.environ.get('DEV_SIGNING_REWRITE'):
        Path(os.environ['DEV_SIGNING_REWRITE']).write_text('#!/bin/bash\\nexit 99\\n')
elif name == 'pgrep':
    backend = os.environ.get('DEV_SIGNING_BACKEND_PATH', '')
    sys.exit(0 if backend and re.search(args[1], backend + ' --backend') else 1)
'''
    for name in ('security', 'xcodebuild', 'codesign', 'pkill', 'pgrep', 'lldb', 'swift'):
        path = binaries / name
        path.write_text(stub)
        path.chmod(0o755)

    def run(cache, count, identity=None, fail=False, backend="", rewrite=False):
        calls.write_text('')
        env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                   WOVENMATTER_DEV_CACHE_DIR=str(cache), DEV_SIGNING_CALLS=str(calls),
                   DEV_SIGNING_IDENTITIES=str(count), DEV_SIGNING_BUILD_FAIL='1' if fail else '0',
                   DEV_SIGNING_BACKEND_PATH=backend,
                   DEV_SIGNING_REWRITE=str(root / "scripts/build_and_run.sh") if rewrite else "")
        env.pop('WOVENMATTER_DEV_SIGNING_IDENTITY', None)
        env.pop('WOVENMATTER_DEV_VARIANT', None)
        if identity is not None:
            env['WOVENMATTER_DEV_SIGNING_IDENTITY'] = identity
        result = subprocess.run(['bash', str(root / 'scripts/build_and_run.sh'), 'debug', '--mode', 'client', '--instance', 'signing-test'],
                                env=env, capture_output=True, text=True)
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        return result, recorded

    cache = fixture / 'signed'
    result, recorded = run(cache, 1)
    assert result.returncode == 0, result.stderr
    args = next(args for name, args in recorded if name == 'xcodebuild')
    assert 'WOVENMATTER_DEV_MODE=client' in args
    assert 'WOVENMATTER_DEV_INSTANCE=signing-test' in args
    assert 'WOVENMATTER_DEV_BUNDLE_ID=wovenmatter.desktop.dev.signing-test.client' in args
    assert 'CODE_SIGNING_ALLOWED=YES' in args and 'CODE_SIGNING_ALLOWED=NO' not in args
    assert 'CODE_SIGN_IDENTITY=' + '1' * 40 in args
    assert (cache / 'signing-test/client/signing-identity').read_text().strip() == '1' * 40

    # Keychain unavailability must not silently change the identity on a rebuild.
    result, recorded = run(cache, 0, fail=True)
    assert result.returncode == 65
    assert not any(name in ('security', 'lldb') for name, _ in recorded)
    assert 'CODE_SIGN_IDENTITY=' + '1' * 40 in next(args for name, args in recorded if name == 'xcodebuild')

    result, recorded = run(fixture / 'ambiguous', 2)
    assert result.returncode == 65 and not any(name == 'xcodebuild' for name, _ in recorded)
    result, recorded = run(fixture / 'explicit', 2, identity='2' * 40)
    assert result.returncode == 0
    assert not any(name == 'security' for name, _ in recorded)
    result, recorded = run(fixture / 'unsigned', 0)
    assert result.returncode == 0 and 'ad-hoc' in result.stderr
    assert 'CODE_SIGNING_ALLOWED=NO' in next(args for name, args in recorded if name == 'xcodebuild')
    assert not any(name == 'codesign' for name, _ in recorded)
    # A running backend may report the logical /tmp path while the build cache
    # uses /private/tmp. Neither spelling may be overwritten by a rebuild.
    executable = cache / 'signing-test/client/DerivedData/Build/Products/Debug/Woven Matter signing-test client Dev.app/Contents/MacOS/Woven Matter signing-test client Dev'
    for path in (str(executable.resolve()), str(executable.resolve()).replace('/private/tmp/', '/tmp/', 1)):
        result, recorded = run(cache, 1, backend=path)
        assert result.returncode == 75, result.stderr
        assert not any(name in ('xcodebuild', 'swift') for name, _ in recorded)
    # Editing a launcher while xcodebuild is running must not replace the
    # remaining commands or make Bash resume at a shifted byte offset.
    original_root = root
    root = fixture / 'frozen-launcher'
    (root / 'scripts').mkdir(parents=True)
    for name in ('build_and_run.sh', 'dev-build.py'):
        shutil.copy2(original_root / 'scripts' / name, root / 'scripts' / name)
    result, recorded = run(fixture / 'frozen-cache', 1, rewrite=True)
    assert result.returncode == 0, result.stderr
    assert any(name == 'lldb' for name, _ in recorded)
print('Dev signing identity selection and rebuild persistence passed.')
PY
