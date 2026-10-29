#!/usr/bin/env python3
"""Paired whole-module comparison with identical production compiler settings."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import shutil

base = os.environ['COMPARE_BASE']
order = os.environ['COMPARE_ORDER']
assert re.fullmatch('[0-9a-f]{40}', base) and order in ('baseline-first', 'candidate-first')
subprocess.run(['git', 'merge-base', '--is-ancestor', base, 'HEAD'], check=True)
changed = subprocess.check_output(['git', 'diff', '--name-only', base, 'HEAD', '--', 'app/'], text=True).splitlines()
assert changed and all(p.endswith('.swift') for p in changed), 'Comparison expects a source-only optimization'
root = Path(os.environ['RUNNER_TEMP'])
output = root / 'release-cache-evidence'
archive = root / 'release-compile-paired'
archive.mkdir(parents=True, exist_ok=True)
for variant in (['baseline', 'candidate'] if order == 'baseline-first' else ['candidate', 'baseline']):
    subprocess.run(['git', 'restore', '--source', base if variant == 'baseline' else 'HEAD', '--', *changed], check=True)
    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(parents=True)
    manifest = {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in changed if Path(p).is_file()}
    (output / 'source-manifest.json').write_text(json.dumps(manifest, indent=2))
    # A fresh release runner has only the five restored stores. Remove transient
    # extraction/install/checkouts left by the other half of this same-runner pair.
    for pattern in ('wovenmatter-node-*', 'wovenmatter-agent-dependencies-*'):
        for p in Path(os.environ['TMPDIR']).glob(pattern):
            if p.is_dir(): shutil.rmtree(p)
    sources = Path.home() / 'Library/Caches/WovenMatter/SourcePackages'
    for name in ('checkouts', 'artifacts'):
        shutil.rmtree(sources / name, ignore_errors=True)
    (sources / 'workspace-state.json').unlink(missing_ok=True)
    cef = root / 'paired-cef'
    shutil.rmtree(cef, ignore_errors=True)
    env = dict(os.environ, WOVENMATTER_CEF_CACHE_DIR=str(cef))
    subprocess.run(['python3', 'scripts/benchmark-release-cache.py', 'warm-edit'], env=env, check=True)
    p = output / 'measurement.json'
    d = json.loads(p.read_text())
    d.update(variant=variant, order=order, base=base, changed=changed)
    assert d['replay_misses'] == 1 and d['browser_reused'], 'The app must actually recompile in each half'
    p.write_text(json.dumps(d, indent=2) + '\n')
    shutil.copytree(output, archive / variant)
    print('compile-comparison',json.dumps(d),flush=True)
