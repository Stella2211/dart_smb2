import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'native lifecycle survives pending callbacks and supports reconnect',
    () async {
      if (Platform.isWindows) {
        markTestSkipped('POSIX compiler fixture only');
        return;
      }

      final root = Directory.systemTemp.createTempSync('smb2-life-');
      addTearDown(() => root.deleteSync(recursive: true));
      final library = await _compileFixtures(root);

      for (final scenario in [
        'pending-echo-kill',
        'pending-connect-kill',
        'timeout-reconnect',
        'readlink-copy',
      ]) {
        await _runScenario(root, library, scenario);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<({String helper, String smb2})> _compileFixtures(Directory root) async {
  final extension = Platform.isMacOS ? 'dylib' : 'so';
  final smb2 = '${root.path}/libfake.$extension';
  final helper = '${root.path}/libdart_smb2_lifecycle.$extension';
  final sharedFlags = [
    '-std=c11',
    '-Wall',
    '-Wextra',
    '-Werror',
    if (!Platform.isMacOS) '-fPIC',
    if (!Platform.isMacOS) '-pthread',
    if (Platform.isMacOS) '-dynamiclib' else '-shared',
  ];

  await _compile([
    ...sharedFlags,
    File('test/support/fake_smb2_lifecycle.c').absolute.path,
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
  Directory root,
  ({String helper, String smb2}) library,
  String scenario,
) async {
  final destroyMarker = '${root.path}/$scenario.destroy';
  final pendingMarker = '${root.path}/$scenario.pending';
  final environment = <String, String>{
    ...Platform.environment,
    'DART_SMB2_LIFECYCLE_LIBRARY': library.helper,
    'DART_SMB2_TEST_LIBRARY': library.smb2,
    'DART_SMB2_LIFECYCLE_MARKER': destroyMarker,
    'DART_SMB2_PENDING_MARKER': pendingMarker,
    if (scenario == 'pending-connect-kill')
      'DART_SMB2_FAKE_CONNECT_PENDING': '1',
  };

  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'test/support/native_lifecycle_child.dart',
    scenario,
  ], environment: environment);
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();

  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(const Duration(seconds: 20));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    final stdoutText = await stdoutFuture;
    final stderrText = await stderrFuture;
    fail('$scenario timed out\n$stdoutText\n$stderrText');
  }

  final stdoutText = await stdoutFuture;
  final stderrText = await stderrFuture;
  expect(exitCode, 0, reason: '$scenario failed\n$stdoutText\n$stderrText');
  expect(stdoutText, contains('READY'), reason: scenario);
  if (scenario.startsWith('pending-')) {
    expect(stdoutText, contains('PENDING'), reason: scenario);
    expect(File(pendingMarker).readAsLinesSync(), isNotEmpty, reason: scenario);
  }
  final expectedDestroyCount = scenario == 'timeout-reconnect' ? 2 : 1;
  expect(
    File(destroyMarker).readAsLinesSync(),
    hasLength(expectedDestroyCount),
    reason: scenario,
  );
}
