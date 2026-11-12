"""Desktop builds use the one Xcode recorded in app/xcode-version.json."""
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
record = json.loads((ROOT / 'app/xcode-version.json').read_text())
assert re.fullmatch(r'\d+\.\d+(\.\d+)?', record['xcodeVersion'])
assert record['developerDir'] == f'/Applications/Xcode_{record["xcodeVersion"]}.app/Contents/Developer'

jobs = 0
for workflow in sorted((ROOT / '.github/workflows').glob('*.yml')):
    text = workflow.read_text()
    # Every copy of the Xcode selection is the recorded one.
    for path in re.findall(r'/Applications/Xcode[^\s/]*\.app', text):
        assert path == record['developerDir'].removesuffix('/Contents/Developer'), (workflow.name, path)
    for job in re.split(r'\n(?=  [\w-]+:\n)', text.split('\njobs:\n', 1)[-1]):
        if f'runs-on: {record["runner"]}' not in job:
            continue
        jobs += 1
        name = f'{workflow.name}:{job.split(":", 1)[0].strip()}'
        assert f'DEVELOPER_DIR: {record["developerDir"]}' in job, name
        # The check is the first command after checkout, before anything builds.
        after = job.split('actions/checkout@', 1)[1]
        first = re.search(r'^\s+(?:- )?run:\s*(.+)$', after, re.MULTILINE)
        assert first and first.group(1).strip() == 'scripts/check-xcode.sh', (name, first and first.group(1))
assert jobs >= 6, jobs  # desktop validation, release, cache benchmark, release cache, two cache measurements

with tempfile.TemporaryDirectory() as directory:
    fake = Path(directory) / 'xcodebuild'

    def check(output, developer_dir=record['developerDir']):
        fake.write_text(f'#!/bin/sh\nprintf "{output}"\n')
        fake.chmod(0o755)
        environment = {**os.environ, 'PATH': f'{directory}:{os.environ["PATH"]}',
                       'GITHUB_ACTIONS': 'true', 'DEVELOPER_DIR': developer_dir}
        return subprocess.run([ROOT / 'scripts/check-xcode.sh'], env=environment,
                              capture_output=True, text=True).returncode

    current = f'Xcode {record["xcodeVersion"]}\\nBuild version {record["xcodeBuild"]}\\n'
    assert check(current) == 0
    assert check(f'Xcode 26.6\\nBuild version 26F100\\n') != 0
    assert check(f'Xcode {record["xcodeVersion"]}\\nBuild version 0A000\\n') != 0
    assert check(current, '/Applications/Xcode.app/Contents/Developer') != 0
print('Workflow toolchain tests passed.')
