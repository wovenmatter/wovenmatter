#!/usr/bin/env bash
# Builds the Linux server release the Mac app carries and installs over SSH:
# OUTPUT/linux-<arch>/woven-server.gz (statically linked, any distribution) and
# OUTPUT/linux-<arch>/resources.tar.gz (Node, Pi Durable with its Linux
# packages, the harness catalog and adapters, the bots runtime), for x86_64 and aarch64.
#
# It cross-compiles on this Mac with the swift.org toolchain and its Static
# Linux SDK (musl); Xcode's compiler cannot use that SDK. Every download is
# verified against server/linux-build.json and kept in the cache.
#
#   scripts/prepare-linux-server.sh OUTPUT            build what is missing or stale, then copy
#   scripts/prepare-linux-server.sh OUTPUT --prepared-only   copy what is already built; never build
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
record="$root/server/linux-build.json"
output="${1:?usage: scripts/prepare-linux-server.sh OUTPUT [--prepared-only]}"
prepared_only=false
[ "${2:-}" = --prepared-only ] && prepared_only=true
cache="${WOVEN_LINUX_BUILD_CACHE:-$HOME/Library/Caches/Woven Matter/linux-server}"
built="$cache/release"

copy_release() {
  mkdir -p "$output"
  rsync -a --delete "$built/" "$output/"
}

if "$prepared_only"; then
  [ -d "$built/linux-x86_64" ] && copy_release || true
  exit 0
fi

field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$record" "$1"; }
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
fetch() { # url sha256 destination
  if [ ! -f "$3" ] || [ "$(sha256 "$3")" != "$2" ]; then
    rm -f "$3.partial"
    curl -fsSL --retry 3 -o "$3.partial" "$1"
    [ "$(sha256 "$3.partial")" = "$2" ] || { rm -f "$3.partial"; echo "Checksum mismatch for $1" >&2; exit 1; }
    mv "$3.partial" "$3"
  fi
}

mkdir -p "$cache/downloads"
downloads="$cache/downloads"
fetch "$(field toolchainURL)" "$(field toolchainSHA256)" "$downloads/swift-toolchain.pkg"
fetch "$(field staticSDKURL)" "$(field staticSDKSHA256)" "$downloads/static-sdk.tar.gz"
fetch "$(field sqliteURL)" "$(field sqliteSHA256)" "$downloads/sqlite.zip"
node_version="$(tr -d '[:space:]' < "$root/default-agent/.node-version")"
fetch "https://nodejs.org/dist/v$node_version/node-v$node_version-linux-x64.tar.gz" "$(field nodeLinuxX64SHA256)" "$downloads/node-linux-x64.tar.gz"
fetch "https://nodejs.org/dist/v$node_version/node-v$node_version-linux-arm64.tar.gz" "$(field nodeLinuxArm64SHA256)" "$downloads/node-linux-arm64.tar.gz"

# The toolchain, unpacked from its signed package without installing it.
toolchain="$cache/toolchain-$(field toolchainSHA256)"
if [ ! -x "$toolchain/usr/bin/swift" ]; then
  pkgutil --check-signature "$downloads/swift-toolchain.pkg" | grep -qF "$(field toolchainSigner)" \
    || { echo 'The Swift toolchain package is not signed by Swift Open Source.' >&2; exit 1; }
  expanded="$cache/toolchain-expanded"
  rm -rf "$expanded" "$toolchain"
  pkgutil --expand-full "$downloads/swift-toolchain.pkg" "$expanded"
  mv "$expanded"/*-osx-package.pkg/Payload "$toolchain"
  rm -rf "$expanded"
fi
bin="$toolchain/usr/bin"
"$bin/swift" --version 2>/dev/null | grep -q "swift-$(field swiftVersion)-RELEASE" || { echo 'Unexpected Swift toolchain.' >&2; exit 1; }
sdks="$cache/sdks"
sdk_id="$(field staticSDKID)"
if ! "$bin/swift" sdk list --swift-sdks-path "$sdks" 2>/dev/null | grep -qx "$sdk_id"; then
  "$bin/swift" sdk install --swift-sdks-path "$sdks" "$downloads/static-sdk.tar.gz" --checksum "$(field staticSDKSHA256)"
fi
musl="$(dirname "$("$bin/swift" sdk configure --swift-sdks-path "$sdks" --show-configuration "$sdk_id" x86_64-swift-linux-musl | sed -n 's/^sdkRootPath: //p')")"

# A private copy of the sources, so edits made during the build do not mix in.
work="$cache/work"
rm -rf "$work/src"; mkdir -p "$work/src"
for package in protocol library server; do
  rsync -a --exclude .build --exclude .swiftpm "$root/$package/" "$work/src/$package/"
done
sqlite="$work/sqlite"
rm -rf "$sqlite"; mkdir -p "$sqlite"
unzip -q -j "$downloads/sqlite.zip" '*/sqlite3.c' '*/sqlite3.h' -d "$sqlite"

# Pi Durable's packages for Linux, installed with this Mac's verified Node.
mac_node="$("$root/scripts/prepare-default-agent.sh" --print-node-bin)"

staging="$cache/staging"
rm -rf "$staging"; mkdir -p "$staging"
for arch in x86_64 aarch64; do
  case "$arch" in x86_64) node_arch=x64 ;; aarch64) node_arch=arm64 ;; esac
  # The features the library uses from SQLite (FTS5, JSON), compiled in.
  mkdir -p "$sqlite/$arch"
  "$bin/clang" --target="$arch-unknown-linux-musl" --sysroot="$musl/$arch" -O2 -fPIC \
    -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_THREADSAFE=1 -DHAVE_USLEEP=1 \
    -c "$sqlite/sqlite3.c" -o "$sqlite/$arch/sqlite3.o"
  "$bin/llvm-ar" rcs "$sqlite/$arch/libsqlite3.a" "$sqlite/$arch/sqlite3.o"
  rm -f "$work/build-$arch/release/woven-server"
  "$bin/swift" build -c release --package-path "$work/src/server" --scratch-path "$work/build-$arch" \
    --force-resolved-versions --swift-sdks-path "$sdks" --swift-sdk "$arch-swift-linux-musl" --product woven-server \
    -Xcc "-I$sqlite" -Xlinker "-L$sqlite/$arch" -Xlinker -s
  release="$staging/linux-$arch"
  mkdir -p "$release"
  gzip -9 -n -c "$work/build-$arch/release/woven-server" > "$release/woven-server.gz"

  resources="$work/resources-$arch"
  rm -rf "$resources"; mkdir -p "$resources/node" "$resources/default-agent"
  tar -xzf "$downloads/node-linux-$node_arch.tar.gz" --strip-components=1 -C "$resources/node" \
    "node-v$node_version-linux-$node_arch/bin" "node-v$node_version-linux-$node_arch/lib" "node-v$node_version-linux-$node_arch/LICENSE"
  rsync -a --exclude=/bin --exclude=/lib --exclude=/node_modules --exclude=/test --exclude=/.build --exclude=.DS_Store \
    "$root/default-agent/" "$resources/default-agent/"
  (
    cd -P "$resources/default-agent"
    PATH="$mac_node:$PATH" npm ci --omit=dev --ignore-scripts --no-audit --no-fund --os=linux --cpu="$node_arch" --libc=glibc >/dev/null
  )
  find "$resources/default-agent/node_modules" -type f -name '*.map' -delete
  rsync -a --exclude=.DS_Store "$root/harnesses/" "$resources/harnesses/"
  # The bots runtime, so this machine can be the bots' host: its sources, the engine
  # installer and its production packages for Linux, without its own copy of the SDK it
  # loads from Pi Durable's (as prepare-bots.sh does for the Mac).
  rsync -a --exclude=/node_modules --exclude=/test --exclude=.DS_Store --exclude='*.map' "$root/bots/" "$resources/bots/"
  (
    cd -P "$resources/bots"
    PATH="$mac_node:$PATH" npm ci --omit=dev --ignore-scripts --no-audit --no-fund --os=linux --cpu="$node_arch" --libc=glibc >/dev/null
  )
  find "$resources/bots/node_modules" -type f -name '*.map' -delete
  python3 -I "$root/scripts/prune-bots-sdk.py" "$resources/bots"
  tar -czf "$release/resources.tar.gz" -C "$resources" node default-agent harnesses bots
  echo "Built $release ($(du -sh "$release" | cut -f1))"
done
rm -rf "$built"; mv "$staging" "$built"
copy_release
