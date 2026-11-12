"""Desktop builds use the one Xcode recorded in app/xcode-version.json."""
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
record = json.loads((ROOT / 'app/xcode-version.json').read_text())
assert set(record) == {'xcodeVersion', 'xcodeBuild', 'runner'}, record
assert re.fullmatch(r'\d+\.\d+(\.\d+)?', record['xcodeVersion'])
assert re.fullmatch(r'\d+[A-Z]\d+[a-z]?', record['xcodeBuild'])

jobs = 0
for workflow in sorted((ROOT / '.github/workflows').glob('*.yml')):
    text = workflow.read_text()
    # The owned Mac's xcode-select chooses Xcode; check-xcode.sh verifies it.
    assert 'DEVELOPER_DIR' not in text and '/Applications/Xcode' not in text, workflow.name
    assert 'xcode-27' not in text and 'macos-26' not in text, workflow.name
    for job in re.split(r'\n(?=  [\w-]+:\n)', text.split('\njobs:\n', 1)[-1]):
        if f'runs-on: [self-hosted, {record["runner"]}]' not in job:
            continue
        jobs += 1
        name = f'{workflow.name}:{job.split(":", 1)[0].strip()}'
        # The check is the first command after checkout, before anything builds.
        after = job.split('actions/checkout@', 1)[1]
        first = re.search(r'^\s+(?:- )?run:\s*(.+)$', after, re.MULTILINE)
        assert first and first.group(1).strip() == 'scripts/check-xcode.sh', (name, first and first.group(1))
assert jobs == 3, jobs  # desktop validation, mobile validation, release

with tempfile.TemporaryDirectory() as directory:
    fake = Path(directory) / 'xcodebuild'

    def check(output):
        fake.write_text(f'#!/bin/sh\nprintf "{output}"\n')
        fake.chmod(0o755)
        environment = {**os.environ, 'PATH': f'{directory}:{os.environ["PATH"]}', 'GITHUB_ACTIONS': 'true'}
        return subprocess.run([ROOT / 'scripts/check-xcode.sh'], env=environment,
                              capture_output=True, text=True).returncode

    current = f'Xcode {record["xcodeVersion"]}\\nBuild version {record["xcodeBuild"]}\\n'
    assert check(current) == 0
    assert check(f'Xcode 26.6\\nBuild version 26F100\\n') != 0
    assert check(f'Xcode {record["xcodeVersion"]}\\nBuild version 0A000\\n') != 0
print('Workflow toolchain tests passed.')
