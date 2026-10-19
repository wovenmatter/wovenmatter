#!/usr/bin/env bash
# Tools and the embedded framework come from one Sparkle release record. The
# updater is security-critical, so the Xcode project requires that release's
# exact revision; dependency maintenance must update both records together.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
read -r version revision expected < <(python3 -c '
import json, re, sys
record = json.load(open(sys.argv[1]))
project = open(sys.argv[2]).read()
required = re.search(r"sparkle-project/Sparkle\";\s*requirement = \{ kind = revision; revision = ([0-9a-f]{40}); \}", project)
assert re.fullmatch(r"\d+\.\d+\.\d+", record["version"]) and re.fullmatch(r"[0-9a-f]{64}", record["toolsSHA256"])
if not required or required[1] != record["revision"]:
    sys.exit("The Xcode Sparkle requirement differs from app/Updater/sparkle-version.json.")
print(record["version"], record["revision"], record["toolsSHA256"])
' "$repo_root/app/Updater/sparkle-version.json" "$repo_root/app/WovenMatter.xcodeproj/project.pbxproj")
: "${revision:?}"
cache="${WOVENMATTER_SPARKLE_TOOLS_DIR:-${TMPDIR:-/tmp}/wovenmatter-sparkle-$version}"
if [ ! -f "$cache/.verified-$expected" ]; then
  temporary="$(mktemp -d)"
  trap 'rm -rf "$temporary"' EXIT
  curl --fail --location --retry 3 --silent --show-error \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
    -o "$temporary/sparkle.tar.xz"
  test "$(shasum -a 256 "$temporary/sparkle.tar.xz" | awk '{print $1}')" = "$expected"
  mkdir -p "$temporary/tools"
  tar -xf "$temporary/sparkle.tar.xz" -C "$temporary/tools"
  touch "$temporary/tools/.verified-$expected"
  rm -rf "$cache"
  mv "$temporary/tools" "$cache"
fi
printf '%s\n' "$cache"
