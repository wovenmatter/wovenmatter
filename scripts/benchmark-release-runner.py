#!/usr/bin/env python3
"""Repeat fresh-runner Release builds on identical source and Xcode versions."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

runner=os.environ['BENCHMARK_RUNNER']
replica=os.environ['BENCHMARK_REPLICA']
assert runner in ('macos-26','macos-26-xlarge') and replica in ('1','2')
root=Path(os.environ['RUNNER_TEMP'])
output=root/'release-cache-evidence'
archive=root/'release-runner-evidence';archive.mkdir(parents=True,exist_ok=True)
source_files=subprocess.check_output(['git','ls-files','--','app/App/*.swift','app/App/**/*.swift','app/Package.swift','app/WovenMatter.xcodeproj/project.pbxproj','app/Package.resolved'],text=True).splitlines()
manifest={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in source_files}
for trial,label in enumerate(['warmup','measured-1','measured-2']):
    shutil.rmtree(output,ignore_errors=True);output.mkdir(parents=True)
    for pattern in ('wovenmatter-node-*','wovenmatter-agent-dependencies-*'):
        for p in Path(os.environ['TMPDIR']).glob(pattern):
            if p.is_dir():shutil.rmtree(p)
    sources=Path.home()/'Library/Caches/WovenMatter/SourcePackages'
    for name in ('checkouts','artifacts'):shutil.rmtree(sources/name,ignore_errors=True)
    (sources/'workspace-state.json').unlink(missing_ok=True)
    cef=root/'runner-benchmark-cef';shutil.rmtree(cef,ignore_errors=True)
    env=dict(os.environ,WOVENMATTER_CEF_CACHE_DIR=str(cef),WOVENMATTER_BENCHMARK_MARKER=f'Woven Matter Runner Trial {replica} {trial}')
    subprocess.run(['python3','scripts/benchmark-release-cache.py','warm-edit'],env=env,check=True)
    p=output/'measurement.json';d=json.loads(p.read_text())
    d.update(runner=runner,replica=replica,trial=trial,warmup=trial==0)
    assert d['source_edited'] and d['replay_misses']>=1 and d['browser_reused']
    if trial:assert d['replay_misses']==1,'Only the edited app may miss in a measured build'
    for name,digest in manifest.items():assert hashlib.sha256(Path(name).read_bytes()).hexdigest()==digest,name
    p.write_text(json.dumps(d,indent=2)+'\n')
    (output/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    shutil.copytree(output,archive/label)
    print('runner-comparison',json.dumps(d),flush=True)
