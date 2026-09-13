Pod::Spec.new do |s|
  s.name             = 'dart_smb2'
  s.version          = '0.2.0'
  s.summary          = 'SMB2/3 client for Dart.'
  s.homepage         = 'https://github.com/Stella2211/dart_smb2'
  s.license          = { :type => 'BSD-3-Clause' }
  s.author           = { 'ales-drnz' => '' }
  s.source           = { :path => '.' }
  s.source_files     = 'dart_smb2/Sources/dart_smb2/**/*',
                       'dart_smb2/Sources/dart_smb2_lifecycle/**/*'
  s.public_header_files = 'dart_smb2/Sources/dart_smb2_lifecycle/include/*.h'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'

  # ── Download pre-built dynamic libsmb2.xcframework from GitHub Releases ────
  # Runs during `pod install`. The xcframework contains a dynamic
  # libsmb2.framework with @rpath install name, signed by CocoaPods at build
  # time alongside the rest of the app's frameworks.
  s.prepare_command = <<-CMD
    set -e
    RELEASE="libsmb2-r9"
    EXPECTED_SHA="0000000000000000000000000000000000000000000000000000000000000000"
    URL="https://github.com/Stella2211/dart_smb2/releases/download/${RELEASE}/libsmb2_ios.xcframework.zip"

    mkdir -p dart_smb2/Frameworks
    ZIP="dart_smb2/Frameworks/libsmb2_xcframework.zip"
    MARKER="dart_smb2/Frameworks/.libsmb2_release"
    ZERO_SHA="0000000000000000000000000000000000000000000000000000000000000000"
    DOWNLOAD_NEEDED=1

    LOCAL_ZIP="${DART_SMB2_NATIVE_DIST:-}/libsmb2_ios.xcframework.zip"
    if [ -f "$LOCAL_ZIP" ]; then
      echo "[dart_smb2] Using local libsmb2 artifact: $LOCAL_ZIP"
      rm -rf "dart_smb2/Frameworks/libsmb2.xcframework"
      rm -f "$MARKER"
      cp "$LOCAL_ZIP" "$ZIP"
      unzip -o "$ZIP" -d dart_smb2/Frameworks/
      rm -f "$ZIP"
      printf 'local:%s\n' "$RELEASE" > "$MARKER"
      DOWNLOAD_NEEDED=0
    fi

    if [ $DOWNLOAD_NEEDED -eq 1 ] &&
       [ -f "dart_smb2/Frameworks/libsmb2.xcframework/Info.plist" ] &&
       [ -f "$ZIP" ]; then
      ACTUAL_SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
      if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
        printf '%s %s\n' "$RELEASE" "$EXPECTED_SHA" > "$MARKER"
        DOWNLOAD_NEEDED=0
      else
        echo "[dart_smb2] SHA-256 mismatch, redownloading..."
        rm -rf "dart_smb2/Frameworks/libsmb2.xcframework"
        rm -f "$ZIP"
        rm -f "$MARKER"
      fi
    elif [ $DOWNLOAD_NEEDED -eq 1 ] &&
         [ -d "dart_smb2/Frameworks/libsmb2.xcframework" ]; then
      if [ -f "$MARKER" ] && [ "$EXPECTED_SHA" != "$ZERO_SHA" ] &&
         [ "$(cat "$MARKER")" = "$RELEASE $EXPECTED_SHA" ]; then
        DOWNLOAD_NEEDED=0
      else
        # An extracted framework without a matching release/checksum marker
        # may be an old r8 install. Remove it before considering r9.
        rm -rf "dart_smb2/Frameworks/libsmb2.xcframework"
        rm -f "$MARKER"
      fi
    fi

    if [ $DOWNLOAD_NEEDED -eq 1 ]; then
      if [ "$EXPECTED_SHA" = "$ZERO_SHA" ]; then
        echo "error: [dart_smb2] libsmb2-r9 checksum is not published yet; run tool/update_native_checksums.dart after downloading SHA256SUMS."
        exit 1
      fi
      echo "[dart_smb2] Downloading libsmb2_ios.xcframework.zip..."
      curl -L -f -o "$ZIP" "$URL"

      ACTUAL_SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
      if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
        rm -f "$ZIP"
        echo "error: [dart_smb2] SHA-256 verification failed!"
        exit 1
      fi

      unzip -o "$ZIP" -d dart_smb2/Frameworks/
      rm -f "$ZIP"
      printf '%s %s\n' "$RELEASE" "$EXPECTED_SHA" > "$MARKER"
    fi
  CMD

  s.vendored_frameworks = 'dart_smb2/Frameworks/libsmb2.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'ENABLE_BITCODE' => 'NO',
  }
end
