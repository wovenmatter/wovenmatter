"""Exercise notarization outcomes without contacting Apple or using credentials."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "scripts/build-release.sh").read_text()
function = source[source.index('notarize() {'):source.index('\nditto -c -k')]
with tempfile.TemporaryDirectory(prefix="wovenmatter-notary-test-") as temporary:
    fixture = Path(temporary)
    calls = fixture / "calls.jsonl"
    tool = fixture / "xcrun"
    tool.write_text("""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['NOTARY_TEST_CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:2] == ['notarytool', 'submit']:
    print(json.dumps({'id': 'fixture-submission', 'status': os.environ['NOTARY_TEST_STATUS']}))
    sys.exit(1 if os.environ['NOTARY_TEST_STATUS'] == 'Transport failure' else 0)
elif args[:2] == ['notarytool', 'log']:
    print('fixture rejection details')
else:
    sys.exit(90)
""")
    tool.chmod(0o755)
    for status, expected in (("Accepted", 0), ("Invalid", 65), ("In Progress", 65), ("Transport failure", 1)):
        calls.write_text("")
        command = 'set -euo pipefail\nrelease_root="$NOTARY_TEST_ROOT"\n' + function + '\nnotarize fixture.zip\n'
        result = subprocess.run(["bash", "-c", command], capture_output=True, text=True,
                                env=dict(os.environ, PATH=str(fixture) + os.pathsep + os.environ["PATH"],
                                         NOTARY_TEST_ROOT=str(fixture), NOTARY_TEST_CALLS=str(calls),
                                         NOTARY_TEST_STATUS=status, WOVENMATTER_NOTARY_KEYCHAIN_PROFILE="fixture profile"))
        assert result.returncode == expected, result
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        logged = any(args[:2] == ['notarytool', 'log'] for args in recorded)
        assert logged == (status in ("Invalid", "In Progress")), recorded
        if logged:
            assert "fixture rejection details" in result.stdout
            assert recorded[-1][2] == 'fixture-submission'
        assert not list(fixture.glob('notary-response.*'))
print("Notarization checks passed: accepted, rejected, pending, transport failure, rejection diagnostics.")
