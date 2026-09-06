#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' 'Skipping AppKit note editor behavior tests outside macOS.'
  exit 0
fi

cache_root="${WOVENMATTER_NOTE_TEST_CACHE_DIR:-/private/tmp/wovenmatter-functional-note-editor}"
mkdir -p "$cache_root/ModuleCache"
xcrun swiftc \
  -parse-as-library -emit-library -emit-module -module-name WovenMatterCore \
  -module-cache-path "$cache_root/ModuleCache" \
  -emit-module-path "$cache_root/WovenMatterCore.swiftmodule" \
  "$repo_root/app/Sources/WovenMatterCore/Database.swift" \
  "$repo_root/app/Sources/WovenMatterCore/NoteDocument.swift" \
  -o "$cache_root/libWovenMatterCore.dylib"
xcrun swiftc \
  -parse-as-library -module-cache-path "$cache_root/ModuleCache" \
  -I "$cache_root" -L "$cache_root" -lWovenMatterCore \
  -Xlinker -rpath -Xlinker "$cache_root" \
  "$repo_root/app/App/Views/NoteEditor.swift" \
  "$repo_root/scripts/test-support/DashboardNoteEditorTests.swift" \
  -o "$cache_root/DashboardNoteEditorTests"
"$cache_root/DashboardNoteEditorTests"
