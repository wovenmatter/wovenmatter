#!/usr/bin/env python3
"""Paired whole-module comparison with identical production compiler settings."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

base = os.environ['COMPARE_BASE']
variant = os.environ['COMPARE_VARIANT']
assert re.fullmatch('[0-9a-f]{40}', base) and variant in ('baseline', 'candidate')
subprocess.run(['git', 'merge-base', '--is-ancestor', base, 'HEAD'], check=True)
changed = subprocess.check_output(['git', 'diff', '--name-only', base, 'HEAD', '--', 'app/'], text=True).splitlines()
assert changed and all(p.endswith('.swift') for p in changed), 'Comparison expects a source-only optimization'
if variant == 'baseline':
    subprocess.run(['git', 'restore', '--source', base, '--', *changed], check=True)
output = Path(os.environ['RUNNER_TEMP']) / 'release-cache-evidence'
output.mkdir(parents=True, exist_ok=True)
manifest = {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in changed if Path(p).is_file()}
(output / 'source-manifest.json').write_text(json.dumps(manifest, indent=2))
subprocess.run(['python3', 'scripts/benchmark-release-cache.py', 'warm-edit'], check=True)
p = output / 'measurement.json'
d = json.loads(p.read_text())
d.update(variant=variant, repeat=int(os.environ['COMPARE_REPEAT']), base=base, changed=changed)
p.write_text(json.dumps(d, indent=2) + '\n')
print('compile-comparison',json.dumps(d))
