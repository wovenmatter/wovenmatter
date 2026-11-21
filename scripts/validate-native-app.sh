#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: validate-native-app.sh /path/to/Woven Matter.app}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
info_plist="${app}/Contents/Info.plist"
test -f "$info_plist"
executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
main_executable="${app}/Contents/MacOS/${executable_name}"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
test -x "$main_executable"
case "$bundle_id" in
  wovenmatter.desktop|wovenmatter.desktop.dev|wovenmatter.desktop.dev.*) ;;
  *) printf 'Unexpected bundle identifier: %s\n' "$bundle_id" >&2; exit 1 ;;
esac
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$info_plist")" = true
# The app's own program is this Mac's background server (app/App/ServerEntry.swift).
# grep reads all input (no -q): an early exit would SIGPIPE nm under pipefail.
nm -j "$main_executable" | grep WovenServerKit >/dev/null

# The Woven VM helper exists on Apple silicon builds only (the guest is arm64).
vm_helper="${app}/Contents/Helpers/WovenMatterVMHelper"
if lipo -archs "$main_executable" | grep -qw arm64; then
  test -x "$vm_helper"
  codesign --verify --strict "$vm_helper"
  # grep reads all input (no -q): an early exit would SIGPIPE codesign under pipefail.
  codesign -d --entitlements :- "$vm_helper" 2>/dev/null | grep com.apple.security.virtualization >/dev/null
  # Signed with the hardened runtime by build-vm-helper.sh, like every shipped executable.
  codesign -dvv "$vm_helper" 2>&1 | grep -E 'flags=0x[0-9a-f]*\(.*runtime' >/dev/null
  # The guest files are sealed resources: exactly the committed copies, one pin for the guest.
  cmp "$repo_root/app/VMHelper/guest-version.json" "${app}/Contents/Resources/WovenVM/guest-version.json"
  for file in agent.py provision.sh egress.sh disk-cap.sh docker-archive-keyring.asc \
      woven-agent.service woven-provision.service woven-egress.service; do
    cmp "$repo_root/app/VMHelper/Guest/$file" "${app}/Contents/Resources/WovenVM/$file"
  done
fi

frameworks="$app/Contents/Frameworks"
cef="$frameworks/Chromium Embedded Framework.framework"
test -f "$cef/Resources/Info.plist"
test -x "$cef/Chromium Embedded Framework"
codesign --verify --strict "$cef"
for suffix in '' ' (GPU)' ' (Renderer)' ' (Plugin)' ' (Alerts)'; do
  helper="$frameworks/$executable_name Helper$suffix.app"
  test -x "$helper/Contents/MacOS/$executable_name Helper$suffix"
  codesign --verify --strict "$helper"
done
test -f "$app/Contents/Resources/BrowserLicenses/LICENSE.txt"
test -f "$app/Contents/Resources/BrowserLicenses/CREDITS.html"
resources="${app}/Contents/Resources"
cmp "$repo_root/docs/assets/LUCIDE_LICENSE.txt" "$resources/LUCIDE_LICENSE.txt"
test -x "${resources}/Cua/cua-driver"
test -f "${resources}/Cua/LICENSE.txt"
test -f "${resources}/Cua/THIRD-PARTY-NOTICES.md"
python3 - "${resources}/Cua" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
record = json.loads((root / 'cua-version.json').read_text())
assert hashlib.sha256((root / 'cua-driver').read_bytes()).hexdigest() == record['binarySHA256']
subprocess.run(['codesign', '--verify', '--strict', str(root / 'cua-driver')], check=True)
PY
python3 "$(cd "$(dirname "$0")" && pwd)/validate-cua.py" "${resources}/Cua/cua-driver"
test -x "${resources}/default-agent/bin/node"
test -f "${resources}/default-agent/src/main.mjs"
test -f "${resources}/default-agent/node_modules/@earendil-works/pi-coding-agent/package.json"
test -f "${resources}/default-agent/node_modules/@earendil-works/pi-durable/package.json"
pi_dependency_root() {
  "${resources}/default-agent/bin/node" --input-type=module --eval \
    'import { createRequire } from "node:module"; import { dirname } from "node:path";
     const require = createRequire(process.argv[1]);
     console.log(dirname(require.resolve(process.argv[2] + "/package.json")));' \
    "${resources}/default-agent/node_modules/@earendil-works/pi-coding-agent/package.json" "$1"
}
tui_root="$(pi_dependency_root @earendil-works/pi-tui)"
chord_root="$(pi_dependency_root @earendil-works/chord)"
test -f "$tui_root/dist/index.js"
test ! -e "$tui_root/native"
test -f "$chord_root/package.json"
for modules in "${resources}/default-agent/node_modules" "${resources}/default-agent/node_modules/@earendil-works/pi-coding-agent/node_modules" "${resources}/default-agent/node_modules/@earendil-works/pi-durable/node_modules"; do
  test ! -e "$modules/esbuild"
  test ! -e "$modules/@esbuild"
  test ! -e "$modules/.bin/esbuild"
  test ! -L "$modules/.bin/esbuild"
done
# Import the actual trimmed agent and its SDKs, not just package manifests. Importing
# starts nothing: no account checks, model discovery, credentials or provider requests.
"${resources}/default-agent/bin/node" --input-type=module --eval \
  'import { pathToFileURL } from "node:url"; await import(pathToFileURL(process.argv[1]));' \
  "${resources}/default-agent/src/agent.mjs"
test -f "${resources}/default-agent/node_modules/@anthropic-ai/claude-agent-sdk/package.json"
claude_arch="$(uname -m)"
if [ "$claude_arch" = x86_64 ]; then claude_arch=x64; fi
claude_binary="${resources}/default-agent/node_modules/@anthropic-ai/claude-agent-sdk-darwin-$claude_arch/claude"
test -x "$claude_binary"
codesign --verify --strict "$claude_binary"
# The bots runtime (Resources/bots): its sources and production dependencies only. It
# loads the default agent's SDK copy and signed Claude binary above (prepare-bots.sh), so
# it carries no copy of its own.
bots="${resources}/bots"
for file in package.json package-lock.json src/cli.ts helper/supervisor.mjs helper/agent.mjs image/Dockerfile; do
  test -f "$bots/$file"
done
test ! -e "$bots/test"
test ! -e "$bots/node_modules/vitest"
test ! -e "$bots/node_modules/typescript"
test -f "$bots/node_modules/zod/package.json"
test ! -e "$bots/node_modules/@anthropic-ai"
test ! -e "$bots/node_modules/@earendil-works"
# The bundled Node runs the bots CLI (bots have no version of their own).
"${resources}/default-agent/bin/node" "$bots/src/cli.ts" --help | grep '^Usage: ' >/dev/null
test -f "${resources}/harnesses/catalog.json"
test -f "${resources}/harnesses/woven-mcp.mjs"
test -f "${resources}/default-agent/.node-version"

# The Linux server this Mac installs over SSH (scripts/prepare-linux-server.sh): a
# static woven-server and its resources for each architecture LinuxInstall accepts.
python3 -I - "${resources}/linux-server" <<'PY'
import gzip, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1])
MACHO = {bytes.fromhex(v) for v in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
for arch, machine in (('x86_64', 0x3E), ('aarch64', 0xB7)):
    release = root / f'linux-{arch}'
    with gzip.open(release / 'woven-server.gz') as server:
        header = server.read(20)
    assert header[:4] == b'\x7fELF' and int.from_bytes(header[18:20], 'little') == machine, \
        f'linux-{arch}/woven-server.gz is not a Linux {arch} executable'
    with tarfile.open(release / 'resources.tar.gz') as resources:
        names = set(resources.getnames())
        # No Mach-O code: Linux never runs it, and Apple's notary rejects it unsigned.
        for member in resources.getmembers():
            if member.isfile() and member.size >= 4:
                with resources.extractfile(member) as file:
                    assert file.read(4) not in MACHO, f'linux-{arch}/resources.tar.gz carries Mach-O code: {member.name}'
    for required in ('node/bin/node', 'default-agent/src/main.mjs',
                     'default-agent/node_modules/@earendil-works/pi-durable/package.json', 'harnesses/catalog.json'):
        assert required in names, f'linux-{arch}/resources.tar.gz lacks {required}'
PY

printf '%s\n' 'Native app validation passed.'
