#!/usr/bin/env bash
# Explicit, provider-free native acceptance; never grants OS permissions.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="${WOVENMATTER_CUA_TEST_DIR:-/private/tmp/wovenmatter-cua-desktop}"
target_only=false
case "${1:-}" in --target-only) target_only=true ;; '') ;; *) echo 'usage: test-cua-desktop.sh [--target-only]' >&2; exit 64 ;; esac
mkdir -p "$scratch"
swift build --force-resolved-versions --package-path "$root/app" --scratch-path "$scratch/build" --product WovenCuaDesktopFixture
binary="$scratch/build/out/Products/Debug/WovenCuaDesktopFixture"
if [ ! -x "$binary" ]; then binary="$scratch/build/debug/WovenCuaDesktopFixture"; fi
identity="${WOVENMATTER_DEV_SIGNING_IDENTITY:-$(security find-identity -p codesigning -v | sed -nE '/"Apple Development:/s/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]{40}) .*/\1/p' | head -1)}"
test -n "$identity" || { echo 'A stable Apple Development identity is required for native permission acceptance.' >&2; exit 69; }
for role in host target; do
  if "$target_only" && [ "$role" = host ]; then continue; fi
  if [ "$role" = host ]; then name='Woven Cua Verification'; else name='Cua Target'; fi
  bundle="$scratch/$name.app"
  if [ -x "$bundle/Contents/MacOS/$name" ]; then
    swift "$root/scripts/stop-development.swift" "$bundle/Contents/MacOS/$name"
  fi
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  cp "$binary" "$bundle/Contents/MacOS/$name"
  python3 - "$bundle/Contents/Info.plist" "$name" "$role" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as output:
    plistlib.dump({'CFBundleIdentifier':'wovenmatter.desktop.dev.cua-verification.'+sys.argv[3],
      'CFBundleExecutable':sys.argv[2],'CFBundleName':sys.argv[2], 'CFBundlePackageType':'APPL',
      'CFBundleVersion':'1','NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'26.0'},output)
PY
  if [ "$role" = host ]; then "$root/scripts/prepare-cua.sh" "$bundle/Contents/Resources/Cua"; fi
  codesign --force --sign "$identity" --options runtime --timestamp=none "$bundle"
  codesign --verify --deep --strict "$bundle"
done
if "$target_only"; then echo "Disposable target prepared: $scratch/Cua Target.app"; exit 0; fi
rm -f "$scratch/report.json" "$scratch/target.json"
WM_CUA_FIXTURE_ROOT="$scratch" /usr/bin/open -n "$scratch/Woven Cua Verification.app" --env "WM_CUA_FIXTURE_ROOT=$scratch"
echo "Acceptance report: $scratch/report.json"
echo 'If needed, enable Accessibility and Screen Recording for Woven Cua Verification in System Settings, then reopen that fixture.'
python3 - "$scratch/report.json" <<'PY'
import json, pathlib, sys, time
report = pathlib.Path(sys.argv[1])
for _ in range(120):
    if report.exists():
        value = json.loads(report.read_text())
        if value.get('status') == 'passed':
            print(json.dumps(value, sort_keys=True)); sys.exit(0)
        if value.get('status') == 'failed':
            print(json.dumps(value), file=sys.stderr); sys.exit(1)
    time.sleep(0.5)
print('Native Cua acceptance is unpassed: user-controlled macOS permissions or a completed report are still required.', file=sys.stderr)
sys.exit(77)
PY
