#!/usr/bin/env python3
"""Measure an unsigned production-configuration build, never publish its output."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('label')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = Path(os.environ['RUNNER_TEMP']) / 'release-cache-evidence'
output.mkdir(parents=True, exist_ok=True)
build_root = Path('/private/tmp/wovenmatter-release-build')
# Always fresh intermediates. Only the independently restored caches may help.
shutil.rmtree(build_root, ignore_errors=True)
env = dict(os.environ, WOVENMATTER_COMPILER_BUILD_ROOT=str(build_root),
           WOVENMATTER_COMPILER_CACHE=str(Path.home() / 'Library/Caches/WovenMatter/Compiler'),
           WOVENMATTER_PACKAGE_CACHE=str(Path.home() / 'Library/Caches/WovenMatter/SourcePackages'),
           WOVENMATTER_BENCHMARK_VERSION='0.0.1' if args.label != 'cold' else '0.0.0',
           WOVENMATTER_BENCHMARK_BUILD='2' if args.label != 'cold' else '1')
# Seed only unsigned browser products during the cold run. Consumers stay read-only.
if args.label == 'cold':
    env['WOVENMATTER_WRITE_BROWSER_CACHE'] = '1'
source_file = root / 'app/App/WovenMatterApp.swift'
original = source_file.read_bytes()
source_edited = args.label == 'warm-edit'
if source_edited:
    before = b'return "Woven Matter"'
    if original.count(before) != 1:
        raise SystemExit('Controlled source edit no longer matches exactly once')
    marker = os.environ.get('WOVENMATTER_BENCHMARK_MARKER', 'Woven Matter Cache Benchmark')
    assert re.fullmatch(r'[A-Za-z0-9 -]+', marker)
    source_file.write_bytes(original.replace(before, ('return ' + json.dumps(marker)).encode()))
    (output / 'source-edit.diff').write_bytes(subprocess.check_output(['git', 'diff', '--', str(source_file)]))
started = time.monotonic()
with (output / 'build.log').open('w') as log:
    proc = subprocess.Popen([str(root / 'scripts/warm-release-compiler.sh')], cwd=root,
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout:
        log.write(line)
        print(line, end='', flush=True)
    status = proc.wait()
if source_edited:
    source_file.write_bytes(original)
seconds = round(time.monotonic() - started, 3)
text = (output / 'build.log').read_text()
record = dict(label=args.label, seconds=seconds, status=status, source_edited=source_edited,
              revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              replay_hits=len(re.findall(r'Replay cache hit', text, re.I)),
              replay_misses=len(re.findall(r'Replay cache miss', text, re.I)),
              browser_reused='Reused unsigned browser products:' in text)
(output / 'measurement.json').write_text(json.dumps(record, indent=2) + '\n')
print('release-cache-benchmark ' + json.dumps(record), flush=True)
if status:
    raise SystemExit(status)
# Metadata must be regenerated even when compiler results are reused.
subprocess.run(['python3', 'scripts/validate-release-metadata.py', 'verify',
                env['WOVENMATTER_BENCHMARK_VERSION'], env['WOVENMATTER_BENCHMARK_BUILD'], record['revision'],
                '--plist', str(build_root / 'DerivedData/Build/Products/Release/Woven Matter.app/Contents/Info.plist')],
               check=True)
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
    summary.write(f"\n{args.label}: {seconds:.1f}s; compiler replay hits {record['replay_hits']}, "
                  f"misses {record['replay_misses']}; browser reused {record['browser_reused']}.\n")
