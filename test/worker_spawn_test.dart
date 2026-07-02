// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Regression test for a worker isolate that dies during startup because
/// the native library fails to load. Before the fix, `Smb2Client.open()`
/// ran outside `workerMain`'s try/catch, so a load failure killed the
/// isolate with an uncaught error before it ever replied on `initPort` —
/// and `Worker.spawn` wasn't listening for isolate exit yet at that
/// point, so `await initPort.first` hung forever.
library;

// ignore: implementation_imports — Worker/ConnectParams are internal.
import 'package:dart_smb2/src/pool/messages.dart';
// ignore: implementation_imports
import 'package:dart_smb2/src/pool/worker.dart';
import 'package:dart_smb2/src/smb2_exceptions.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Worker.spawn throws promptly when the native library fails to load',
    () async {
      const params = ConnectParams(
        host: 'unused',
        share: 'unused',
        testLibOverride: '/nonexistent/path/to/libsmb2.so',
      );

      await expectLater(
        Worker.spawn(params),
        throwsA(isA<Smb2Exception>()),
      ).timeout(const Duration(seconds: 10));
    },
  );
}
