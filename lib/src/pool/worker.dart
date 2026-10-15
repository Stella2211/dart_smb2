// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Main-isolate proxy for a single worker isolate. [Worker.spawn] kicks
/// off the worker, [Worker.send] forwards a command, [Worker.close]
/// asks it to abort native resources locally and waits for the isolate to
/// exit without killing it while a native callback may be pending.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';

import '../smb2_error_type.dart';
import '../smb2_exceptions.dart';
import 'messages.dart';
import 'worker_main.dart';

/// One worker isolate's handle. Visible to [Smb2Pool] and to
/// [Smb2PoolHandle]'s finalizer; not part of the public API.
class Worker {
  final SendPort _sendPort;
  final Isolate _isolate;
  final ReceivePort _exitPort;
  final Future<void> _exitedFuture;

  /// Shared reply channel for every [send] on this worker. Replies carry
  /// the request id ([ReplyMsg.id]) so one long-lived port replaces the
  /// per-request `ReceivePort` the hot path used to allocate.
  final ReceivePort _replyPort = ReceivePort();

  /// Currently-awaited [send] completers, keyed on request id. Tracked so
  /// that if the worker dies (Isolate-level exit OR explicit [close]) we
  /// can finish every pending Future with a typed connection error
  /// instead of leaving them hung forever waiting on a reply that's never
  /// coming.
  final Map<int, Completer<Object?>> _pending = {};
  int _nextRequestId = 0;

  /// Number of [Smb2PoolHandle]s currently bound to this worker. Handles
  /// are worker-local, so the pool never retires a worker that still owns
  /// one (see `Smb2Pool` idle shrinking).
  int openHandles = 0;

  /// Monotonic timestamp (microseconds, [_clock]) of the last time this
  /// worker had a request start or finish. Drives idle shrinking.
  int _lastActiveMicros = _clock.elapsedMicroseconds;
  static final Stopwatch _clock = Stopwatch()..start();

  bool _dead = false;
  bool _closing = false;
  Future<void>? _closeFuture;

  /// Sentinel returned by the `initPort` vs `exitPort` race in [spawn]
  /// when the isolate exits before ever sending an init result (e.g. an
  /// uncaught error that predates the `try`/`catch` in [workerMain]).
  /// Without this race, such a death would leave `initPort.first`
  /// awaiting forever since nothing was ever sent on it.
  static const _diedDuringInit = 'Worker isolate exited during startup';
  static final Object _workerExited = Object();

  Worker._(this._sendPort, this._isolate, this._exitPort, Future<void> exited)
    : _exitedFuture = exited {
    // NOTE: `_exitPort` is already being listened to by [spawn] (a
    // ReceivePort is single-subscription and can only ever be listened
    // to once), so death is observed through the shared [exited] future
    // instead of a second `listen` call.
    exited.then((_) => _markDead());
    _replyPort.listen(_onReply);
  }

  /// `true` once the worker isolate has exited (either via [close], an
  /// uncaught error, or an explicit kill). [send] starts rejecting
  /// immediately after this flips so callers don't queue up new requests
  /// against a dead worker.
  bool get isDead => _dead;

  /// Number of [send] calls awaiting a reply. Used by the pool to route
  /// new work to the least-loaded worker.
  int get inFlight => _pending.length;

  /// How long this worker has had no request in flight. [Duration.zero]
  /// while a request is pending.
  Duration get idleFor => _pending.isNotEmpty
      ? Duration.zero
      : Duration(microseconds: _clock.elapsedMicroseconds - _lastActiveMicros);

  /// Spawn a worker isolate with the given [ConnectParams] and wait for
  /// it to confirm a successful libsmb2 connection.
  static Future<Worker> spawn(ConnectParams p) async {
    final initPort = ReceivePort();
    final exitPort = ReceivePort();
    final isolate = await Isolate.spawn(
      workerMain,
      InitMsg(
        sendPort: initPort.sendPort,
        host: p.host,
        share: p.share,
        user: p.user,
        password: p.password,
        domain: p.domain,
        timeoutSeconds: p.timeoutSeconds,
        seal: p.seal,
        signing: p.signing,
        version: p.version,
        testLibOverride: p.testLibOverride,
      ),
    );

    // Registered before awaiting `initPort` so that if the isolate dies
    // before ever sending an init result (e.g. an uncaught error in
    // `workerMain` predating its try/catch), `exitPort` fires and the
    // race below resolves instead of hanging on `initPort.first` forever.
    isolate.addOnExitListener(exitPort.sendPort);

    // A ReceivePort is a single-subscription stream, so this is the one
    // and only `listen` on `exitPort` for the worker's whole lifetime.
    // Using `exitPort.first` here would leave that subscription claimed
    // on the success path and make any later listen throw
    // "Stream has already been listened to".
    final exited = Completer<void>();
    exitPort.listen((_) {
      if (!exited.isCompleted) exited.complete();
    });

    final result = await Future.any([
      initPort.first,
      exited.future.then((_) => _diedDuringInit),
    ]);
    initPort.close();

    if (result is SendPort) {
      return Worker._(result, isolate, exitPort, exited.future);
    }
    // Initialisation failed; drop the exit subscription with the port.
    exitPort.close();
    throw Smb2Exception('Worker failed to start: $result');
  }

  void _onReply(Object? msg) {
    if (msg is! ReplyMsg) return;
    final completer = _pending.remove(msg.id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(msg.value);
    }
  }

  /// Send [cmd] with [args] and await its reply.
  ///
  /// Two races resolve the returned Future:
  ///
  ///   1. The worker replies → [_onReply] looks the request id up in
  ///      [_pending] and completes its Completer with that value (or the
  ///      awaiter throws an [Smb2Exception] reconstructed from the
  ///      wire-format [ErrorMsg]).
  ///   2. The worker dies → [_markDead] iterates every pending
  ///      Completer and finishes it with a typed connection
  ///      [Smb2Exception], so the awaiter sees an error instead of a
  ///      Future that never settles.
  ///
  /// Both paths share the same Completer; whichever fires first wins,
  /// and the other side is a no-op (the second check guards against
  /// `Completer.complete` being called twice).
  ///
  /// [args] is forwarded as-is (not copied); callers must not mutate it
  /// after the call.
  Future<T> send<T>(String cmd, Map<String, Object?> args) async {
    if (_dead || _closing) {
      throw const Smb2Exception(
        'Worker isolate is dead',
        null,
        Smb2ErrorType.connection,
      );
    }
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _lastActiveMicros = _clock.elapsedMicroseconds;
    try {
      _sendPort.send(RequestMsg(cmd, args, id, _replyPort.sendPort));
      final result = await completer.future;
      if (result is ErrorMsg) throw result.toException();
      if (result is TransferableTypedData) {
        return result.materialize().asUint8List() as T;
      }
      return result as T;
    } finally {
      _pending.remove(id);
      _lastActiveMicros = _clock.elapsedMicroseconds;
    }
  }

  /// Fire-and-forget variant of [send]: no reply is requested, nothing is
  /// tracked and errors are dropped. Used for best-effort cleanup (GC
  /// finalizers, orphaned handles) where nobody awaits the outcome.
  void post(String cmd, Map<String, Object?> args) {
    if (_dead || _closing) return;
    try {
      _sendPort.send(RequestMsg(cmd, args));
    } catch (_) {
      // Best-effort only.
    }
  }

  /// Mark the worker dead and fail every pending [send]. Called from
  /// the [Isolate.addOnExitListener] callback and from [close].
  ///
  /// Idempotent: calling it twice is harmless.
  void _markDead() {
    if (_dead) return;
    _dead = true;
    _failPending(
      const Smb2Exception(
        'Worker isolate died with in-flight requests',
        null,
        Smb2ErrorType.connection,
      ),
    );
    _replyPort.close();
    _exitPort.close();
  }

  void _failPending(Smb2Exception error) {
    // Snapshot to a list — completing a Completer triggers `finally`
    // blocks in `send` that mutate `_pending`.
    final completers = _pending.values.toList();
    _pending.clear();
    for (final c in completers) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  /// Ask the worker to abort native resources locally and exit cleanly.
  ///
  /// The worker acknowledges only after its native context is safely
  /// disposed. There is deliberately no time-based isolate kill: killing
  /// while a native callback is pending can invoke the finalizer during
  /// isolate unwinding and abort the process.
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final future = _closeImpl();
    _closeFuture = future;
    return future;
  }

  Future<void> _closeImpl() async {
    if (_dead) return;
    _closing = true;
    // A dedicated one-shot port (instead of [_replyPort]) keeps the close
    // acknowledgement out of [_pending], which is failed wholesale below
    // and again by [_markDead] when the isolate exits.
    final replyPort = ReceivePort();
    try {
      // Closing invalidates all outstanding requests. Complete them before
      // waiting for the worker's native abort acknowledgement.
      _failPending(
        const Smb2Exception(
          'Worker is closing',
          null,
          Smb2ErrorType.connection,
        ),
      );
      _sendPort.send(RequestMsg('close', const {}, 0, replyPort.sendPort));
      // worker_main aborts its native context without waiting for network
      // CLOSE replies, then closes its command port. Never kill an isolate
      // while a native callback may still be unwinding.
      final reply = await Future.any<Object?>([
        replyPort.first,
        _exitedFuture.then((_) => _workerExited),
      ]);
      // An isolate which exits before replying has completed teardown. If it
      // acknowledges first, wait for the actual isolate exit as well; an ACK
      // only means that abort() returned, not that native callbacks are no
      // longer able to run during isolate shutdown.
      if (identical(reply, _workerExited)) return;
      final result = reply is ReplyMsg ? reply.value : reply;
      if (result is ErrorMsg) throw result.toException();
      if (result != true) {
        throw const Smb2Exception(
          'Worker close returned an invalid acknowledgement',
          null,
          Smb2ErrorType.connection,
        );
      }
      await _exitedFuture;
    } finally {
      replyPort.close();
      _markDead();
    }
  }

  /// Test-only: kill the worker isolate immediately, without sending
  /// the cooperative `close` message first. Lets tests verify that
  /// pending sends complete with a connection error instead of hanging
  /// forever waiting on a reply that's never coming.
  @visibleForTesting
  void killForTest() {
    if (_dead) return;
    _isolate.kill(priority: Isolate.immediate);
    _markDead();
  }
}
