"""Offline checks that signing preflight discovers every native package."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_code", root / "scripts/validate-release-code.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="wovenmatter-code-test-") as temporary:
    fixture = Path(temporary)
    bundle = fixture / "App with spaces.app"
    bundle.mkdir()
    tools = fixture / "tools"
    tools.mkdir()
    stub = """#!/usr/bin/env python3
import os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
binary = Path(sys.argv[-1]).name
if name == 'file':
    print('Mach-O dynamically linked shared library' if binary == 'library' else 'Mach-O executable arm64')
elif '--verify' in sys.argv:
    sys.exit(1 if binary == 'invalid' else 0)
else:
    if binary != 'unsigned': print('Authority=Developer ID Application: Fixture', file=sys.stderr)
    if binary != 'no-timestamp': print('Timestamp=Fixture timestamp', file=sys.stderr)
    if binary not in ('no-runtime', 'library'): print('CodeDirectory flags=0x10001(host,runtime)', file=sys.stderr)
"""
    for name in ('file', 'codesign'):
        path = tools / name
        path.write_text(stub)
        path.chmod(0o755)
    previous_path = os.environ['PATH']
    os.environ['PATH'] = str(tools) + os.pathsep + previous_path
    try:
        try:
            module.validate(bundle)
            raise AssertionError('Empty bundle accepted')
        except SystemExit as error:
            assert 'No Mach-O' in str(error)
        # Include an unexpected package without relying on a binary name/suffix.
        native = bundle / 'Resources/node_modules/unexpected package/helper'
        native.parent.mkdir(parents=True)
        native.write_bytes(bytes.fromhex('cffaedfe') + b'fixture')
        (bundle / 'plain-text').write_text('Not executable code')
        (bundle / 'alias').symlink_to(native)
        module.validate(bundle)
        for name, message in (('unsigned', 'missing Developer ID'), ('no-timestamp', 'missing secure timestamp'),
                              ('no-runtime', 'missing hardened runtime'), ('invalid', 'invalid signature')):
            rejected = native.with_name(name)
            native.rename(rejected)
            try:
                module.validate(bundle)
                raise AssertionError(f'{name} accepted')
            except SystemExit as error:
                assert message in str(error), str(error)
                assert str(rejected.relative_to(bundle)) in str(error)
            rejected.rename(native)
        library = bundle / 'library'
        library.write_bytes(bytes.fromhex('cafebabe') + b'fixture')
        module.validate(bundle)
    finally:
        os.environ['PATH'] = previous_path
print('Release code preflight checks passed: discovery, identity, timestamp, runtime, signature, library, symlink.')
