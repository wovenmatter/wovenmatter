"""Exercise the actual parallel release orchestration with offline service stubs."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'scripts/build-release.sh').read_text()
start = source.index('# The app is already signed, notarized and stapled.')
end = source.index("release_status 'Distribution artifacts ready'", start)
block = source[start:end]
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    (root / 'scripts').mkdir()
    (root / 'tools').mkdir()
    generator = root / 'scripts/generate-update-feed.sh'
    generator.write_text('''#!/usr/bin/env bash
set -euo pipefail
if [ "${WOVENMATTER_UPDATE_PREPARE_ONLY:-0}" = 1 ]; then
  trap 'echo stopped >> "$EVENTS"; exit 130' TERM INT
  echo prepare-start >> "$EVENTS"
  sleep 0.3
  if [ "$MODE" = delta-failure ]; then exit 1; fi
  echo prepare-done >> "$EVENTS"
else
  grep -qx staple "$EVENTS"
  grep -qx prepare-done "$EVENTS"
  echo final-feed >> "$EVENTS"
fi
''')
    manifest = root / 'scripts/generate-release-manifest.sh'
    manifest.write_text('#!/bin/sh\nexit 0\n')
    for script in (generator, manifest): script.chmod(0o755)
    for name in ('xcrun', 'spctl'):
        tool = root / 'tools' / name
        tool.write_text('#!/bin/sh\nif [ "$1 $2" = "stapler staple" ]; then echo staple >> "$EVENTS"; fi\nexit 0\n')
        tool.chmod(0o755)
    for mode in ('success', 'notary-failure', 'delta-failure'):
        events = root / f'{mode}.events'
        dmg = root / f'{mode}.dmg'
        dmg.write_bytes(b'immutable input')
        command = '''set -euo pipefail
release_status() { :; }
notarize() {
  for attempt in {1..30}; do
    if grep -qx prepare-start "$EVENTS" 2>/dev/null; then break; fi
    sleep 0.01
  done
  echo notary >> "$EVENTS"
  if [ "$MODE" = notary-failure ]; then return 1; fi
}
version=1.2.3
build_number=42
release_root="$ROOT"
output_dir="$ROOT"
dmg="$DMG"
''' + block
        result = subprocess.run(['bash', '-c', command], cwd=root, timeout=10,
            env=dict(os.environ, PATH=str(root / 'tools') + os.pathsep + os.environ['PATH'],
                     ROOT=str(root), DMG=str(dmg), EVENTS=str(events), MODE=mode,
                     WOVENMATTER_UPDATE_HISTORY=str(root)), capture_output=True, text=True)
        recorded = events.read_text().splitlines()
        assert (result.returncode == 0) == (mode == 'success'), result
        assert ('final-feed' in recorded) == (mode == 'success'), recorded
        if mode == 'success':
            assert recorded.index('notary') < recorded.index('prepare-done'), recorded
            assert recorded.index('staple') < recorded.index('final-feed'), recorded
        if mode == 'notary-failure':
            assert 'stopped' in recorded and 'prepare-done' not in recorded, recorded
print('Parallel release: overlap proven; final feed waits for staple and delta success; notary failure terminates its owned worker.')
