#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'Skipping AppKit termination test outside macOS.'
  exit 0
fi

cache_root="${WOVENMATTER_TEST_CACHE_DIR:-/private/tmp/wovenmatter-validation}"
mkdir -p "$cache_root/ModuleCache"
test_root="$(mktemp -d "${cache_root}/AppTerminationTests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
app="$test_root/TerminationProbe.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>wovenmatter.tests.termination</string>
<key>CFBundleExecutable</key><string>TerminationProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 6 -D COMPANION_FACADE_TESTS \
  -module-cache-path "$cache_root/ModuleCache" \
  "$repo_root/app/App/WovenMatterLifecycleDelegate.swift" \
  "$repo_root/scripts/test-support/AppTerminationTests.swift" \
  -o "$app/Contents/MacOS/TerminationProbe"
# open -W does not report a crash, so each run gets a fresh result file and a
# missing result fails. The probe's own watchdog bounds every run.
run=0
run_probe() {
  run=$((run + 1))
  local result="$test_root/result-$run"
  rm -f "$result"
  open -n -W "$app" --args "$result" "$@"
  if [ "$(cat "$result" 2>/dev/null)" != PASS ]; then
    printf 'AppKit termination probe (%s): %s\n' "$*" \
      "$(cat "$result" 2>/dev/null || printf 'exited without a result')" >&2
    exit 1
  fi
}
for mode in --normal --updater --standalone-update --staged-update; do
  run_probe "$mode"
done
# Sparkle's helper can quit the backend before the frontend, including retries
# that skip shouldPostponeRelaunchForUpdate. Exercise the real AppKit delegate.
for mode in --updater --staged-update; do
  run_probe "$mode" --backend-already-stopped
done
# Each failure cancels the quit through AppKit; the probe then quits again, as
# a Sparkle retry does, and that attempt must complete the handoff.
for failure in --backend-restart-fails --note-save-fails --browser-cancels; do
  run_probe --updater "$failure"
done
second="$test_root/OtherProbe.app"
cp -R "$app" "$second"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier wovenmatter.tests.termination.other' "$second/Contents/Info.plist"
open -n "$app" --args "$test_root/first-result" --wait-for-stop
open -n "$second" --args "$test_root/second-result" --wait-for-stop
swift "$repo_root/scripts/stop-development.swift" "$app/Contents/MacOS/TerminationProbe" --wait
swift "$repo_root/scripts/stop-development.swift" "$second/Contents/MacOS/TerminationProbe" --check
logical_app="$(python3 -c 'import sys; print(sys.argv[1].replace("/private/tmp/", "/tmp/", 1))' "$app")"
swift "$repo_root/scripts/stop-development.swift" "$logical_app/Contents/MacOS/TerminationProbe"
test "$(cat "$test_root/first-result")" = PASS
swift "$repo_root/scripts/stop-development.swift" "$second/Contents/MacOS/TerminationProbe" --check
swift "$repo_root/scripts/stop-development.swift" "$second/Contents/MacOS/TerminationProbe"
test "$(cat "$test_root/second-result")" = PASS
printf '%s\n' 'AppKit quit: passed (ordinary, immediate update, standalone update, staged update; deferred cleanup once, app exited).'
printf '%s\n' 'Update handoff: passed (backend already stopped; refused restart, failed note save and browser cancellation each cancel, then retry).'
printf '%s\n' 'Development rebuild quit: exact executable only; neighboring instance remains running.'
