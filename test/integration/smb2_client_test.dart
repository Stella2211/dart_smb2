// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:dart_smb2/dart_smb2.dart';

import '_fixture.dart';

/// Integration tests for Smb2Client against the local Samba container seeded
/// by `bootstrap.dart`.
void main() {
  final cache = bootstrapCache;
  final libPath = cache.libPath;
  late Smb2Client client;

  setUp(() {
    client = Smb2Client.open(libPath);
    client.connect(
      host: cache.host,
      share: cache.share,
      user: cache.user,
      password: cache.password,
    );
  });

  tearDown(() => client.disconnect());

  test('listDirectory returns entries with metadata', () {
    final entries = client.listDirectory('');
    expect(entries, isNotEmpty);
    for (final e in entries) {
      expect(e.name, isNotEmpty);
      expect(e.stat.type, isNotNull);
    }
  });

  test('stat returns file info', () {
    final entries = client.listDirectory('');
    final first = entries.first;
    final info = client.stat(first.name);
    expect(info.type, equals(first.stat.type));
    expect(info.size, equals(first.stat.size));
  });

  test('readFileRange reads partial file', () {
    final entries = client.listDirectory('');
    final file = entries.firstWhere((e) => e.isFile, orElse: () => throw 'No files');
    final bytes = client.readFileRange(file.name, length: 1024);
    expect(bytes.length, greaterThan(0));
    expect(bytes.length, lessThanOrEqualTo(1024));
  });

  test('fileSize returns correct size', () {
    final entries = client.listDirectory('');
    final file = entries.firstWhere((e) => e.isFile, orElse: () => throw 'No files');
    final size = client.fileSize(file.name);
    expect(size, equals(file.size));
  });

  test('throws on invalid path', () {
    expect(
      () => client.listDirectory('nonexistent_path_12345'),
      throwsA(isA<Smb2Exception>()),
    );
  });

  test('throws when not connected', () {
    final disconnected = Smb2Client.open(libPath);
    expect(
      () => disconnected.listDirectory(''),
      throwsA(isA<Smb2Exception>()),
    );
  });
}
