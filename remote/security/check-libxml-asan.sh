#!/usr/bin/env bash
set -euo pipefail
source_root="$1"
expected="$2"
security_root="$(cd "$(dirname "$0")" && pwd)"
build_root="$(mktemp -d /tmp/libxml-asan.XXXXXX)"
trap 'rm -rf -- "$build_root"' EXIT
cp -a "$source_root/." "$build_root/"
cd "$build_root"
autoreconf -fi
./configure --without-python --without-lzma --without-zlib --disable-shared \
  CFLAGS='-g -O1 -fsanitize=address -fno-omit-frame-pointer' \
  LDFLAGS='-fsanitize=address'
make -j4 libxml2.la
g++ -g -O1 -fsanitize=address -fno-omit-frame-pointer -Iinclude \
  "$security_root/libxml-reproducer.cc" .libs/libxml2.a -lm -o reproduce
set +e
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 ./reproduce \
  "$security_root/fixtures/CVE-2026-6653.xml" > result.log 2>&1
status=$?
set -e
if [ "$expected" = vulnerable ]; then
  [ "$status" != 0 ] && grep -q 'AddressSanitizer: heap-use-after-free' result.log
else
  [ "$status" = 0 ] && ! grep -q 'AddressSanitizer:' result.log
fi
printf 'CVE-2026-6653 ASan %s control passed.\n' "$expected"
