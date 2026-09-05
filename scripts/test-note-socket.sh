#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' 'Skipping native note socket behavior tests outside macOS.'
  exit 0
fi

cache_root="${WOVENMATTER_SOCKET_TEST_CACHE_DIR:-/private/tmp/wovenmatter-functional-note-socket}"
mkdir -p "$cache_root/ModuleCache"
xcrun swiftc \
  -swift-version 6 -parse-as-library -emit-library -emit-module -module-name WovenMatterCore \
  -module-cache-path "$cache_root/ModuleCache" \
  -emit-module-path "$cache_root/WovenMatterCore.swiftmodule" \
  "$repo_root/app/Sources/WovenMatterCore/Database.swift" \
  "$repo_root/app/Sources/WovenMatterCore/NoteDocument.swift" \
  "$repo_root/app/Sources/WovenMatterCore/NoteEditingProtocol.swift" \
  -o "$cache_root/libWovenMatterCore.dylib"
xcrun swiftc \
  -swift-version 6 -parse-as-library -module-cache-path "$cache_root/ModuleCache" \
  -I "$cache_root" -L "$cache_root" -lWovenMatterCore \
  -Xlinker -rpath -Xlinker "$cache_root" \
  "$repo_root/app/App/Services/WovenNoteService.swift" \
  "$repo_root/scripts/test-support/WovenNoteSocketTests.swift" \
  -o "$cache_root/WovenNoteSocketTests"
"$cache_root/WovenNoteSocketTests"
