#!/usr/bin/env bash
# Build libsmb2.so for Linux (host architecture) from the UNMODIFIED
# upstream libsmb2 sources vendored at third_party/libsmb2.
#
# Output (under build/native/dist/):
#   libsmb2_linux-x86_64.so   (when run on an x86_64 host)
#   libsmb2_linux-aarch64.so  (when run on an aarch64 host)
#
# Kerberos is explicitly disabled so the .so has no runtime dependency
# beyond libc — libsmb2 then authenticates via its built-in NTLMSSP.
#
# Requirements: gcc/clang, CMake >= 3.16.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/libsmb2"
OUT="$ROOT/build/native/linux"
DIST="$ROOT/build/native/dist"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|aarch64) ;;
  *) echo "error: unsupported Linux arch: $ARCH (expected x86_64 or aarch64)" >&2
     exit 1 ;;
esac

mkdir -p "$DIST"
rm -rf "$OUT"

echo "── building Linux $ARCH"
cmake -S "$SRC" -B "$OUT" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_EXAMPLES=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_LibKrb5=TRUE \
  -DHAVE_LIBKRB5=0 \
  -DHAVE_GSSAPI_GSSAPI_H=0 \
  >/dev/null
cmake --build "$OUT" -j >/dev/null

# CMake emits libsmb2.so.<version> with libsmb2.so symlinks — ship the
# real file under the plain loader name used by DynamicLibrary.open.
so="$(readlink -f "$OUT/lib/libsmb2.so")"
strip --strip-unneeded -o "$DIST/libsmb2_linux-$ARCH.so" "$so"
echo "── wrote $DIST/libsmb2_linux-$ARCH.so"
