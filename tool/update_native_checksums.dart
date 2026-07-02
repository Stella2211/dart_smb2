// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Rewrites the pinned libsmb2 release tag + SHA-256 checksums in every
/// platform build file from a `SHA256SUMS` manifest produced by the
/// `native-release` GitHub workflow.
///
/// Usage:
///   `dart run tool/update_native_checksums.dart <SHA256SUMS-file> <release-tag>`
///
/// Example:
///   gh release download libsmb2-r6 --pattern SHA256SUMS
///   dart run tool/update_native_checksums.dart SHA256SUMS libsmb2-r6
///
/// Files updated:
///   linux/CMakeLists.txt        windows/CMakeLists.txt
///   android/build.gradle.kts
///   ios/dart_smb2.podspec       macos/dart_smb2.podspec
///   ios/dart_smb2/Package.swift macos/dart_smb2/Package.swift
library;

import 'dart:io';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/update_native_checksums.dart '
      '<SHA256SUMS-file> <release-tag>',
    );
    exit(64);
  }
  final sums = _parseSums(File(args[0]));
  final tag = args[1];
  if (!RegExp(r'^libsmb2-r\d+$').hasMatch(tag)) {
    _die('Release tag must look like libsmb2-r<N>, got: $tag');
  }

  String need(String artifact) =>
      sums[artifact] ?? _die('Missing $artifact in SHA256SUMS');

  // ── linux/CMakeLists.txt ─────────────────────────────────────────────
  _rewrite('linux/CMakeLists.txt', [
    _setCmakeVar('SMB2_RELEASE_VERSION', tag),
    _setCmakeVar('EXPECTED_SHA256_X86_64', need('libsmb2_linux-x86_64.so')),
    _setCmakeVar('EXPECTED_SHA256_AARCH64', need('libsmb2_linux-aarch64.so')),
  ]);

  // ── windows/CMakeLists.txt ───────────────────────────────────────────
  _rewrite('windows/CMakeLists.txt', [
    _setCmakeVar('SMB2_RELEASE_VERSION', tag),
    _setCmakeVar('EXPECTED_SHA256_X86_64', need('libsmb2_windows-x86_64.dll')),
    _setCmakeVar('EXPECTED_SHA256_ARM64', need('libsmb2_windows-arm64.dll')),
  ]);

  // ── android/build.gradle.kts ─────────────────────────────────────────
  final androidEdits = <_Edit>[
    (
      RegExp('val SMB2_RELEASE_VERSION = "libsmb2-r\\d+"'),
      'val SMB2_RELEASE_VERSION = "$tag"',
    ),
  ];
  for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
    final artifact = 'libsmb2_android-$abi.so';
    androidEdits.add(
      (
        RegExp(
          '("file"\\s+to\\s+"$artifact",\\s*\\n\\s*"sha256" to )"[0-9a-f]{64}"',
        ),
        '\$1"${need(artifact)}"',
      ),
    );
  }
  _rewrite('android/build.gradle.kts', androidEdits);

  // ── podspecs ─────────────────────────────────────────────────────────
  for (final (dir, artifact) in [
    ('ios', 'libsmb2_ios.xcframework.zip'),
    ('macos', 'libsmb2_macos.xcframework.zip'),
  ]) {
    _rewrite('$dir/dart_smb2.podspec', [
      (
        RegExp('RELEASE="libsmb2-r\\d+"'),
        'RELEASE="$tag"',
      ),
      (
        RegExp('EXPECTED_SHA="[0-9a-f]{64}"'),
        'EXPECTED_SHA="${need(artifact)}"',
      ),
    ]);
  }

  // ── Package.swift (SPM binary targets) ───────────────────────────────
  for (final (dir, artifact) in [
    ('ios', 'libsmb2_ios.xcframework.zip'),
    ('macos', 'libsmb2_macos.xcframework.zip'),
  ]) {
    _rewrite('$dir/dart_smb2/Package.swift', [
      (
        RegExp('(url: "https://[^"]+/download/)libsmb2-r\\d+(/$artifact")'),
        '\$1$tag\$2',
      ),
      (
        RegExp('checksum: "[0-9a-f]{64}"'),
        'checksum: "${need(artifact)}"',
      ),
    ]);
  }

  stdout.writeln('All build files now pin $tag.');
}

typedef _Edit = (RegExp pattern, String replacement);

Map<String, String> _parseSums(File file) {
  if (!file.existsSync()) _die('No such file: ${file.path}');
  final out = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final m = RegExp(r'^([0-9a-f]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (m != null) out[m.group(2)!] = m.group(1)!;
  }
  if (out.isEmpty) _die('No checksum entries parsed from ${file.path}');
  return out;
}

_Edit _setCmakeVar(String name, String value) => (
      RegExp('set\\($name\\s+"[^"]*"'),
      'set($name  "$value"',
    );

void _rewrite(String path, List<_Edit> edits) {
  final file = File(path);
  if (!file.existsSync()) _die('No such file: $path');
  var text = file.readAsStringSync();
  for (final (pattern, replacement) in edits) {
    final matches = pattern.allMatches(text).length;
    if (matches != 1) {
      _die(
        '$path: expected exactly 1 match for `${pattern.pattern}`, '
        'found $matches',
      );
    }
    text = text.replaceAllMapped(pattern, (m) {
      var out = replacement;
      for (var i = 1; i <= m.groupCount; i++) {
        out = out.replaceAll('\$$i', m.group(i)!);
      }
      return out;
    });
  }
  file.writeAsStringSync(text);
  stdout.writeln('Updated $path');
}

Never _die(String message) {
  stderr.writeln('error: $message');
  exit(1);
}
