#!/usr/bin/env bash
# Build libsmb2.so for Android (arm64-v8a, armeabi-v7a, x86_64) from the
# UNMODIFIED upstream libsmb2 sources vendored at third_party/libsmb2.
#
# Outputs (under build/native/dist/):
#   libsmb2_android-arm64-v8a.so
#   libsmb2_android-armeabi-v7a.so
#   libsmb2_android-x86_64.so
#
# Requirements: Android NDK (ANDROID_NDK_HOME or ANDROID_NDK_ROOT),
# CMake >= 3.16.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/libsmb2"
OUT="$ROOT/build/native/android"
DIST="$ROOT/build/native/dist"

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$NDK" ]]; then
  echo "error: set ANDROID_NDK_HOME (or ANDROID_NDK_ROOT)" >&2
  exit 1
fi

# Matches the plugin's minSdk in android/build.gradle.kts.
ANDROID_PLATFORM="android-24"
ABIS=(arm64-v8a armeabi-v7a x86_64)

mkdir -p "$DIST"
rm -rf "$OUT"

STRIP="$(find "$NDK/toolchains/llvm/prebuilt" -name llvm-strip | head -1)"
if [[ -z "$STRIP" ]]; then
  echo "error: llvm-strip not found under $NDK/toolchains/llvm/prebuilt" >&2
  exit 1
fi

for ABI in "${ABIS[@]}"; do
  echo "── building Android $ABI"
  bdir="$OUT/$ABI"
  # `-include errno.h` is build configuration, not a source change: at
  # libsmb2-6.1 compat.c's Android API<28 getlogin_r fallback references
  # ENXIO without pulling in <errno.h> itself, so the header is
  # force-included for every translation unit.
  cmake -S "$SRC" -B "$bdir" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-include errno.h" \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_EXAMPLES=OFF \
    -DHAVE_LIBKRB5=0 \
    -DHAVE_GSSAPI_GSSAPI_H=0 \
    >/dev/null
  cmake --build "$bdir" -j >/dev/null
  # The NDK toolchain disables versioned sonames, so the output is a
  # plain libsmb2.so.
  so="$bdir/lib/libsmb2.so"
  [[ -f "$so" ]] || so="$(find "$bdir" -name 'libsmb2.so' -type f | head -1)"
  "$STRIP" --strip-unneeded -o "$DIST/libsmb2_android-$ABI.so" "$so"
  echo "── wrote $DIST/libsmb2_android-$ABI.so"
done

echo "Done. Artifacts in $DIST"
