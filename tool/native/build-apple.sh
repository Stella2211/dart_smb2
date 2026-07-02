#!/usr/bin/env bash
# Build dynamic libsmb2.xcframework bundles for macOS and iOS from the
# UNMODIFIED upstream libsmb2 sources vendored at third_party/libsmb2.
#
# Outputs (under build/native/dist/):
#   libsmb2_macos.xcframework.zip   (macOS arm64 + x86_64, universal)
#   libsmb2_ios.xcframework.zip     (iOS device arm64 + simulator arm64/x86_64)
#
# Requirements: Xcode command line tools, CMake >= 3.16.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/libsmb2"
OUT="$ROOT/build/native/apple"
DIST="$ROOT/build/native/dist"

MACOS_TARGET="12.0"
IOS_TARGET="15.0"

mkdir -p "$DIST"
rm -rf "$OUT"

# ── one CMake slice ──────────────────────────────────────────────────────────
# $1 name, $2 CMAKE_SYSTEM_NAME, $3 sysroot, $4 archs (semicolon-sep), $5 min os
#
# HAVE_LIBKRB5/HAVE_GSSAPI_GSSAPI_H are pre-seeded to 0 (build *configuration*,
# not a source modification): upstream's check_include_file finds the Apple
# SDK's krb5 headers and defines HAVE_LIBKRB5, but never adds krb5-wrapper.c
# for this platform — producing undefined krb5_* symbols at link time.
# Kerberos auth is therefore disabled on all platforms; libsmb2 authenticates
# via its built-in NTLMSSP.
build_slice() {
  local name="$1" system="$2" sysroot="$3" archs="$4" minos="$5"
  local bdir="$OUT/$name"
  echo "── building slice: $name ($archs, $sysroot)"
  cmake -S "$SRC" -B "$bdir" \
    -DCMAKE_SYSTEM_NAME="$system" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$minos" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_EXAMPLES=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE \
    -DHAVE_LIBKRB5=0 \
    -DHAVE_GSSAPI_GSSAPI_H=0 \
    >/dev/null
  cmake --build "$bdir" -j "$(sysctl -n hw.ncpu)" >/dev/null
}

# Resolve the real (non-symlink) dylib a slice produced.
slice_dylib() {
  # CMake names it libsmb2.<version>.dylib with libsmb2.dylib symlinks.
  find "$OUT/$1/lib" -name 'libsmb2*.dylib' -type f | head -1
}

# ── framework assembly ───────────────────────────────────────────────────────
# iOS frameworks are flat; macOS frameworks must use the versioned layout.
make_framework_ios() { # $1 dylib, $2 out dir, $3 min os
  local dylib="$1" fw="$2/libsmb2.framework"
  mkdir -p "$fw"
  cp "$dylib" "$fw/libsmb2"
  install_name_tool -id @rpath/libsmb2.framework/libsmb2 "$fw/libsmb2"
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>libsmb2</string>
  <key>CFBundleIdentifier</key><string>org.samba.libsmb2</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>libsmb2</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>6.1.0</string>
  <key>CFBundleVersion</key><string>6.1.0</string>
  <key>MinimumOSVersion</key><string>$3</string>
</dict>
</plist>
PLIST
}

make_framework_macos() { # $1 dylib, $2 out dir
  local dylib="$1" fw="$2/libsmb2.framework"
  mkdir -p "$fw/Versions/A/Resources"
  cp "$dylib" "$fw/Versions/A/libsmb2"
  install_name_tool -id @rpath/libsmb2.framework/Versions/A/libsmb2 \
    "$fw/Versions/A/libsmb2"
  cat > "$fw/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>libsmb2</string>
  <key>CFBundleIdentifier</key><string>org.samba.libsmb2</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>libsmb2</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>6.1.0</string>
  <key>CFBundleVersion</key><string>6.1.0</string>
  <key>LSMinimumSystemVersion</key><string>$MACOS_TARGET</string>
</dict>
</plist>
PLIST
  ln -s A "$fw/Versions/Current"
  ln -s Versions/Current/libsmb2 "$fw/libsmb2"
  ln -s Versions/Current/Resources "$fw/Resources"
}

zip_xcframework() { # $1 xcframework dir, $2 zip name
  ( cd "$(dirname "$1")" &&
    ditto -c -k --keepParent "$(basename "$1")" "$DIST/$2" )
  echo "── wrote $DIST/$2"
}

# ── macOS ────────────────────────────────────────────────────────────────────
build_slice macos Darwin macosx "arm64;x86_64" "$MACOS_TARGET"
mkdir -p "$OUT/fw/macos"
make_framework_macos "$(slice_dylib macos)" "$OUT/fw/macos"
rm -rf "$OUT/libsmb2_macos.xcframework"
xcodebuild -create-xcframework \
  -framework "$OUT/fw/macos/libsmb2.framework" \
  -output "$OUT/libsmb2_macos.xcframework"
zip_xcframework "$OUT/libsmb2_macos.xcframework" libsmb2_macos.xcframework.zip

# ── iOS ──────────────────────────────────────────────────────────────────────
build_slice ios-device iOS iphoneos "arm64" "$IOS_TARGET"
build_slice ios-sim iOS iphonesimulator "arm64;x86_64" "$IOS_TARGET"
mkdir -p "$OUT/fw/ios-device" "$OUT/fw/ios-sim"
make_framework_ios "$(slice_dylib ios-device)" "$OUT/fw/ios-device" "$IOS_TARGET"
make_framework_ios "$(slice_dylib ios-sim)" "$OUT/fw/ios-sim" "$IOS_TARGET"
rm -rf "$OUT/libsmb2_ios.xcframework"
xcodebuild -create-xcframework \
  -framework "$OUT/fw/ios-device/libsmb2.framework" \
  -framework "$OUT/fw/ios-sim/libsmb2.framework" \
  -output "$OUT/libsmb2_ios.xcframework"
zip_xcframework "$OUT/libsmb2_ios.xcframework" libsmb2_ios.xcframework.zip

echo "Done. Artifacts in $DIST"
