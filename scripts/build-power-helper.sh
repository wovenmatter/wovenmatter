#!/usr/bin/env bash
# Build/embed only. Registration and system power changes are never build steps.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:?usage: build-power-helper.sh /path/to/Woven Matter.app}"
helper_id="wovenmatter.desktop.power-helper"
helper_dir="$app/Contents/Library/LaunchServices"
daemon_dir="$app/Contents/Library/LaunchDaemons"
scratch="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}/wovenmatter-build}/power-helper"
mkdir -p "$helper_dir" "$daemon_dir" "$scratch"
client_id="${PRODUCT_BUNDLE_IDENTIFIER:-wovenmatter.desktop.dev}"
python3 - "$scratch/Info.plist" "$daemon_dir/$helper_id.plist" "$client_id" <<'PY'
import plistlib, re, sys
info_path, daemon_path, client_id = sys.argv[1:]
if not re.fullmatch(r'wovenmatter\.desktop(?:\.dev(?:\.[a-z0-9-]+)?)?', client_id):
    raise SystemExit('Unsupported power helper client identifier')
service = 'wovenmatter.desktop.power-helper'
with open(info_path, 'wb') as output:
    plistlib.dump({'CFBundleIdentifier': service, 'CFBundleName': 'Woven Matter Power Helper',
                  'CFBundleVersion': '1', 'CFBundleExecutable': 'WovenMatterPowerHelper',
                  'WMAllowedClients': sorted(set(['wovenmatter.desktop', 'wovenmatter.desktop.dev', client_id]))}, output)
with open(daemon_path, 'wb') as output:
    plistlib.dump({'Label': service, 'BundleProgram': 'Contents/Library/LaunchServices/WovenMatterPowerHelper',
                  'MachServices': {service: True}, 'UserName': 'root',
                  'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 5,
                  'ProcessType': 'Background'}, output)
PY
power_sources="$repo_root/app/Sources/WovenMatterClient/PowerProtection"
architectures="${ARCHS:-$(uname -m)}"
objects=()
for architecture in $architectures; do
  output="$scratch/helper-$architecture"
  xcrun swiftc -swift-version 6 -parse-as-library -O \
    -target "$architecture-apple-macos26.0" \
    -module-cache-path "$scratch/ModuleCache" \
    "$power_sources/WorkPowerPolicy.swift" \
    "$power_sources/ClosedLidLeaseController.swift" \
    "$power_sources/ClosedLidPowerProtocol.swift" \
    "$power_sources/ClosedLidSystemPower.swift" \
    "$repo_root/app/PowerHelper/Main.swift" \
    -framework Foundation -framework Security -framework IOKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$scratch/Info.plist" \
    -o "$output"
  objects+=("$output")
done
helper="$helper_dir/WovenMatterPowerHelper"
xcrun lipo -create "${objects[@]}" -output "$helper"
identity="-"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
fi
sign_options=(--force --sign "$identity" --identifier "$helper_id" --options runtime)
if [ "${CONFIGURATION:-Debug}" = Release ] && [ "$identity" != - ]; then
  sign_options+=(--timestamp)
else
  sign_options+=(--timestamp=none)
fi
codesign "${sign_options[@]}" "$helper"
codesign --verify --strict "$helper"
