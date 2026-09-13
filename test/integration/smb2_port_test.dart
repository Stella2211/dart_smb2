// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be
// found in the LICENSE file.

/// Focused integration check for a non-default SMB TCP port.
///
/// Run against an already-running server with:
///
/// ```sh
/// SMB2_PORT_TEST=1 \
/// SMB2_TEST_HOST=127.0.0.1:1445 \
/// SMB2_TEST_SHARE=public \
/// SMB2_TEST_USER=smbuser \
/// SMB2_TEST_PASS=smbpass \
/// SMB2_LIB_PATH=/path/to/libsmb2 \
/// DART_SMB2_LIFECYCLE_LIBRARY=/path/to/libdart_smb2_lifecycle.dylib \
/// dart test test/integration/smb2_port_test.dart
/// ```
library;

import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:dart_smb2/src/ffi/native_lib.dart';
import 'package:test/test.dart';

void main() {
  final enabled = Platform.environment['SMB2_PORT_TEST'] == '1';
  final skipReason = enabled
      ? null
      : 'Set SMB2_PORT_TEST=1 with the SMB2_TEST_* connection settings.';

  group('SMB2 host:port connection', () {
    setUpAll(() {
      final libPath = Platform.environment['SMB2_LIB_PATH'];
      if (libPath != null && libPath.isNotEmpty) {
        debugLibSmb2PathOverride = libPath;
      }
    });

    test('connects and lists a share on the selected port', () async {
      final pool = await Smb2Pool.connect(
        host: Platform.environment['SMB2_TEST_HOST'] ?? '127.0.0.1:1445',
        share: Platform.environment['SMB2_TEST_SHARE'] ?? 'public',
        user: Platform.environment['SMB2_TEST_USER'],
        password: Platform.environment['SMB2_TEST_PASS'],
        workers: 1,
        timeoutSeconds: 10,
      );
      try {
        final entries = await pool.listDirectory('');
        expect(entries, isA<List<Smb2DirEntry>>());
      } finally {
        await pool.disconnect();
      }
    });
  }, skip: skipReason);
}
