// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Argument validation of [Smb2Pool.connect]. Validation runs before any
/// worker is spawned, so these tests need neither a server nor libsmb2.
library;

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

void main() {
  Future<Smb2Pool> connect({
    int workers = 4,
    int? minWorkers,
    Duration? idleTimeout,
  }) => Smb2Pool.connect(
    host: 'unused.invalid',
    share: 'unused',
    workers: workers,
    minWorkers: minWorkers,
    idleTimeout: idleTimeout,
  );

  group('Smb2Pool.connect argument validation', () {
    test('rejects workers < 1', () async {
      await expectLater(connect(workers: 0), throwsRangeError);
      await expectLater(connect(workers: -3), throwsRangeError);
    });

    test('rejects workers above maxWorkersLimit', () async {
      await expectLater(
        connect(workers: Smb2Pool.maxWorkersLimit + 1),
        throwsRangeError,
      );
    });

    test('rejects minWorkers outside 1..workers', () async {
      await expectLater(connect(workers: 2, minWorkers: 0), throwsRangeError);
      await expectLater(connect(workers: 2, minWorkers: 3), throwsRangeError);
    });

    test('rejects a non-positive idleTimeout', () async {
      await expectLater(
        connect(idleTimeout: Duration.zero),
        throwsArgumentError,
      );
      await expectLater(
        connect(idleTimeout: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });
}
