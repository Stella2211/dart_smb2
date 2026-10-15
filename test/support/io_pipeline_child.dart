// Child process for test/io_pipeline_test.dart. Drives Smb2Client against
// the fake libsmb2 in fake_smb2_io.c; any failed expectation throws, which
// makes the process exit non-zero.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/src/ffi/native_lib.dart';
import 'package:dart_smb2/src/smb2_client.dart';
import 'package:dart_smb2/src/smb2_error_type.dart';
import 'package:dart_smb2/src/smb2_exceptions.dart';

late final int Function() _maxInFlight;
late final void Function() _resetStats;

void main(List<String> args) {
  final library = Platform.environment['DART_SMB2_TEST_LIBRARY']!;
  debugLibSmb2PathOverride = library;
  final fake = DynamicLibrary.open(library);
  _maxInFlight = fake.lookupFunction<Int32 Function(), int Function()>(
    'fake_max_in_flight',
  );
  _resetStats = fake.lookupFunction<Void Function(), void Function()>(
    'fake_reset_stats',
  );

  final client = Smb2Client.open();
  client.connect(host: 'fake', share: 'fake', user: 'fake', password: 'x');
  final size = int.parse(Platform.environment['DART_SMB2_FAKE_FILE_SIZE']!);

  switch (args.first) {
    case 'read':
      _read(client, size);
    case 'clamp':
      _clamp(client, size);
    case 'fail':
      _fail(client);
    default:
      throw StateError('unknown scenario ${args.first}');
  }
  client.disconnect();
  stdout.writeln('READY');
}

Uint8List _pattern(int length, [int from = 0]) =>
    Uint8List.fromList([for (var i = from; i < from + length; i++) i * 7 + 3]);

void _expectBytes(Uint8List actual, Uint8List expected, String what) {
  if (actual.length != expected.length) {
    throw StateError(
      '$what: length ${actual.length} != expected ${expected.length}',
    );
  }
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) {
      throw StateError('$what: mismatch at byte $i');
    }
  }
}

Uint8List _concat(Iterable<Uint8List> chunks) {
  final builder = BytesBuilder();
  chunks.forEach(builder.add);
  return builder.takeBytes();
}

void _expectPipelined(String what) {
  final depth = _maxInFlight();
  if (depth < 2) throw StateError('$what: max in-flight was $depth');
  _resetStats();
}

void _read(Smb2Client client, int size) {
  _resetStats();
  _expectBytes(client.readFile('f'), _pattern(size), 'readFile');
  _expectPipelined('readFile');

  _expectBytes(
    _concat(client.readFileChunked('f', chunkSize: 100000)),
    _pattern(size),
    'readFileChunked',
  );

  final handle = client.openFileHandle('f');
  _expectBytes(
    client.readHandle(handle, offset: 1000, length: 200000),
    _pattern(200000, 1000),
    'readHandle',
  );
  _expectPipelined('readHandle');
  // Past EOF: short result, exactly the remaining bytes.
  _expectBytes(
    client.readHandle(handle, offset: size - 10, length: 300000),
    _pattern(10, size - 10),
    'readHandle at EOF',
  );
  if (client.readHandle(handle, offset: size, length: 10).isNotEmpty) {
    throw StateError('readHandle beyond EOF was not empty');
  }
  if (client.readHandle(handle, length: 0).isNotEmpty) {
    throw StateError('zero-length readHandle was not empty');
  }
  client.closeHandle(handle);

  _expectBytes(
    client.readFileRange('f', offset: 5, length: 70000),
    _pattern(70000, 5),
    'readFileRange',
  );
}

void _clamp(Smb2Client client, int size) {
  // Every reply is capped below the advertised MaxRead/WriteSize: the
  // client must re-request the remainder instead of skipping it.
  _expectBytes(
    _concat(client.readFileChunked('f')),
    _pattern(size),
    'readFileChunked (clamped)',
  );
  _expectBytes(client.readFile('f'), _pattern(size), 'readFile (clamped)');

  final payload = Uint8List.fromList(
    List.generate(500003, (i) => (i * 13 + 1) & 0xff),
  );
  _resetStats();
  client.writeFile('f', payload);
  _expectPipelined('writeFile');
  _expectBytes(client.readFile('f'), payload, 'writeFile round-trip');

  final chunks = [
    for (var i = 0; i < 40; i++)
      Uint8List.fromList(List.generate(10007 + i * 997, (j) => (i + j) & 0xff)),
  ];
  client.writeFileChunked('f', chunks);
  _expectPipelined('writeFileChunked');
  _expectBytes(client.readFile('f'), _concat(chunks), 'writeFileChunked');

  final handle = client.openFileHandleWrite('f');
  client.writeHandle(handle, payload, offset: 100);
  client.closeHandle(handle);
  _expectBytes(
    client.readFileRange('f', offset: 100, length: payload.length),
    payload,
    'writeHandle round-trip',
  );
}

void _fail(Smb2Client client) {
  try {
    client.readFile('f');
    throw StateError('readFile did not fail');
  } on Smb2Exception catch (e) {
    if (e.type != Smb2ErrorType.io) throw StateError('wrong error: $e');
  }
  // The failure drained the other in-flight requests instead of tearing
  // the connection down, so the client remains usable.
  if (!client.isConnected) throw StateError('client lost its connection');
  _expectBytes(
    client.readFileRange('f', length: 1000),
    _pattern(1000),
    'read after failure',
  );
}
