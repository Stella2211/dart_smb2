// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Hermetic tests for Smb2Client's pipelined pread/pwrite paths, driven
/// against the fake libsmb2 in `test/support/fake_smb2_io.c` (queued
/// completions, clamped replies, injected failures).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory root;
  late ({String helper, String smb2}) library;

  setUpAll(() async {
    if (Platform.isWindows) return;
    root = Directory.systemTemp.createTempSync('smb2-io-');
    library = await _compileFixtures(root);
  });

  tearDownAll(() {
    if (Platform.isWindows) return;
    root.deleteSync(recursive: true);
  });

  final skip = Platform.isWindows ? 'POSIX compiler fixture only' : null;

  test('reads are pipelined and byte-exact', skip: skip, () async {
    await _runScenario(library, 'read', {
      'DART_SMB2_FAKE_FILE_SIZE': '300001',
      'DART_SMB2_FAKE_MAX_IO': '65536',
    });
  });

  test(
    'short (clamped) replies are re-requested, never skipped',
    skip: skip,
    () async {
      await _runScenario(library, 'clamp', {
        'DART_SMB2_FAKE_FILE_SIZE': '700001',
        'DART_SMB2_FAKE_MAX_IO': '262144',
        'DART_SMB2_FAKE_CLAMP': '100000',
      });
    },
  );

  test(
    'a failed request drains the pipeline and keeps the connection',
    skip: skip,
    () async {
      await _runScenario(library, 'fail', {
        'DART_SMB2_FAKE_FILE_SIZE': '400000',
        'DART_SMB2_FAKE_MAX_IO': '65536',
        'DART_SMB2_FAKE_FAIL_AT': '150000',
      });
    },
  );
}

Future<({String helper, String smb2})> _compileFixtures(Directory root) async {
  final extension = Platform.isMacOS ? 'dylib' : 'so';
  final smb2 = '${root.path}/libfakeio.$extension';
  final helper = '${root.path}/libdart_smb2_lifecycle.$extension';
  final sharedFlags = [
    '-std=c11',
    '-D_POSIX_C_SOURCE=200809L',
    '-Wall',
    '-Wextra',
    '-Werror',
    if (!Platform.isMacOS) '-fPIC',
    if (!Platform.isMacOS) '-pthread',
    if (Platform.isMacOS) '-dynamiclib' else '-shared',
  ];
  await _compile([
    ...sharedFlags,
    File('test/support/fake_smb2_io.c').absolute.path,
    '-o',
    smb2,
  ]);
  await _compile([
    ...sharedFlags,
    File('src/smb2_lifecycle.c').absolute.path,
    '-o',
    helper,
  ]);
  return (helper: helper, smb2: smb2);
}

Future<void> _compile(List<String> arguments) async {
  final result = await Process.run('cc', arguments);
  expect(
    result.exitCode,
    0,
    reason: 'cc ${arguments.join(' ')}\n${result.stdout}\n${result.stderr}',
  );
}

Future<void> _runScenario(
  ({String helper, String smb2}) library,
  String scenario,
  Map<String, String> fakeEnvironment,
) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'test/support/io_pipeline_child.dart', scenario],
    environment: {
      ...Platform.environment,
      'DART_SMB2_LIFECYCLE_LIBRARY': library.helper,
      'DART_SMB2_TEST_LIBRARY': library.smb2,
      ...fakeEnvironment,
    },
  );
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();

  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(const Duration(seconds: 60));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    fail('$scenario timed out\n${await stdoutFuture}\n${await stderrFuture}');
  }
  final stdoutText = await stdoutFuture;
  final stderrText = await stderrFuture;
  expect(exitCode, 0, reason: '$scenario failed\n$stdoutText\n$stderrText');
  expect(stdoutText, contains('READY'), reason: scenario);
}
