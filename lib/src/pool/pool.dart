// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../ffi/native_lib.dart';
import '../smb2_client.dart';
import '../smb2_error_type.dart';
import '../smb2_exceptions.dart';
import '../smb2_types.dart';
import 'handle.dart';
import 'messages.dart';
import 'worker.dart';

export 'handle.dart' show Smb2PoolHandle, Smb2File;

/// A pool of SMB2 worker isolates for non-blocking parallel operations.
///
/// Each worker owns its own SMB connection and runs in a dedicated isolate.
/// All public methods are async and safe to call from the Flutter UI thread.
///
/// ```dart
/// final pool = await Smb2Pool.connect(
///   host: '192.168.1.100',
///   share: 'Music',
///   user: 'user',
///   password: 'pass',
///   workers: 4,
/// );
///
/// final entries = await pool.listDirectory('');
/// final bytes = await pool.readFile('Artist/cover.jpg');
/// await pool.disconnect();
/// ```
class Smb2Pool {
  /// Upper bound accepted for the `workers` argument of [connect].
  ///
  /// Every worker is a separate isolate *and* a separate SMB session on
  /// the server; past a few dozen connections servers start throttling
  /// or refusing sessions long before the client gains any throughput.
  static const int maxWorkersLimit = 64;

  final List<Worker> _workers;
  final ConnectParams _params;
  final int _minWorkers;
  final int _maxWorkers;
  final Duration? _idleTimeout;

  int _next = 0;
  bool _closed = false;

  /// Spawns requested (growth) but not yet added to [_workers]. Counted
  /// against [_maxWorkers] so a burst of callers doesn't overshoot.
  int _pendingSpawns = 0;

  /// Tail of the serial spawn queue — see [_spawnSerialized].
  Future<void> _spawnQueue = Future<void>.value();

  /// Pending idle-shrink check, armed only while the pool is above
  /// [_minWorkers] and [_idleTimeout] is set.
  Timer? _idleTimer;

  /// Close futures of workers retired by idle shrinking; awaited by
  /// [disconnect] so no isolate outlives the pool.
  final Set<Future<void>> _retiring = {};

  Smb2Pool._(
    this._workers,
    this._params,
    this._minWorkers,
    this._maxWorkers,
    this._idleTimeout,
  );

  /// Connect [workers] isolates to the SMB share.
  ///
  /// Each isolate opens its own TCP connection to the server.
  /// All isolates share the same credentials and target share.
  /// [workers] must be in `1..`[maxWorkersLimit].
  ///
  /// Workers are spawned **sequentially** — each spawn is `await`ed
  /// before the next starts. libsmb2 mutates a global `active_contexts`
  /// list (init.c) without internal locking, so concurrent
  /// `smb2_init_context` calls from multiple isolates would race on it.
  /// Sequencing the spawns guarantees that at most one isolate is inside
  /// `smb2_init_context` at any given moment within this pool. The same
  /// serial queue is used for on-demand growth and reconnects.
  ///
  /// The startup cost is N × per-worker connect latency instead of
  /// max(per-worker latency). For typical `workers = 4` and a local SMB
  /// server that's ~100 ms vs ~25 ms — well below human-perceptible.
  ///
  /// **Lazy start / idle shrink (opt-in).** By default every worker is
  /// started here and kept until [disconnect]. Pass [minWorkers] below
  /// [workers] to start only [minWorkers] now and grow on demand — a new
  /// worker is spawned when every live worker is busy — up to [workers].
  /// Pass [idleTimeout] to retire workers above [minWorkers] after they
  /// have been idle that long. A worker that still owns an open handle
  /// ([openFile], [streamFile], …) is never retired, since handles are
  /// bound to the worker that opened them.
  static Future<Smb2Pool> connect({
    required String host,
    required String share,
    String? user,
    String? password,
    String? domain,
    int workers = 4,
    int timeoutSeconds = 30,
    bool seal = false,
    bool signing = false,
    Smb2Version version = Smb2Version.any,
    int? minWorkers,
    Duration? idleTimeout,
  }) async {
    RangeError.checkValueInInterval(workers, 1, maxWorkersLimit, 'workers');
    final initialWorkers = minWorkers ?? workers;
    RangeError.checkValueInInterval(initialWorkers, 1, workers, 'minWorkers');
    if (idleTimeout != null && idleTimeout <= Duration.zero) {
      throw ArgumentError.value(idleTimeout, 'idleTimeout', 'must be positive');
    }
    final params = ConnectParams(
      host: host,
      share: share,
      user: user,
      password: password,
      domain: domain,
      timeoutSeconds: timeoutSeconds,
      seal: seal,
      signing: signing,
      version: version,
      testLibOverride: debugLibSmb2PathOverride,
    );
    final workerList = <Worker>[];
    try {
      for (var i = 0; i < initialWorkers; i++) {
        workerList.add(await Worker.spawn(params));
      }
    } catch (_) {
      // Spawn failure: wait for every initialized worker to release its
      // native context and exit before reporting the failure.
      await Future.wait(workerList.map((w) => w.close()));
      rethrow;
    }
    return Smb2Pool._(workerList, params, initialWorkers, workers, idleTimeout);
  }

  /// Number of currently running workers. Equals the `workers` passed to
  /// [connect] unless lazy start / idle shrink is enabled, in which case
  /// it moves between [minWorkers] and [maxWorkers].
  int get workerCount => _workers.length;

  /// Workers kept running at all times (`minWorkers` of [connect]).
  int get minWorkers => _minWorkers;

  /// Upper bound on running workers (`workers` of [connect]).
  int get maxWorkers => _maxWorkers;

  /// Package-internal view on the underlying [Worker] list. Read-only —
  /// returning the live list lets the concurrency suite call
  /// `killForTest()` and send fault-injection commands directly on a
  /// worker. Reached via `lib/src/pool/test_hooks.dart`.
  @internal
  List<Worker> get workersForTest => _workers;

  /// List available shares on a server (no active connection needed).
  ///
  /// Spawns a temporary isolate, connects to IPC$, enumerates, and cleans up.
  ///
  /// [seal]/[signing] mirror the same-named [connect] parameters — they are
  /// applied to the temporary IPC$ connection used for enumeration. Pass
  /// `true` to require SMB3 encryption / packet signing when listing shares
  /// on a security-hardened server.
  static Future<List<Smb2ShareInfo>> listSharesOn({
    required String host,
    String? user,
    String? password,
    String? domain,
    int timeoutSeconds = 15,
    bool seal = false,
    bool signing = false,
  }) async {
    // Capture the test override here so the spawned isolate (which
    // doesn't inherit the main isolate's static fields) can re-apply
    // it before opening libsmb2.
    final override = debugLibSmb2PathOverride;
    return await Isolate.run(() {
      if (override != null) debugLibSmb2PathOverride = override;
      final client = Smb2Client.open();
      return client.listShares(
        host: host,
        user: user,
        password: password,
        domain: domain,
        timeoutSeconds: timeoutSeconds,
        seal: seal,
        signing: signing,
      );
    });
  }

  /// Pick the worker for a new request.
  ///
  /// Routes to the worker with the fewest in-flight requests; ties are
  /// broken round-robin (the scan starts one slot further on every call),
  /// so an idle pool behaves exactly like plain round-robin. When every
  /// worker is busy and the pool may still grow (lazy start), a new worker
  /// is spawned and used instead.
  ///
  /// Returns synchronously whenever no spawn is needed, so callers can
  /// issue their [Worker.send] in the same synchronous step — that keeps
  /// the in-flight counts accurate for a burst of calls made back-to-back.
  FutureOr<Worker> _acquireWorker() {
    if (_closed) throw const Smb2Exception('Pool is closed');
    final n = _workers.length;
    Worker? best;
    if (n > 0) {
      final start = _next++ % n;
      best = _workers[start];
      for (var i = 1; i < n && best!.inFlight > 0; i++) {
        final w = _workers[(start + i) % n];
        if (w.inFlight < best.inFlight) best = w;
      }
    }
    final canGrow = _workers.length + _pendingSpawns < _maxWorkers;
    if (best != null && (best.inFlight == 0 || !canGrow)) return best;
    if (best == null && !canGrow) {
      throw const Smb2Exception('Pool is closed');
    }
    return _grow(best);
  }

  /// Spawn one extra worker (lazy start). Falls back to [fallback] — the
  /// least-loaded existing worker — when the spawn fails, e.g. because
  /// the server refuses another session.
  Future<Worker> _grow(Worker? fallback) async {
    _pendingSpawns++;
    try {
      final worker = await _spawnSerialized();
      // [disconnect] may have run between the spawn finishing and this
      // continuation; it no longer sees this worker, so close it here
      // instead of leaking the isolate into a closed pool.
      if (_closed) {
        await worker.close();
        throw const Smb2Exception('Pool is closed');
      }
      _workers.add(worker);
      _scheduleIdleCheck();
      return worker;
    } on Smb2Exception {
      if (fallback == null || _closed) rethrow;
      return fallback;
    } finally {
      _pendingSpawns--;
    }
  }

  /// Spawn a worker through the pool's serial spawn queue so that at most
  /// one isolate of this pool is inside `smb2_init_context` at a time (see
  /// [connect]). Spawns requested after [disconnect] fail fast; a worker
  /// that finishes spawning after it is closed and never handed out.
  Future<Worker> _spawnSerialized() {
    final completer = Completer<Worker>();
    _spawnQueue = _spawnQueue.then((_) async {
      try {
        if (_closed) throw const Smb2Exception('Pool is closed');
        final worker = await Worker.spawn(_params);
        if (_closed) {
          await worker.close();
          throw const Smb2Exception('Pool is closed');
        }
        completer.complete(worker);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  void _scheduleIdleCheck() {
    final timeout = _idleTimeout;
    if (timeout == null || _closed || _idleTimer != null) return;
    if (_workers.length <= _minWorkers) return;
    // Checking at half the timeout bounds the overshoot to 1.5×.
    var interval = timeout ~/ 2;
    if (interval < const Duration(milliseconds: 1)) {
      interval = const Duration(milliseconds: 1);
    }
    _idleTimer = Timer(interval, _retireIdleWorkers);
  }

  /// Retire workers above [_minWorkers] that have been idle for at least
  /// the idle timeout, newest first. Busy workers, workers owning open
  /// handles and workers being reconnected are kept.
  void _retireIdleWorkers() {
    _idleTimer = null;
    final timeout = _idleTimeout;
    if (_closed || timeout == null) return;
    for (final worker in _workers.reversed.toList()) {
      if (_workers.length <= _minWorkers) break;
      if (worker.inFlight > 0 ||
          worker.openHandles > 0 ||
          _reconnectsInFlight.containsKey(worker) ||
          worker.idleFor < timeout) {
        continue;
      }
      _workers.remove(worker);
      late final Future<void> closing;
      closing = worker.close().catchError((Object _) {}).whenComplete(() {
        _retiring.remove(closing);
      });
      _retiring.add(closing);
    }
    _scheduleIdleCheck();
  }

  /// List all entries in a directory.
  Future<List<Smb2DirEntry>> listDirectory(String path) =>
      _sendWithRetry('listDir', {'path': path});

  /// List available shares on the connected server.
  Future<List<Smb2ShareInfo>> listShares({
    required String host,
    String? user,
    String? password,
    String? domain,
  }) async {
    final picked = _acquireWorker();
    final worker = picked is Worker ? picked : await picked;
    return worker.send('listShares', {
      'host': host,
      'user': user,
      'password': password,
      'domain': domain,
    });
  }

  /// Read [length] bytes from a file at [offset].
  Future<Uint8List> readFileRange(
    String path, {
    int offset = 0,
    required int length,
  }) => _sendWithRetry('readRange', {
    'path': path,
    'offset': offset,
    'length': length,
  });

  /// Read an entire file into memory.
  Future<Uint8List> readFile(String path) =>
      _sendWithRetry('readFile', {'path': path});

  /// Get file metadata.
  Future<Smb2Stat> stat(String path) => _sendWithRetry('stat', {'path': path});

  /// Get file size in bytes.
  Future<int> fileSize(String path) =>
      _sendWithRetry('fileSize', {'path': path});

  /// Send a keepalive echo to the server.
  ///
  /// Uses one worker to check if the connection is healthy.
  Future<void> echo() => _sendWithRetry('echo', {});

  /// Get filesystem statistics (total/free space).
  Future<Smb2StatVfs> statvfs(String path) =>
      _sendWithRetry('statvfs', {'path': path});

  /// Read the target path of a symbolic link.
  Future<String> readlink(String path) =>
      _sendWithRetry('readlink', {'path': path});

  /// Flush all buffered writes on a file handle to the server.
  ///
  /// On connection failure, reconnects the worker, reopens the file,
  /// and retries the flush transparently.
  Future<void> fsyncHandle(Smb2PoolHandle handle) => _sendOnHandle<Object?>(
    handle,
    'fsync',
    (id) => {'handleId': id},
    write: true,
  );

  /// Truncate an open file handle to [length] bytes.
  ///
  /// On connection failure, reconnects the worker, reopens the file,
  /// and retries the truncate transparently.
  Future<void> ftruncateHandle(Smb2PoolHandle handle, int length) =>
      _sendOnHandle<Object?>(
        handle,
        'ftruncate',
        (id) => {'handleId': id, 'length': length},
        write: true,
      );

  /// Check whether a file or directory exists.
  ///
  /// Returns `true` if the path exists, `false` if it does not.
  /// Throws [Smb2Exception] on connection or permission errors.
  Future<bool> exists(String path) async {
    try {
      await stat(path);
      return true;
    } on Smb2Exception catch (e) {
      if (e.type == Smb2ErrorType.fileNotFound) return false;
      rethrow;
    }
  }

  // ─── File writing ──────────────────────────────────────────────────────

  /// Write [data] to a file at [offset], creating it if it doesn't exist.
  Future<void> writeFileRange(String path, Uint8List data, {int offset = 0}) =>
      _sendWriteWithRetry('writeRange', data, {'path': path, 'offset': offset});

  /// Write [data] to a file, creating or truncating it.
  Future<void> writeFile(String path, Uint8List data) =>
      _sendWriteWithRetry('writeFile', data, {'path': path});

  // ─── File/directory management ────────────────────────────────────────

  /// Delete a file.
  Future<void> deleteFile(String path) =>
      _sendWithRetry('deleteFile', {'path': path});

  /// Create a directory.
  Future<void> mkdir(String path) => _sendWithRetry('mkdir', {'path': path});

  /// Delete an empty directory.
  Future<void> rmdir(String path) => _sendWithRetry('rmdir', {'path': path});

  /// Rename or move a file or directory.
  Future<void> rename(String oldPath, String newPath) =>
      _sendWithRetry('rename', {'oldPath': oldPath, 'newPath': newPath});

  /// Truncate a file to [length] bytes.
  Future<void> truncate(String path, int length) =>
      _sendWithRetry('truncate', {'path': path, 'length': length});

  // ─── File handles ──────────────────────────────────────────────────────

  /// Open a file for reading and return a handle tied to one worker.
  ///
  /// Use [readFromHandle] and [closeHandle] with the returned handle.
  /// All operations on a handle are routed to the same worker isolate.
  Future<Smb2PoolHandle> openFile(String path) async {
    final picked = _acquireWorker();
    var worker = picked is Worker ? picked : await picked;
    try {
      final handleId = await worker.send<int>('openFile', {'path': path});
      return Smb2PoolHandle(worker, handleId, path);
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      worker = await _reconnectWorker(worker);
      final handleId = await worker.send<int>('openFile', {'path': path});
      return Smb2PoolHandle(worker, handleId, path);
    }
  }

  /// Open a file and get its size in one call.
  ///
  /// Returns `(handle, fileSize)`. Saves a network round-trip vs
  /// calling [fileSize] + [openFile] separately.
  Future<(Smb2PoolHandle, int)> openFileWithSize(String path) async {
    final picked = _acquireWorker();
    var worker = picked is Worker ? picked : await picked;
    try {
      return await _openFileWithSizeOn(worker, path);
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      worker = await _reconnectWorker(worker);
      return await _openFileWithSizeOn(worker, path);
    }
  }

  Future<(Smb2PoolHandle, int)> _openFileWithSizeOn(
    Worker worker,
    String path,
  ) async {
    final result = await worker.send<List<dynamic>>('openFileWithSize', {
      'path': path,
    });
    return (Smb2PoolHandle(worker, result[0] as int, path), result[1] as int);
  }

  /// Read [length] bytes at [offset] from an open handle.
  ///
  /// On connection failure, reconnects the worker, reopens the file,
  /// and retries the read transparently.
  Future<Uint8List> readFromHandle(
    Smb2PoolHandle handle, {
    int offset = 0,
    required int length,
  }) => _sendOnHandle<Uint8List>(
    handle,
    'readHandle',
    (id) => {'handleId': id, 'offset': offset, 'length': length},
    write: false,
  );

  /// Close an open file handle.
  Future<void> closeHandle(Smb2PoolHandle handle) async {
    if (handle.closed) return;
    handle.markClosed();
    try {
      await handle.worker.send('closeHandle', {'handleId': handle.id});
    } catch (_) {
      // Best-effort — the handle may already be invalid after reconnect.
    }
  }

  /// Open a file for writing and return a handle tied to one worker.
  ///
  /// The file is created if it doesn't exist.
  /// Use [writeToHandle] to write, then [closeHandle] when done.
  Future<Smb2PoolHandle> openFileWrite(String path) async {
    final picked = _acquireWorker();
    var worker = picked is Worker ? picked : await picked;
    try {
      final handleId = await worker.send<int>('openFileWrite', {'path': path});
      return Smb2PoolHandle(worker, handleId, path);
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      worker = await _reconnectWorker(worker);
      final handleId = await worker.send<int>('openFileWrite', {'path': path});
      return Smb2PoolHandle(worker, handleId, path);
    }
  }

  /// Write [data] at [offset] to an open write handle.
  ///
  /// On connection failure, reconnects the worker, reopens the file,
  /// and retries the write transparently.
  Future<void> writeToHandle(
    Smb2PoolHandle handle,
    Uint8List data, {
    int offset = 0,
  }) => _sendOnHandle<Object?>(
    handle,
    'writeHandle',
    // A fresh TransferableTypedData per attempt: a transferred buffer can
    // only be materialized once.
    (id) => {
      'handleId': id,
      'data': TransferableTypedData.fromList([data]),
      'offset': offset,
    },
    write: true,
  );

  /// Send a handle-bound command with one reconnect + reopen retry.
  ///
  /// [args] builds the arguments for the handle id of each attempt. The
  /// worker/id pair the first attempt went to is captured up front: when
  /// several requests are in flight on the same handle (read-ahead,
  /// pipelined writes) and all fail together, only the first one
  /// reconnects + reopens; the others join that reopen (or, if it already
  /// finished, retry straight on the replacement handle) instead of
  /// reconnecting the healthy replacement worker or leaking extra
  /// server-side handles.
  Future<T> _sendOnHandle<T>(
    Smb2PoolHandle handle,
    String cmd,
    Map<String, Object?> Function(int handleId) args, {
    required bool write,
  }) async {
    final worker = handle.worker;
    final id = handle.id;
    try {
      return await worker.send<T>(cmd, args(id));
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      final reopening = _handleReopens[handle];
      if (reopening != null) {
        await reopening;
      } else if (identical(handle.worker, worker) && handle.id == id) {
        await _reopen(handle, write: write);
      } else {
        _throwIfClosed(handle);
      }
      return await handle.worker.send<T>(cmd, args(handle.id));
    }
  }

  /// In-flight handle reopens, so concurrent failures on one handle share
  /// a single reconnect + reopen (see [_sendOnHandle]).
  final Map<Smb2PoolHandle, Future<void>> _handleReopens = {};

  Future<void> _reopen(Smb2PoolHandle handle, {required bool write}) {
    final existing = _handleReopens[handle];
    if (existing != null) return existing;
    final future = write ? _reopenWriteHandle(handle) : _reopenHandle(handle);
    _handleReopens[handle] = future;
    future.then<void>(
      (_) => _handleReopens.remove(handle),
      onError: (Object _, StackTrace _) {
        _handleReopens.remove(handle);
      },
    );
    return future;
  }

  /// Reconnect the worker and reopen the file for writing.
  ///
  /// Honors a concurrent [closeHandle] call: if the handle is marked
  /// closed at any of the three observation points (entry, after the
  /// reconnect await, after the new open), we throw a typed
  /// connection error and best-effort close the just-opened handle.
  /// Without this, a parallel `closeHandle(h) + readFromHandle(h)`
  /// could leave the read path reopening a fresh handle that nobody owns.
  Future<void> _reopenWriteHandle(Smb2PoolHandle handle) async {
    _throwIfClosed(handle);
    handle.worker = await _reconnectWorker(handle.worker);
    _invalidateHandleId(handle);
    _throwIfClosed(handle);
    final newId = await handle.worker.send<int>('openFileWrite', {
      'path': handle.path,
    });
    if (handle.closed) {
      _closeOrphanHandle(handle.worker, newId);
      _throwClosedDuringRetry();
    }
    handle.id = newId;
    handle.refreshFinalizer();
  }

  /// Reconnect the worker and reopen the file, updating the handle in-place.
  ///
  /// See [_reopenWriteHandle] for how a concurrent close is handled.
  Future<void> _reopenHandle(Smb2PoolHandle handle) async {
    _throwIfClosed(handle);
    handle.worker = await _reconnectWorker(handle.worker);
    _invalidateHandleId(handle);
    _throwIfClosed(handle);
    final newId = await handle.worker.send<int>('openFile', {
      'path': handle.path,
    });
    if (handle.closed) {
      _closeOrphanHandle(handle.worker, newId);
      _throwClosedDuringRetry();
    }
    handle.id = newId;
    handle.refreshFinalizer();
  }

  /// The old worker-local id means nothing on the replacement worker —
  /// worse, it may name a *different* file opened there. Until the reopen
  /// succeeds, park the handle on an id no worker ever hands out, so a
  /// failed reopen leaves an invalid handle instead of a wrong one, and
  /// re-arm the GC finalizer for the new worker (it only fixes up the
  /// open-handle count for this id).
  static void _invalidateHandleId(Smb2PoolHandle handle) {
    handle.id = Smb2PoolHandle.noId;
    handle.refreshFinalizer();
  }

  static void _throwIfClosed(Smb2PoolHandle handle) {
    if (handle.closed) _throwClosedDuringRetry();
  }

  static Never _throwClosedDuringRetry() {
    throw const Smb2Exception(
      'Handle was closed during reconnect',
      null,
      Smb2ErrorType.connection,
    );
  }

  /// Fire-and-forget close on a handle we just reopened on the new
  /// worker — only invoked when a concurrent [closeHandle] beat us to
  /// the punch, so the caller no longer wants it.
  static void _closeOrphanHandle(Worker worker, int handleId) {
    worker.post('closeHandle', {'handleId': handleId});
  }

  /// Write data from a [Stream] to a file without loading everything into RAM.
  ///
  /// Opens a write handle, writes the chunks in order, and closes.
  ///
  /// Up to [maxInFlight] chunk writes are kept outstanding on the worker
  /// so the next chunk is already on its way while the previous one is
  /// being written; the worker executes them strictly in order. Pass `1`
  /// to wait for each write before sending the next. The first failing
  /// write stops the stream: remaining in-flight writes are awaited (their
  /// outcome ignored), the handle is closed, and that first error is
  /// rethrown.
  ///
  /// Unlike other write operations, streamed writes do **not** retry on
  /// connection failure — a partial write cannot be safely resumed because
  /// the server-side state is unknown. If the connection drops mid-stream,
  /// the error is propagated immediately.
  Future<void> streamWrite(
    String path,
    Stream<Uint8List> chunks, {
    int maxInFlight = 2,
  }) async {
    _checkMaxInFlight(maxInFlight);
    final handle = await openFileWrite(path);
    final inFlight = ListQueue<Future<Object?>>();
    try {
      await ftruncateHandle(handle, 0);
      int offset = 0;
      await for (final chunk in chunks) {
        if (inFlight.length >= maxInFlight) await inFlight.removeFirst();
        // Send directly to the worker without retry — a reconnect would
        // reopen the file and lose track of how many bytes the server
        // actually received, causing data corruption.
        final write = handle.worker.send<Object?>('writeHandle', {
          'handleId': handle.id,
          'data': TransferableTypedData.fromList([chunk]),
          'offset': offset,
        });
        // Errors surface when the write is dequeued above / below; this
        // only stops them being reported as unhandled meanwhile.
        write.ignore();
        inFlight.add(write);
        offset += chunk.length;
      }
      while (inFlight.isNotEmpty) {
        await inFlight.removeFirst();
      }
    } finally {
      await _drain(inFlight);
      await closeHandle(handle);
    }
  }

  /// Stream a file in chunks without loading everything into RAM.
  ///
  /// Keeps a single file handle open for the whole read — one `Create`
  /// on the wire, then `smb2_pread` (splits into server-negotiated
  /// MaxReadSize packets internally), then one `Close`. The handle is
  /// released when the stream completes, errors, or is canceled.
  ///
  /// - [chunkSize] controls the Dart-side buffer per iteration. The
  ///   network layer chunks independently into libsmb2's
  ///   `max_read_size` (typically 1 MiB). Larger [chunkSize] means
  ///   fewer isolate round-trips and fewer progress callbacks.
  /// - [onProgress] fires after each chunk with `(received, total)`
  ///   bytes. `total` is the file size; 0 if unknown.
  /// - [isCanceled] is polled before each chunk is awaited. Returning
  ///   `true` aborts the stream with an `Smb2Exception('canceled')`.
  /// - [maxInFlight] bounds the read-ahead: at most that many chunks are
  ///   outstanding at once, counting the one the listener is processing.
  ///   With the default `2` the next chunk is already being read while
  ///   the listener handles the current one; `1` reads strictly one
  ///   chunk at a time (no read-ahead). On cancel, error, or when the
  ///   listener cancels its subscription, the outstanding reads are
  ///   awaited and discarded before the handle is closed.
  Stream<Uint8List> streamFile(
    String path, {
    int chunkSize = 1024 * 1024,
    void Function(int received, int total)? onProgress,
    bool Function()? isCanceled,
    int maxInFlight = 2,
  }) async* {
    _checkMaxInFlight(maxInFlight);
    final (handle, size) = await openFileWithSize(path);
    final inFlight = ListQueue<({int length, Future<Uint8List> data})>();
    try {
      if (size <= 0) return;
      var offset = 0; // bytes delivered to the listener
      var nextOffset = 0; // first byte not yet requested
      void fill(int limit) {
        while (inFlight.length < limit && nextOffset < size) {
          final remaining = size - nextOffset;
          final length = remaining < chunkSize ? remaining : chunkSize;
          final data = readFromHandle(
            handle,
            offset: nextOffset,
            length: length,
          );
          // Errors surface when the read is dequeued (or drained in
          // `finally`); this only stops them being reported as unhandled
          // while the read waits in the queue.
          data.ignore();
          inFlight.add((length: length, data: data));
          nextOffset += length;
        }
      }

      while (offset < size) {
        if (isCanceled?.call() ?? false) {
          throw const Smb2Exception('Read canceled');
        }
        fill(maxInFlight);
        final next = inFlight.removeFirst();
        final chunk = await next.data;
        // A read of 0 bytes before reaching [size] means the file was
        // truncated by another client mid-stream — surface it as an error
        // instead of silently returning a short, incomplete result.
        if (chunk.isEmpty) {
          throw Smb2Exception(
            'File shrank mid-stream: expected $size bytes, got $offset',
            null,
            Smb2ErrorType.io,
          );
        }
        offset += chunk.length;
        if (chunk.length < next.length) {
          // Short read: the queued reads assumed this one was full. Drop
          // them and continue right after the bytes actually received.
          await _drain(inFlight.map((r) => r.data));
          inFlight.clear();
          nextOffset = offset;
        } else {
          // Keep reads in flight while the listener consumes this chunk;
          // the chunk it holds counts against [maxInFlight], so `1` keeps
          // the strictly serial read → yield → read behaviour.
          fill(maxInFlight - 1);
        }
        onProgress?.call(offset, size);
        yield chunk;
      }
    } finally {
      await _drain(inFlight.map((r) => r.data));
      inFlight.clear();
      await closeHandle(handle);
    }
  }

  static void _checkMaxInFlight(int maxInFlight) {
    if (maxInFlight < 1) {
      throw RangeError.range(maxInFlight, 1, null, 'maxInFlight');
    }
  }

  /// Await every future in [futures], ignoring their outcome. Used to let
  /// outstanding handle requests settle before the handle is closed.
  static Future<void> _drain(Iterable<Future<Object?>> futures) async {
    for (final f in futures.toList()) {
      try {
        await f;
      } catch (_) {
        // The caller is already unwinding with its own result or error.
      }
    }
  }

  /// Download [path] to [destFile], writing in chunks via the same
  /// persistent handle [streamFile] uses.
  ///
  /// Returns the number of bytes written. On cancel or error the
  /// destination file is left as-is — callers that want atomic writes
  /// should download to a `.part` file and rename on success.
  /// [maxInFlight] is forwarded to [streamFile] (read-ahead depth).
  Future<int> downloadToFile(
    String path,
    File destFile, {
    int chunkSize = 1024 * 1024,
    void Function(int received, int total)? onProgress,
    bool Function()? isCanceled,
    int maxInFlight = 2,
  }) async {
    _checkMaxInFlight(maxInFlight);
    final sink = destFile.openWrite();
    var total = 0;
    try {
      await for (final chunk in streamFile(
        path,
        chunkSize: chunkSize,
        onProgress: onProgress,
        isCanceled: isCanceled,
        maxInFlight: maxInFlight,
      )) {
        sink.add(chunk);
        total += chunk.length;
      }
    } finally {
      await sink.close();
    }
    return total;
  }

  /// Open [path] for reading, run [body] with a scoped [Smb2File],
  /// and guarantee the handle is closed on any exit path.
  ///
  /// Preferred over raw [openFileWithSize]/[closeHandle] pairs because
  /// it composes with exceptions, early returns, and cancellation
  /// without boilerplate.
  ///
  /// Pass [knownSize] when you already have the file size from a prior
  /// `stat` or directory listing — this uses the cheaper [openFile]
  /// (no `fstat` round-trip) and populates [Smb2File.size] from the
  /// argument. Omit it to do one combined `open + fstat`.
  ///
  /// ```dart
  /// final tags = await pool.withFile('Music/song.flac', (file) async {
  ///   final header = await file.read(length: 64 * 1024);
  ///   return parseVorbisComments(
  ///     header,
  ///     fileSize: file.size,
  ///     fallbackRead: (o, n) => file.read(offset: o, length: n),
  ///   );
  /// });
  /// ```
  Future<T> withFile<T>(
    String path,
    FutureOr<T> Function(Smb2File file) body, {
    int? knownSize,
  }) async {
    final Smb2PoolHandle handle;
    final int size;
    if (knownSize != null) {
      handle = await openFile(path);
      size = knownSize;
    } else {
      final (h, s) = await openFileWithSize(path);
      handle = h;
      size = s;
    }
    try {
      return await body(Smb2File(this, handle, size));
    } finally {
      await closeHandle(handle);
    }
  }

  /// Disconnect all workers and release resources.
  Future<void> disconnect() async {
    if (_closed && _workers.isEmpty) return;
    _closed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    await Future.wait([..._workers.map((w) => w.close()), ..._retiring]);
    // Spawns still queued (growth / reconnect) fail fast or close the
    // worker they just created; wait so no isolate outlives the pool.
    await _spawnQueue;
    _workers.clear();
  }

  // ─── Auto-reconnect wrapper ────────────────────────────────────────────

  /// Send a command with one retry on connection failure.
  ///
  /// If the worker reports a connection error, it is respawned with a fresh
  /// TCP connection and the command is retried once.
  Future<T> _sendWithRetry<T>(String cmd, Map<String, Object?> args) async {
    final picked = _acquireWorker();
    var worker = picked is Worker ? picked : await picked;
    try {
      return await worker.send<T>(cmd, args);
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      // Reconnect this worker and retry once
      worker = await _reconnectWorker(worker);
      return await worker.send<T>(cmd, args);
    }
  }

  /// Like [_sendWithRetry] but for write commands that carry [Uint8List] data.
  ///
  /// A fresh [TransferableTypedData] is created for each attempt because
  /// a transferred buffer can only be materialized once — reusing it on
  /// retry would crash.
  Future<void> _sendWriteWithRetry(
    String cmd,
    Uint8List data,
    Map<String, Object?> args,
  ) async {
    final picked = _acquireWorker();
    var worker = picked is Worker ? picked : await picked;
    try {
      await worker.send<Object?>(cmd, {
        ...args,
        'data': TransferableTypedData.fromList([data]),
      });
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      worker = await _reconnectWorker(worker);
      await worker.send<Object?>(cmd, {
        ...args,
        'data': TransferableTypedData.fromList([data]),
      });
    }
  }

  /// In-flight reconnect futures, keyed on the failing [Worker] that
  /// triggered the rebuild. Single-flight: concurrent ops that all see
  /// the same worker fail share one reconnect attempt instead of each
  /// racing to spawn its own replacement.
  ///
  /// Without this coalescing, N parallel calls failing on the same worker
  /// would each spawn a replacement — leaking N-1 orphan isolates and
  /// leaving some callers pointing at a worker they never see.
  final Map<Worker, Future<Worker>> _reconnectsInFlight = {};

  /// Closes [worker], spawns a fresh replacement at the same slot, and returns it.
  ///
  /// Coalesces concurrent retries on the same dead worker via
  /// [_reconnectsInFlight] — the first caller starts the work and every
  /// other caller awaits the same future. Once it settles (success or
  /// failure) the map entry is removed so a *future* failure on the
  /// replacement worker can trigger its own reconnect.
  Future<Worker> _reconnectWorker(Worker worker) {
    final existing = _reconnectsInFlight[worker];
    if (existing != null) return existing;

    final future = _doReconnect(worker);
    _reconnectsInFlight[worker] = future;
    future.then<void>(
      (_) => _reconnectsInFlight.remove(worker),
      onError: (Object _, StackTrace _) {
        _reconnectsInFlight.remove(worker);
      },
    );
    return future;
  }

  Future<Worker> _doReconnect(Worker worker) async {
    if (_closed) throw const Smb2Exception('Pool is closed');
    if (!_workers.contains(worker)) {
      // Another caller's reconnect already replaced this worker (or idle
      // shrinking retired it). Handing the dead worker back would make the
      // retry fail again, so route the retry to a live pool worker.
      final picked = _acquireWorker();
      return picked is Worker ? picked : await picked;
    }
    await worker.close();
    if (_closed) throw const Smb2Exception('Pool is closed');
    if (!_workers.contains(worker)) {
      throw const Smb2Exception('Worker was replaced during reconnect');
    }
    final newWorker = await _spawnSerialized();
    // Look the slot up again: idle shrinking / growth may have shifted
    // indices while we were awaiting.
    final idx = _workers.indexOf(worker);
    if (_closed || idx < 0) {
      await newWorker.close();
      throw const Smb2Exception('Pool closed during worker reconnect');
    }
    _workers[idx] = newWorker;
    return newWorker;
  }

  static bool _isConnectionError(Smb2Exception e) => e.isConnectionError;
}
