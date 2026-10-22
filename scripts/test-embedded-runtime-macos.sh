#!/usr/bin/env bash
# Execute the generated offline Python worker through the production WebKit host.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || exit 0
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cache="${WOVENMATTER_TEST_CACHE_DIR:-/private/tmp/wovenmatter-validation}"
mkdir -p "$cache/ModuleCache"
fixture="$(mktemp -d "$cache/EmbeddedRuntimeSmoke.XXXXXX")"
cleanup() {
  if [ -f "$fixture/report.json" ]; then
    cp "$fixture/report.json" "$cache/embedded-runtime-report.json"
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$cache/ModuleCache" \
  "$root/ios/Sources/EmbeddedExecution/EmbeddedWorkspace.swift" \
  "$root/ios/Sources/EmbeddedExecution/EmbeddedCommandExecutor.swift" \
  "$root/ios/EmbeddedRuntime/SmokeRunner.swift" \
  "$root/scripts/test-support/EmbeddedRuntimeSmokeMain.swift" -o "$fixture/Probe"
python3 - "$fixture/Probe" "$fixture" "$root/ios/Sources/EmbeddedExecution/Resources" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

subprocess.run(sys.argv[1:], check=True, timeout=120)
report = json.loads((Path(sys.argv[2]) / "report.json").read_text())
assert report["status"] == "passed", report
for check in ("receiptReplay", "sqlitePersistence", "cancel", "symlinkRejected",
              "interruptedReplayRejected", "conflictPreserved", "fullOutputSaved",
              "pythonUnitTests", "virtualCLIFile", "libraryIntoPython", "importKeepsConflict"):
    assert report.get(check) is True, (check, report)
print(json.dumps(report, indent=2))
print("Embedded Python/WebKit smoke passed with offline runtime resources and temporary data.")
PY
