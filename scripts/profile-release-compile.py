#!/usr/bin/env python3
"""Temporary compiler investigation; no release artifacts or signing credentials."""
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
output = Path(os.environ['RUNNER_TEMP']) / 'release-compiler-profile'
output.mkdir(parents=True, exist_ok=True)
(output / 'stats').mkdir(exist_ok=True)
p = root / 'app/WovenMatter.xcodeproj/project.pbxproj'
original = p.read_text()
needle = 'SWIFT_COMPILATION_MODE = wholemodule;'
assert original.count(needle) == 1
flags = '-Xfrontend -debug-time-function-bodies -Xfrontend -debug-time-expression-type-checking -Xfrontend -profile-stats-entities -Xfrontend -stats-output-dir -Xfrontend ' + str(output / 'stats')
p.write_text(original.replace(needle, needle + '\n\t\t\t\tOTHER_SWIFT_FLAGS = "$(inherited) ' + flags + '";'))
env = dict(os.environ, WOVENMATTER_COMPILER_BUILD_ROOT='/private/tmp/wovenmatter-release-build',
           WOVENMATTER_COMPILER_CACHE=str(Path.home() / 'Library/Caches/WovenMatter/Compiler'),
           WOVENMATTER_PACKAGE_CACHE=str(Path.home() / 'Library/Caches/WovenMatter/SourcePackages'))
started = time.monotonic()
try:
    with (output / 'build.log').open('w') as log:
        proc = subprocess.Popen([str(root / 'scripts/warm-release-compiler.sh')], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            log.write(line)
            print(line, end='', flush=True)
        status = proc.wait()
finally:
    p.write_text(original)
print('Profile elapsed:',time.monotonic()-started)
raise SystemExit(status)
