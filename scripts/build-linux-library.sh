#!/usr/bin/env bash
# Builds the statically linked wovenmatter-library for Linux hosts (amd64 and
# arm64; any distribution) with the pinned Swift toolchain image and Static
# Linux SDK (musl). Inputs are verified against remote/library/build-version.json.
# Output: remote/host/library/linux-<arch>/wovenmatter-library.gz and the
# uncompressed binary's wovenmatter-library.sha256, which the host bundle ships
# to installs and updates; remote-host.sh unpacks and verifies the binary there.
# Compressed, they keep the app small. --uncompressed also leaves the binary for
# local runs. See docs/DEPENDENCIES.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
record="$root/remote/library/build-version.json"
arches=(x86_64 aarch64)
output="$root/remote/host/library"
cache="${WOVENMATTER_LIBRARY_BUILD_CACHE:-${TMPDIR:-/tmp}/wovenmatter-library-build}"
mode=auto
keep=0

usage() { echo 'usage: scripts/build-linux-library.sh [--arch x86_64|aarch64] [--output DIR] [--cache DIR] [--docker|--native] [--uncompressed]' >&2; exit 64; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch) [ "$#" -ge 2 ] || usage; case "$2" in x86_64|aarch64) arches=("$2") ;; *) usage ;; esac; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output="$2"; shift 2 ;;
    --cache) [ "$#" -ge 2 ] || usage; cache="$2"; shift 2 ;;
    --docker) mode=docker; shift ;;
    --native) mode=native; shift ;;
    --uncompressed) keep=1; shift ;;
    *) usage ;;
  esac
done

field() { sed -n "s/^ *\"$1\": *\"\([^\"]*\)\",\{0,1\}$/\1/p" "$record"; }
swift_version="$(field swiftVersion)"; image="$(field swiftImage)"
sdk_id="$(field staticSDKID)"; sdk_url="$(field staticSDKURL)"; sdk_sha="$(field staticSDKSHA256)"
sqlite_url="$(field sqliteURL)"; sqlite_sha="$(field sqliteSHA256)"
[ -n "$swift_version" ] && [ -n "$image" ] && [ -n "$sdk_sha" ] && [ -n "$sqlite_sha" ] || { echo "Invalid $record" >&2; exit 1; }

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
fetch() { # url sha256 destination
  if [ ! -f "$3" ] || [ "$(sha256 "$3")" != "$2" ]; then
    rm -f "$3.partial"
    curl -fsSL --retry 3 -o "$3.partial" "$1"
    [ "$(sha256 "$3.partial")" = "$2" ] || { rm -f "$3.partial"; echo "Checksum mismatch for $1" >&2; exit 1; }
    mv "$3.partial" "$3"
  fi
}

if [ "$mode" = auto ]; then
  if command -v swift >/dev/null && swift --version 2>/dev/null | grep -q "Swift version $swift_version " \
     && [ "$(uname -s)" = Linux ]; then mode=native; else mode=docker; fi
fi

mkdir -p "$cache" "$output"
cache="$(cd "$cache" && pwd -P)"; output="$(cd "$output" && pwd -P)"

# Downloads happen on the invoking host, so the container needs no network.
if [ "${WOVENMATTER_LIBRARY_BUILD_INPUTS:-}" != verified ]; then
  fetch "$sdk_url" "$sdk_sha" "$cache/static-sdk.tar.gz"
  fetch "$sqlite_url" "$sqlite_sha" "$cache/sqlite.zip"
fi

if [ "$mode" = docker ]; then
  command -v docker >/dev/null || { echo 'Docker or the pinned Swift toolchain is required.' >&2; exit 1; }
  selection=()
  [ "${#arches[@]}" -ne 1 ] || selection=(--arch "${arches[0]}")
  [ "$keep" = 0 ] || selection+=(--uncompressed)
  exec docker run --rm -e WOVENMATTER_LIBRARY_BUILD_INPUTS=verified \
    -v "$root:/src:ro" -v "$cache:/cache" -v "$output:/out" "$image" \
    /src/scripts/build-linux-library.sh --native --cache /cache --output /out ${selection[@]+"${selection[@]}"}
fi

swift --version 2>/dev/null | grep -q "Swift version $swift_version " || { echo "Swift $swift_version is required." >&2; exit 1; }
if ! swift sdk list 2>/dev/null | grep -qx "$sdk_id"; then
  [ "$(sha256 "$cache/static-sdk.tar.gz")" = "$sdk_sha" ] || { echo 'Static SDK checksum mismatch.' >&2; exit 1; }
  swift sdk install "$cache/static-sdk.tar.gz"
fi
sdk_root="$(swift sdk configure --show-configuration "$sdk_id" x86_64-swift-linux-musl | sed -n 's/^sdkRootPath: //p')"
sdk_root="${sdk_root%/x86_64}"

# Private copy of the sources: SwiftPM may write package state beside a manifest.
work="$cache/work"
rm -rf "$work/src"; mkdir -p "$work/src"
cp -R "$root/app" "$root/shared" "$root/ios" "$work/src/"
rm -rf "$work/src/app/.build" "$work/src/shared/.build" "$work/src/ios/.build"

sqlite="$work/sqlite"
rm -rf "$sqlite"; mkdir -p "$sqlite"
[ "$(sha256 "$cache/sqlite.zip")" = "$sqlite_sha" ] || { echo 'SQLite checksum mismatch.' >&2; exit 1; }
unzip -q -j "$cache/sqlite.zip" '*/sqlite3.c' '*/sqlite3.h' -d "$sqlite"

for arch in "${arches[@]}"; do
  sysroot="$sdk_root/$arch"
  mkdir -p "$sqlite/$arch"
  # The features Apple's system SQLite provides that the library uses (FTS5, JSON).
  clang --target="$arch-unknown-linux-musl" --sysroot="$sysroot" -O2 -fPIC \
    -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_THREADSAFE=1 \
    -DHAVE_USLEEP=1 -c "$sqlite/sqlite3.c" -o "$sqlite/$arch/sqlite3.o"
  llvm-ar rcs "$sqlite/$arch/libsqlite3.a" "$sqlite/$arch/sqlite3.o"
  swift build -c release --package-path "$work/src/app" --scratch-path "$work/build-$arch" \
    --force-resolved-versions --swift-sdk "$arch-swift-linux-musl" --product wovenmatter-library \
    -Xcc "-I$sqlite" -Xlinker "-L$sqlite/$arch" -Xlinker -s
  binary="$(swift build -c release --package-path "$work/src/app" --scratch-path "$work/build-$arch" \
    --swift-sdk "$arch-swift-linux-musl" --show-bin-path)/wovenmatter-library"
  mkdir -p "$output/linux-$arch"
  install -m 0755 "$binary" "$output/linux-$arch/wovenmatter-library"
  (cd "$output/linux-$arch" && sha256sum wovenmatter-library > wovenmatter-library.sha256)
  # -n: no name or time in the header, so the same binary always packs the same bytes
  # (the host release fingerprint covers the .gz).
  gzip -9 -n -c "$output/linux-$arch/wovenmatter-library" > "$output/linux-$arch/wovenmatter-library.gz"
  [ "$keep" = 1 ] || rm -f "$output/linux-$arch/wovenmatter-library"
  echo "Built $output/linux-$arch/wovenmatter-library.gz ($(wc -c < "$output/linux-$arch/wovenmatter-library.gz") bytes from $(wc -c < "$binary"))"
done
