import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_smb2/src/ffi/native_lib.dart';
import 'package:dart_smb2/src/smb2_client.dart';
import 'package:dart_smb2/src/smb2_error_type.dart';
import 'package:dart_smb2/src/smb2_exceptions.dart';

Future<void> main(List<String> args) async {
  final library = Platform.environment['DART_SMB2_TEST_LIBRARY'];
  final destroyMarker = Platform.environment['DART_SMB2_LIFECYCLE_MARKER'];
  final pendingMarker = Platform.environment['DART_SMB2_PENDING_MARKER'];
  if (library == null || destroyMarker == null || pendingMarker == null) {
    throw StateError('missing lifecycle environment');
  }
  debugLibSmb2PathOverride = library;

  final scenario = args.isEmpty ? 'pending-echo-kill' : args.first;
  switch (scenario) {
    case 'pending-echo-kill':
      await _killPending(_echoWorker, pendingMarker);
    case 'pending-connect-kill':
      await _killPending(_connectWorker, pendingMarker);
    case 'timeout-reconnect':
      await _timeoutReconnect(destroyMarker);
    case 'readlink-copy':
      _readlinkCopy();
    default:
      throw StateError('unknown scenario: $scenario');
  }

  stdout.writeln('READY');
}

Future<void> _killPending(
  void Function(SendPort) worker,
  String pendingMarker,
) async {
  final started = ReceivePort();
  final exited = ReceivePort();
  final isolate = await Isolate.spawn(
    worker,
    started.sendPort,
    onExit: exited.sendPort,
  );
  await started.first.timeout(const Duration(seconds: 5));
  await _waitForMarker(pendingMarker, minimumLines: 1);
  stdout.writeln('PENDING');
  isolate.kill(priority: Isolate.immediate);
  await exited.first.timeout(const Duration(seconds: 5));
  await _waitForDestroyCount(1);
  started.close();
  exited.close();
}

void _connectWorker(SendPort started) {
  _configureLibrary();
  started.send('started');
  Smb2Client.open().connect(
    host: 'fake',
    share: 'fake',
    user: 'fake',
    password: 'fake',
  );
}

void _echoWorker(SendPort started) {
  _configureLibrary();
  final client = Smb2Client.open();
  client.connect(host: 'fake', share: 'fake', user: 'fake', password: 'fake');
  started.send('connected');
  client.echo();
}

void _configureLibrary() {
  debugLibSmb2PathOverride = Platform.environment['DART_SMB2_TEST_LIBRARY']!;
}

Future<void> _timeoutReconnect(String destroyMarker) async {
  final client = Smb2Client.open();

  for (var attempt = 1; attempt <= 2; attempt++) {
    client.connect(
      host: 'fake',
      share: 'fake',
      user: 'fake',
      password: 'fake',
      timeoutSeconds: 1,
    );
    if (!client.isConnected) {
      throw StateError('attempt $attempt did not connect');
    }

    try {
      client.echo();
      throw StateError('attempt $attempt echo unexpectedly succeeded');
    } on Smb2Exception catch (error) {
      if (error.type != Smb2ErrorType.timeout) {
        throw StateError('attempt $attempt was not a typed timeout: $error');
      }
    }

    if (client.isConnected) {
      throw StateError('attempt $attempt remained connected after timeout');
    }
    client.abort();
    client.abort();
    if (client.isConnected) {
      throw StateError('attempt $attempt remained connected after abort');
    }
    await _waitForMarker(destroyMarker, minimumLines: attempt);
  }
}

void _readlinkCopy() {
  final client = Smb2Client.open();
  client.connect(host: 'fake', share: 'fake', user: 'fake', password: 'fake');
  if (client.readlink('link') != 'fake-target') {
    throw StateError('readlink did not preserve callback-transient data');
  }
  client.disconnect();
}

Future<void> _waitForDestroyCount(int count) async {
  final marker = Platform.environment['DART_SMB2_LIFECYCLE_MARKER']!;
  await _waitForMarker(marker, minimumLines: count);
}

Future<void> _waitForMarker(String path, {required int minimumLines}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final file = File(path);
    if (file.existsSync()) {
      final lines = file
          .readAsLinesSync()
          .where((line) => line.trim().isNotEmpty)
          .length;
      if (lines >= minimumLines) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw TimeoutException('marker $path did not reach $minimumLines lines');
}
