// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Shared fixture for the dart_smb2 integration test suite.
///
/// Each `*_test.dart` file under `test/integration/` calls [poolFromCache]
/// (or [clientFromCache]) from `setUpAll` to obtain a connected pool/client.
/// The credentials come from `test/integration/.bootstrap-cache.json`
/// written by `bootstrap.dart`, so we don't re-stand-up the Samba container
/// for every test.
///
/// The bootstrap cache also carries a `libPath` pointing at the prebuilt
/// libsmb2 binary on this dev machine. The fixture wires it into the
/// package's internal [debugLibSmb2PathOverride] in `setUpAll`, so the
/// public API can stay path-free (`Smb2Client.open()`,
/// `Smb2Pool.connect(...)`) while the tests still target the exact
/// `.dylib` / `.so` checkout the bootstrap container was provisioned
/// against.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
// ignore: implementation_imports — fixture needs the package-internal
// debugLibSmb2PathOverride to point Smb2Client/Smb2Pool at the test
// libsmb2 binary without leaking that knob to consumers.
import 'package:dart_smb2/src/ffi/native_lib.dart';

const String _cacheFile = 'test/integration/.bootstrap-cache.json';

/// Skip reason for the integration suite when the bootstrap hasn't been run
/// yet. Pass to `group(..., skip: bootstrapSkipReason)` so `dart test` shows
/// a clear message instead of failing.
String? get bootstrapSkipReason {
  if (File(_cacheFile).existsSync()) return null;
  return 'Bootstrap cache missing at $_cacheFile. '
      'Run `dart run test/integration/bootstrap.dart` first.';
}

class Smb2BootstrapCache {
  final String host;
  final String share;
  final String user;
  final String password;
  final String libPath;
  final String testFile;

  const Smb2BootstrapCache({
    required this.host,
    required this.share,
    required this.user,
    required this.password,
    required this.libPath,
    required this.testFile,
  });

  factory Smb2BootstrapCache.load() {
    final file = File(_cacheFile);
    if (!file.existsSync()) {
      throw StateError(
        'Bootstrap cache missing at $_cacheFile. '
        'Run `dart run test/integration/bootstrap.dart` first.',
      );
    }
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return Smb2BootstrapCache(
      host: json['host'] as String,
      share: json['share'] as String,
      user: json['user'] as String,
      password: json['password'] as String,
      libPath: json['libPath'] as String,
      testFile: json['testFile'] as String,
    );
  }
}

/// Idempotently point the package at the test libsmb2 binary recorded in
/// the bootstrap cache. Safe to call from every `setUpAll` — it just
/// overwrites the same path each time.
void installTestLibPath() {
  debugLibSmb2PathOverride = Smb2BootstrapCache.load().libPath;
}

/// Build a connected [Smb2Pool] from the bootstrap cache.
///
/// When the cache is missing, throws — but `setUpAll` guarded by the outer
/// `group(skip: bootstrapSkipReason)` should never run, so this is only a
/// belt-and-braces safeguard for direct invocations.
Future<Smb2Pool> poolFromCache({int workers = 2}) {
  installTestLibPath();
  final cache = Smb2BootstrapCache.load();
  return Smb2Pool.connect(
    host: cache.host,
    share: cache.share,
    user: cache.user,
    password: cache.password,
    workers: workers,
  );
}

/// Build a synchronous [Smb2Client] from the bootstrap cache. Used by the
/// `smb2_client_test.dart` suite that exercises the low-level sync API.
Smb2Client clientFromCache() {
  installTestLibPath();
  return Smb2Client.open();
}

/// The cache exposed for tests that need to read specific fields (e.g. the
/// `testFile` path or `host` for share enumeration).
Smb2BootstrapCache get bootstrapCache => Smb2BootstrapCache.load();
