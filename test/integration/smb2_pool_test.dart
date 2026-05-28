// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

import '_fixture.dart';

/// Integration tests for [Smb2Pool] against the local Samba container seeded
/// by `bootstrap.dart`.
void main() {
  Future<Smb2Pool> connect({int workers = 2}) =>
      poolFromCache(workers: workers);
  Future<String> resolveTestFile(Smb2Pool pool) async =>
      bootstrapCache.testFile;

  // ─── Basic correctness ──────────────────────────────────────────────────

  group('Smb2Pool — basic', () {
    late Smb2Pool pool;

    setUp(() async => pool = await connect());
    tearDown(() => pool.disconnect());

    test('workerCount reflects requested workers', () async {
      final p = await connect(workers: 3);
      addTearDown(p.disconnect);
      expect(p.workerCount, 3);
    });

    test('listDirectory returns non-empty result', () async {
      final entries = await pool.listDirectory('');
      expect(entries, isNotEmpty);
      for (final e in entries) {
        expect(e.name, isNotEmpty);
      }
    });

    test('stat returns metadata matching listDirectory entry', () async {
      final entries = await pool.listDirectory('');
      final first = entries.first;
      final info = await pool.stat(first.name);
      expect(info.type, equals(first.stat.type));
      expect(info.size, equals(first.stat.size));
    });

    test('fileSize matches stat size for a file', () async {
      final path = await resolveTestFile(pool);
      final size = await pool.fileSize(path);
      final info = await pool.stat(path);
      expect(size, equals(info.size));
      expect(size, greaterThan(0));
    });

    test('readFileRange returns correct byte count', () async {
      final path = await resolveTestFile(pool);
      const toRead = 512;
      final bytes = await pool.readFileRange(path, length: toRead);
      expect(bytes.length, greaterThan(0));
      expect(bytes.length, lessThanOrEqualTo(toRead));
    });

    test('readFile returns full file matching fileSize', () async {
      final path = await resolveTestFile(pool);
      final expectedSize = await pool.fileSize(path);
      // Only do this for reasonably small files to keep test fast.
      if (expectedSize > 10 * 1024 * 1024) {
        markTestSkipped(
          'File too large for readFile test (>10 MB) — set SMB2_TEST_FILE to a small file',
        );
        return;
      }
      final bytes = await pool.readFile(path);
      expect(bytes.length, equals(expectedSize));
    });

    test('throws Smb2Exception for nonexistent path', () async {
      await expectLater(
        pool.listDirectory('__nonexistent_path_12345__'),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('Smb2Exception for nonexistent path has fileNotFound type', () async {
      try {
        await pool.listDirectory('__nonexistent_path_12345__');
        fail('Expected Smb2Exception');
      } on Smb2Exception catch (e) {
        expect(e.type, Smb2ErrorType.fileNotFound);
      }
    });
  });

  // ─── File handles ────────────────────────────────────────────────────────

  group('Smb2Pool — file handles', () {
    late Smb2Pool pool;
    late String path;

    setUp(() async {
      pool = await connect();
      path = await resolveTestFile(pool);
    });
    tearDown(() => pool.disconnect());

    test('openFile + readFromHandle + closeHandle round-trip', () async {
      final handle = await pool.openFile(path);
      final bytes = await pool.readFromHandle(handle, length: 256);
      await pool.closeHandle(handle);
      expect(bytes.length, greaterThan(0));
    });

    test('openFileWithSize returns handle and correct size', () async {
      final expectedSize = await pool.fileSize(path);
      final (handle, size) = await pool.openFileWithSize(path);
      await pool.closeHandle(handle);
      expect(size, equals(expectedSize));
    });

    test('readFromHandle at offset matches readFileRange', () async {
      const offset = 128;
      const length = 256;
      final expected = await pool.readFileRange(
        path,
        offset: offset,
        length: length,
      );
      final handle = await pool.openFile(path);
      final actual = await pool.readFromHandle(
        handle,
        offset: offset,
        length: length,
      );
      await pool.closeHandle(handle);
      expect(actual, equals(expected));
    });

    test('double closeHandle does not throw', () async {
      final handle = await pool.openFile(path);
      await pool.closeHandle(handle);
      // Second close should be best-effort and not throw.
      await expectLater(pool.closeHandle(handle), completes);
    });
  });

  // ─── Stream ──────────────────────────────────────────────────────────────

  group('Smb2Pool — streamFile', () {
    late Smb2Pool pool;

    setUp(() async => pool = await connect());
    tearDown(() => pool.disconnect());

    test('streamFile yields all bytes matching readFile', () async {
      final path = await resolveTestFile(pool);
      final expectedSize = await pool.fileSize(path);
      if (expectedSize > 10 * 1024 * 1024) {
        markTestSkipped('File too large for stream test (>10 MB)');
        return;
      }
      final chunks = await pool.streamFile(path, chunkSize: 64 * 1024).toList();
      final total = chunks.fold<int>(0, (sum, c) => sum + c.length);
      expect(total, equals(expectedSize));
    });

    test('streamFile chunks are not larger than chunkSize', () async {
      final path = await resolveTestFile(pool);
      const chunkSize = 32 * 1024;
      await for (final chunk in pool.streamFile(path, chunkSize: chunkSize)) {
        expect(chunk.length, lessThanOrEqualTo(chunkSize));
      }
    });
  });

  // ─── Round-robin distribution ─────────────────────────────────────────────

  group('Smb2Pool — round-robin', () {
    test('concurrent requests complete without error', () async {
      final pool = await connect(workers: 4);
      addTearDown(pool.disconnect);
      final path = await resolveTestFile(pool);

      final futures = List.generate(
        16,
        (_) => pool.readFileRange(path, length: 512),
      );
      final results = await Future.wait(futures);
      for (final r in results) {
        expect(r.length, greaterThan(0));
      }
    });

    test(
      'concurrent listDirectory calls all return same entry count',
      () async {
        final pool = await connect(workers: 3);
        addTearDown(pool.disconnect);

        final futures = List.generate(9, (_) => pool.listDirectory(''));
        final results = await Future.wait(futures);
        final counts = results.map((r) => r.length).toSet();
        // All parallel calls should see the same directory listing.
        expect(counts.length, 1);
      },
    );
  });

  // ─── Disconnect ───────────────────────────────────────────────────────────

  group('Smb2Pool — disconnect', () {
    test('disconnect completes cleanly', () async {
      final pool = await connect();
      await expectLater(pool.disconnect(), completes);
    });

    test('operations after disconnect throw', () async {
      final pool = await connect();
      await pool.disconnect();
      await expectLater(pool.listDirectory(''), throwsA(isA<Smb2Exception>()));
    });
  });

  // ─── Performance benchmarks ───────────────────────────────────────────────

  group('Smb2Pool — performance', () {
    late Smb2Pool pool;
    late String path;
    late int fileBytes;

    setUp(() async {
      pool = await connect(workers: 4);
      path = await resolveTestFile(pool);
      fileBytes = await pool.fileSize(path);
    });
    tearDown(() => pool.disconnect());

    test(
      'sequential read throughput (readFileRange, 1 MB chunks)',
      () async {
        const chunkSize = 1024 * 1024;
        final toRead = fileBytes.clamp(0, 8 * chunkSize);
        var offset = 0;
        var totalBytes = 0;
        final sw = Stopwatch()..start();
        while (offset < toRead) {
          final len = (toRead - offset).clamp(0, chunkSize);
          final chunk = await pool.readFileRange(
            path,
            offset: offset,
            length: len,
          );
          totalBytes += chunk.length;
          offset += chunk.length;
        }
        sw.stop();
        final mbps =
            (totalBytes / (1024 * 1024)) / (sw.elapsedMilliseconds / 1000);
        print(
          'Sequential read: ${mbps.toStringAsFixed(1)} MB/s '
          '(${totalBytes ~/ 1024} KB in ${sw.elapsedMilliseconds} ms)',
        );
        // Sanity check — any modern network should do at least 1 MB/s.
        expect(mbps, greaterThan(1.0));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'parallel read throughput (4 workers × 1 MB chunks)',
      () async {
        const chunkSize = 1024 * 1024;
        const requests = 8;
        final length = chunkSize.clamp(0, fileBytes);

        final sw = Stopwatch()..start();
        final futures = List.generate(
          requests,
          (_) => pool.readFileRange(path, length: length),
        );
        final results = await Future.wait(futures);
        sw.stop();

        final totalBytes = results.fold<int>(0, (s, r) => s + r.length);
        final mbps =
            (totalBytes / (1024 * 1024)) / (sw.elapsedMilliseconds / 1000);
        print(
          'Parallel read ($requests requests): ${mbps.toStringAsFixed(1)} MB/s '
          '(${totalBytes ~/ 1024} KB in ${sw.elapsedMilliseconds} ms)',
        );
        expect(mbps, greaterThan(1.0));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('stat latency (50 sequential calls)', () async {
      const iterations = 50;
      final sw = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        await pool.stat(path);
      }
      sw.stop();
      final avgMs = sw.elapsedMilliseconds / iterations;
      print(
        'stat latency: ${avgMs.toStringAsFixed(1)} ms/call avg over $iterations calls',
      );
      // Sanity: stat should resolve in under 2 seconds on a local network.
      expect(avgMs, lessThan(2000));
    });

    test('listDirectory latency (20 sequential calls)', () async {
      const iterations = 20;
      final sw = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        await pool.listDirectory('');
      }
      sw.stop();
      final avgMs = sw.elapsedMilliseconds / iterations;
      print(
        'listDirectory latency: ${avgMs.toStringAsFixed(1)} ms/call avg over $iterations calls',
      );
      expect(avgMs, lessThan(2000));
    });

    test(
      'handle open+read+close throughput (20 cycles)',
      () async {
        const iterations = 20;
        final sw = Stopwatch()..start();
        for (var i = 0; i < iterations; i++) {
          final handle = await pool.openFile(path);
          await pool.readFromHandle(handle, length: 4096);
          await pool.closeHandle(handle);
        }
        sw.stop();
        final avgMs = sw.elapsedMilliseconds / iterations;
        print(
          'Handle open+read+close: ${avgMs.toStringAsFixed(1)} ms/cycle avg over $iterations cycles',
        );
        expect(avgMs, lessThan(5000));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  // ─── Scoped helpers, downloads & info surface ────────────────────────────

  group('Smb2Pool — scoped helpers & info', () {
    late Smb2Pool pool;
    late String path;

    setUp(() async {
      pool = await connect();
      path = await resolveTestFile(pool);
    });
    tearDown(() => pool.disconnect());

    test('withFile reads via a scoped handle and exposes size', () async {
      final size = await pool.fileSize(path);
      final got = await pool.withFile(path, (file) async {
        expect(file.size, size);
        return file.read(length: 1024);
      });
      expect(got.length, 1024);
    });

    test('withFile(knownSize:) skips the fstat round-trip', () async {
      final size = await pool.fileSize(path);
      final headLen = await pool.withFile(
        path,
        (file) async {
          expect(file.size, size);
          final head = await file.read(length: 256);
          return head.length;
        },
        knownSize: size,
      );
      expect(headLen, 256);
    });

    test('downloadToFile writes the whole file and reports progress', () async {
      final size = await pool.fileSize(path);
      final tmp = File(
        '${Directory.systemTemp.path}/dart_smb2_dl_${DateTime.now().microsecondsSinceEpoch}.bin',
      );
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      var lastReceived = 0;
      var lastTotal = -1;
      final written = await pool.downloadToFile(
        path,
        tmp,
        chunkSize: 64 * 1024,
        onProgress: (received, total) {
          lastReceived = received;
          lastTotal = total;
        },
      );
      expect(written, size);
      expect(tmp.lengthSync(), size);
      expect(lastReceived, size);
      expect(lastTotal, size);
    });

    test('downloadToFile honours cancellation mid-stream', () async {
      final tmp = File(
        '${Directory.systemTemp.path}/dart_smb2_cancel_${DateTime.now().microsecondsSinceEpoch}.bin',
      );
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      var calls = 0;
      await expectLater(
        pool.downloadToFile(
          path,
          tmp,
          chunkSize: 4096,
          isCanceled: () => ++calls > 1, // cancel after the first chunk
        ),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('statvfs reports plausible totals', () async {
      final vfs = await pool.statvfs('');
      expect(vfs.totalSize, greaterThan(0));
      expect(vfs.freeSize, lessThanOrEqualTo(vfs.totalSize));
    });

    test('echo succeeds on a healthy pool', () async {
      await expectLater(pool.echo(), completes);
    });

    test('readlink throws on a regular file', () async {
      await expectLater(
        pool.readlink(path),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('listShares (instance) returns the configured share', () async {
      final shares = await pool.listShares(
        host: bootstrapCache.host,
        user: bootstrapCache.user,
        password: bootstrapCache.password,
      );
      expect(shares.map((s) => s.name), contains(bootstrapCache.share));
    });

    test('listSharesOn (static) returns the configured share', () async {
      final shares = await Smb2Pool.listSharesOn(
        host: bootstrapCache.host,
        user: bootstrapCache.user,
        password: bootstrapCache.password,
      );
      expect(shares.map((s) => s.name), contains(bootstrapCache.share));
    });
  });

  // ─── Write-handle helpers (fsync / ftruncate over the worker) ────────────

  group('Smb2Pool — write-handle helpers', () {
    late Smb2Pool pool;
    const path = 'pool_handle_helpers.bin';

    setUp(() async => pool = await connect());
    tearDown(() async {
      try {
        await pool.deleteFile(path);
      } catch (_) {}
      await pool.disconnect();
    });

    test('openFileWrite + writeToHandle + fsyncHandle + ftruncateHandle',
        () async {
      final handle = await pool.openFileWrite(path);
      try {
        await pool.writeToHandle(
          handle,
          Uint8List.fromList([10, 20, 30, 40, 50, 60]),
        );
        await pool.fsyncHandle(handle);
        expect(await pool.fileSize(path), 6);

        await pool.ftruncateHandle(handle, 3);
        expect(await pool.fileSize(path), 3);
      } finally {
        await pool.closeHandle(handle);
      }
      expect(await pool.readFile(path), orderedEquals([10, 20, 30]));
    });
  });
}
