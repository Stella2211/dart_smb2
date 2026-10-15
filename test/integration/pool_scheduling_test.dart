// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

@Tags(['integration'])
/// Scheduling / pipelining tests for [Smb2Pool]: least-loaded worker
/// selection, lazy growth and idle shrinking, read-ahead in `streamFile`
/// and pipelined `streamWrite`.
///
/// A worker is made "busy" deterministically by parking a request on it
/// with the `__inject_hang` knob: the worker swallows the next command, so
/// that request stays in flight until the pool is disconnected.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
// ignore: implementation_imports — needs poolWorkers() for fault injection
// and per-worker in-flight / open-handle counters.
import 'package:dart_smb2/src/pool/test_hooks.dart';
// ignore: implementation_imports
import 'package:dart_smb2/src/pool/worker.dart';
import 'package:test/test.dart';

import '_fixture.dart';

void main() {
  final seed = bootstrapCache.testFile;

  /// Park one never-answered request on [worker]; it stays in flight until
  /// the worker is closed (which fails it — hence the `ignore`).
  Future<void> park(Worker worker) async {
    await worker.send<bool>('__inject_hang', const {});
    worker.send<Object?>('echo', const {}).ignore();
    expect(worker.inFlight, 1);
  }

  void expectNoHandlesOrRequests(Smb2Pool pool) {
    for (final w in poolWorkers(pool)) {
      expect(w.openHandles, 0, reason: 'handle leaked on a worker');
      expect(w.inFlight, 0, reason: 'request left in flight on a worker');
    }
  }

  group('least-loaded worker selection', () {
    test('routes around a busy worker instead of round-robin', () async {
      final pool = await poolFromCache();
      addTearDown(pool.disconnect);
      await park(poolWorkers(pool)[0]);

      // Plain round-robin would send every other call to the parked
      // worker and hang; least-loaded keeps picking the idle one.
      for (var i = 0; i < 6; i++) {
        await pool.echo().timeout(const Duration(seconds: 5));
      }
      expect(poolWorkers(pool)[1].inFlight, 0);
    });

    test('idle workers are still used round-robin', () async {
      final pool = await poolFromCache(workers: 3);
      addTearDown(pool.disconnect);
      final workers = poolWorkers(pool).toList();

      // Back-to-back calls: each send registers synchronously, so a burst
      // of 3 spreads over the 3 idle workers.
      final futures = List.generate(3, (_) => pool.echo());
      expect(workers.map((w) => w.inFlight), everyElement(1));
      await Future.wait(futures);
    });
  });

  group('lazy start / idle shrink', () {
    test('starts minWorkers and grows when every worker is busy', () async {
      final pool = await poolFromCache(workers: 3, minWorkers: 1);
      addTearDown(pool.disconnect);
      expect(pool.workerCount, 1);
      expect(pool.minWorkers, 1);
      expect(pool.maxWorkers, 3);

      // Idle worker available → no growth.
      await pool.echo();
      expect(pool.workerCount, 1);

      await park(poolWorkers(pool)[0]);
      await pool.echo().timeout(const Duration(seconds: 10));
      expect(pool.workerCount, 2);

      // The new worker is idle again → reused, no further growth.
      await pool.echo();
      expect(pool.workerCount, 2);
    });

    test('never grows past workers', () async {
      final pool = await poolFromCache(minWorkers: 1);
      addTearDown(pool.disconnect);
      final futures = List.generate(8, (_) => pool.echo());
      await Future.wait(futures);
      expect(pool.workerCount, lessThanOrEqualTo(2));
    });

    test('default pool neither grows nor shrinks', () async {
      final pool = await poolFromCache();
      addTearDown(pool.disconnect);
      expect(pool.minWorkers, 2);
      expect(pool.maxWorkers, 2);
      await Future.wait(List.generate(8, (_) => pool.echo()));
      expect(pool.workerCount, 2);
    });

    test(
      'retires idle extra workers but keeps one that owns a handle',
      () async {
        const idle = Duration(milliseconds: 200);
        final pool = await poolFromCache(
          workers: 3,
          minWorkers: 1,
          idleTimeout: idle,
        );
        addTearDown(pool.disconnect);
        final first = poolWorkers(pool).single;
        await park(first);

        // Grows; the handle lands on the new (least-loaded) worker.
        final handle = await pool
            .openFile(seed)
            .timeout(const Duration(seconds: 10));
        expect(pool.workerCount, 2);
        final grown = poolWorkers(pool)[1];
        expect(identical(handle.worker, grown), isTrue);
        expect(grown.openHandles, 1);

        await Future<void>.delayed(idle * 4);
        expect(
          pool.workerCount,
          2,
          reason: 'a worker owning an open handle must not be retired',
        );

        await pool.closeHandle(handle);
        expect(grown.openHandles, 0);
        await Future<void>.delayed(idle * 4);
        expect(pool.workerCount, 1);
        expect(identical(poolWorkers(pool).single, first), isTrue);
        expect(grown.isDead, isTrue);
      },
    );

    test('disconnect during on-demand growth settles everything', () async {
      final pool = await poolFromCache(minWorkers: 1);
      await park(poolWorkers(pool).single);
      // Triggers a spawn; observe the outcome before disconnecting so the
      // expected "Pool is closed" error is never reported as unhandled.
      final echo = pool
          .echo()
          .then<Object?>((_) => 'ok')
          .catchError((Object e) => e);
      await pool.disconnect().timeout(const Duration(seconds: 15));
      final outcome = await echo.timeout(
        const Duration(seconds: 5),
        onTimeout: () => 'HUNG',
      );
      expect(outcome, isNot('HUNG'));
      expect(pool.workerCount, 0);
    });
  });

  group('streamFile read-ahead', () {
    late Smb2Pool pool;
    late Uint8List expected;

    setUp(() async {
      pool = await poolFromCache(workers: 1);
      expected = await pool.readFile(seed);
    });
    tearDown(() => pool.disconnect());

    Future<Uint8List> collect(Stream<Uint8List> stream) async {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    }

    for (final depth in [1, 2, 4]) {
      test('maxInFlight: $depth yields the exact file content', () async {
        // Odd chunk size so the last chunk is a short tail.
        final bytes = await collect(
          pool.streamFile(seed, chunkSize: 100003, maxInFlight: depth),
        );
        expect(bytes, orderedEquals(expected));
        expectNoHandlesOrRequests(pool);
      });
    }

    test('onProgress runs before each chunk is delivered', () async {
      var reported = 0;
      var received = 0;
      await for (final chunk in pool.streamFile(
        seed,
        chunkSize: 64 * 1024,
        onProgress: (r, total) {
          expect(total, expected.length);
          expect(r, greaterThan(reported));
          reported = r;
        },
      )) {
        received += chunk.length;
        expect(reported, received);
      }
      expect(received, expected.length);
    });

    test('early break drains read-ahead and closes the handle', () async {
      await for (final _ in pool.streamFile(
        seed,
        chunkSize: 64 * 1024,
        maxInFlight: 3,
      )) {
        break;
      }
      expectNoHandlesOrRequests(pool);
      // The worker is still healthy and in a clean state.
      expect(await collect(pool.streamFile(seed)), orderedEquals(expected));
    });

    test('cancel drains read-ahead and closes the handle', () async {
      var chunks = 0;
      await expectLater(
        pool
            .streamFile(
              seed,
              chunkSize: 64 * 1024,
              isCanceled: () => chunks >= 1,
            )
            .forEach((_) => chunks++),
        throwsA(isA<Smb2Exception>()),
      );
      expect(chunks, 1);
      expectNoHandlesOrRequests(pool);
    });

    test('zero-byte read is still detected with reads in flight', () async {
      final worker = poolWorkers(pool).single;
      await worker.send<bool>('__inject_readhandle_zero_next', const {});
      final iterator = StreamIterator(
        pool.streamFile(seed, chunkSize: 64 * 1024, maxInFlight: 3),
      );
      try {
        await expectLater(
          iterator.moveNext(),
          throwsA(
            isA<Smb2Exception>().having(
              (e) => e.type,
              'type',
              Smb2ErrorType.io,
            ),
          ),
        );
      } finally {
        await iterator.cancel();
      }
      expectNoHandlesOrRequests(pool);
    });

    test(
      'downloadToFile validates maxInFlight before touching the file',
      () async {
        final dir = Directory.systemTemp.createTempSync('smb2-dl-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final dest = File('${dir.path}/out.bin');
        await expectLater(
          pool.downloadToFile(seed, dest, maxInFlight: 0),
          throwsRangeError,
        );
        expect(dest.existsSync(), isFalse);
        expect(
          await pool.downloadToFile(seed, dest, maxInFlight: 3),
          expected.length,
        );
        expect(dest.readAsBytesSync(), orderedEquals(expected));
      },
    );
  });

  group('streamWrite pipelining', () {
    const path = 'pool_scheduling_stream.bin';
    late Smb2Pool pool;

    setUp(() async => pool = await poolFromCache(workers: 1));
    tearDown(() async {
      try {
        await pool.deleteFile(path);
      } catch (_) {}
      await pool.disconnect();
    });

    List<Uint8List> makeChunks() => List.generate(
      9,
      (i) => Uint8List.fromList(
        List.generate(70001 + i, (j) => (i * 31 + j) & 0xff),
      ),
    );

    for (final depth in [1, 2, 4]) {
      test('maxInFlight: $depth writes chunks in order', () async {
        final chunks = makeChunks();
        await pool.streamWrite(
          path,
          Stream.fromIterable(chunks),
          maxInFlight: depth,
        );
        final builder = BytesBuilder();
        chunks.forEach(builder.add);
        expect(await pool.readFile(path), orderedEquals(builder.takeBytes()));
        expectNoHandlesOrRequests(pool);
      });
    }

    test('chunk buffers may be reused by the producer', () async {
      // The producer overwrites one buffer after each yield; every send
      // must have taken its own copy already.
      final buffer = Uint8List(50000);
      Stream<Uint8List> produce() async* {
        for (var i = 0; i < 6; i++) {
          buffer.fillRange(0, buffer.length, i + 1);
          yield buffer;
        }
      }

      await pool.streamWrite(path, produce(), maxInFlight: 3);
      final data = await pool.readFile(path);
      expect(data.length, 6 * buffer.length);
      for (var i = 0; i < 6; i++) {
        expect(
          data.sublist(i * buffer.length, (i + 1) * buffer.length),
          everyElement(i + 1),
        );
      }
    });

    test('source stream error propagates and closes the handle', () async {
      Stream<Uint8List> failing() async* {
        yield Uint8List(1000);
        yield Uint8List(1000);
        throw StateError('source failed');
      }

      await expectLater(pool.streamWrite(path, failing()), throwsStateError);
      expectNoHandlesOrRequests(pool);
    });

    test('write error propagates and closes the handle', () async {
      final worker = poolWorkers(pool).single;
      Stream<Uint8List> source() async* {
        yield Uint8List(1000);
        // Fail the next commands (writes) with a connection error; the
        // streamed write must not retry.
        await worker.send<bool>('__inject_fail_next_n', const {'count': 2});
        yield Uint8List(1000);
        yield Uint8List(1000);
      }

      await expectLater(
        pool.streamWrite(path, source()),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.connection,
          ),
        ),
      );
      expect(worker.openHandles, 0);
      expect(worker.inFlight, 0);
    });
  });
}
