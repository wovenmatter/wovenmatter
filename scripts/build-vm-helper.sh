#!/usr/bin/env bash
# Build/embed only: compiles and signs the Woven VM helper and copies the guest
# files. Installing the launch agent and creating the VM happen at run time.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:?usage: build-vm-helper.sh /path/to/Woven Matter.app}"
helper_id="wovenmatter.desktop.vm-helper"
helper_dir="$app/Contents/Helpers"
resources_dir="$app/Contents/Resources/WovenVM"
scratch="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}/wovenmatter-build}/vm-helper"
sources="$repo_root/app/VMHelper"
shared="$repo_root/app/Sources/WovenMatterClient/WovenVM"
mkdir -p "$helper_dir" "$scratch"

# The guest is arm64 Ubuntu, so the helper exists only for Apple silicon.
case " ${ARCHS:-$(uname -m)} " in
  *" arm64 "*) ;;
  *) rm -rf "$helper_dir/WovenMatterVMHelper" "$resources_dir"; exit 0 ;;
esac

python3 - "$scratch/Info.plist" "$helper_id" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'CFBundleIdentifier': sys.argv[2], 'CFBundleName': 'Woven Matter VM Helper',
                   'CFBundleVersion': '1', 'CFBundleExecutable': 'WovenMatterVMHelper'}, output)
PY

xcrun swiftc -swift-version 6 -parse-as-library -O \
  -target arm64-apple-macos26.0 \
  -module-name WovenMatterVMHelper \
  -module-cache-path "$scratch/ModuleCache" \
  "$shared/WovenVMProtocol.swift" "$shared/WovenVMGuest.swift" \
  "$shared/WovenVMControlHTTP.swift" "$shared/QCOW2Image.swift" \
  "$sources/Main.swift" "$sources/VMHelper.swift" "$sources/Sockets.swift" \
  "$sources/HostMetrics.swift" "$sources/GuestSetup.swift" \
  -framework Foundation -framework Virtualization -framework AppKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$scratch/Info.plist" \
  -o "$scratch/WovenMatterVMHelper"

helper="$helper_dir/WovenMatterVMHelper"
# Sign a copy and rename it into place: overwriting the running helper's file
# in place would get it killed for an invalid code signature.
staged="$scratch/WovenMatterVMHelper.signed"
cp "$scratch/WovenMatterVMHelper" "$staged"
identity="-"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
fi
sign_options=(--force --sign "$identity" --identifier "$helper_id" --options runtime
  --entitlements "$sources/WovenMatterVMHelper.entitlements")
if [ "${CONFIGURATION:-Debug}" = Release ] && [ "$identity" != - ]; then
  sign_options+=(--timestamp)
else
  sign_options+=(--timestamp=none)
fi
codesign "${sign_options[@]}" "$staged"
codesign --verify --strict "$staged"
mv -f "$staged" "$helper"

rm -rf "$resources_dir"
mkdir -p "$resources_dir"
cp "$sources/guest-version.json" "$resources_dir/"
for file in agent.py provision.sh egress.sh disk-cap.sh docker-archive-keyring.asc \
    woven-agent.service woven-provision.service woven-update.service woven-egress.service; do
  cp "$sources/Guest/$file" "$resources_dir/$file"
done
