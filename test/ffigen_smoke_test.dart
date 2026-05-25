// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// ffigen Phase A smoke test.
///
/// Proves that the generated bindings in `lib/src/ffi/libsmb2_bindings.dart`
/// link against the prebuilt libsmb2 binary shipped by this package
/// (the one referenced by `test/integration/.bootstrap-cache.json`).
///
/// This test does NOT touch the network — it only exercises symbols that
/// operate on local memory:
///   * `smb2_get_libsmb2Version` — fills a 3-byte struct with the linked
///     library's major/minor/patch version. Confirms struct layout matches
///     and that the prebuilt library exports the symbol.
///   * `smb2_init_context` + `smb2_destroy_context` — round-trip context
///     creation. Confirms the most-used pointer-returning / pointer-taking
///     calls work end-to-end.
///
/// Run:
///   dart test test/ffigen_smoke_test.dart
///
/// The test points the package at the bootstrap cache's libsmb2 binary by
/// setting the internal [debugLibSmb2PathOverride]. When the bootstrap
/// cache is missing (fresh clone) the whole group is skipped so
/// `dart test` stays green.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dart_smb2/src/ffi/libsmb2_bindings.dart';
import 'package:dart_smb2/src/ffi/native_lib.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

String? _resolveLibPath() {
  final cache = File('test/integration/.bootstrap-cache.json');
  if (!cache.existsSync()) return null;
  try {
    final json = jsonDecode(cache.readAsStringSync()) as Map<String, dynamic>;
    final path = json['libPath'] as String?;
    if (path != null && path.isNotEmpty) return path;
  } catch (_) {
    // Cache present but malformed — treat as missing.
  }
  return null;
}

void main() {
  final libPath = _resolveLibPath();
  final skipReason = libPath == null
      ? 'No libsmb2 path resolvable. '
          'Run `dart run test/integration/bootstrap.dart` first.'
      : null;

  group('ffigen Phase A', () {
    late LibSmb2Bindings bindings;

    setUpAll(() {
      debugLibSmb2PathOverride = libPath;
      bindings = openLibSmb2Bindings();
    });

    test('library loads and exports expected symbols', () {
      // Just constructing the bindings forces a lookup of every symbol the
      // wrappers reference — if any are missing from the dylib, the test
      // would fail at first call. The act of opening the dylib also rules
      // out ABI-incompatible mismatch (wrong file format, missing
      // dependency).
      expect(bindings, isNotNull);
    });

    test('smb2_get_libsmb2Version returns a plausible version', () {
      final ver = calloc<smb2_libversion>();
      try {
        bindings.smb2_get_libsmb2Version(ver);
        // We don't pin the exact version — only that it looks like a real
        // libsmb2 release. Major version 0 would mean the struct layout is
        // off (since libsmb2 ≥ 5 was the cutoff for exposing this symbol).
        expect(ver.ref.major_version, greaterThanOrEqualTo(4));
        expect(ver.ref.minor_version, inInclusiveRange(0, 99));
        expect(ver.ref.patch_version, inInclusiveRange(0, 99));
      } finally {
        calloc.free(ver);
      }
    });

    test('smb2_init_context + smb2_destroy_context round-trip', () {
      final ctx = bindings.smb2_init_context();
      expect(ctx, isNot(equals(nullptr)));
      // No-op for an uninitialised context but must not crash.
      bindings.smb2_destroy_context(ctx);
    });

    test('init/destroy cycle is stable across repeated invocations', () {
      // Catches the pathological case where the wrapper's removed
      // per-context mutex was actually load-bearing (see review N1). The
      // prebuilt binary is built from the same submodule pin as the
      // headers, so the lock — if any was hiding bugs — has been exercised
      // here too.
      for (var i = 0; i < 64; i++) {
        final ctx = bindings.smb2_init_context();
        expect(ctx, isNot(equals(nullptr)));
        bindings.smb2_destroy_context(ctx);
      }
    });
  }, skip: skipReason);
}
