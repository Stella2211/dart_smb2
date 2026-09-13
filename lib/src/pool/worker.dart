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

  /// Currently-awaited [send] completers. Tracked so that if the worker
  /// dies (Isolate-level exit OR explicit [close]) we can finish every
  /// pending Future with a typed connection error instead of leaving
  /// them hung forever waiting on a reply that's never coming.
  final Set<Completer<dynamic>> _pending = {};

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

  Worker._(
    this._sendPort,
    this._isolate,
    this._exitPort,
    Future<void> exited,
  ) : _exitedFuture = exited {
    // NOTE: `_exitPort` is already being listened to by [spawn] (a
    // ReceivePort is single-subscription and can only ever be listened
    // to once), so death is observed through the shared [exited] future
    // instead of a second `listen` call.
    exited.then((_) => _markDead());
  }

  /// Internal accessor used by [Smb2PoolHandle]'s GC finalizer to
  /// best-effort close a leaked handle. Wrapping it as a getter keeps
  /// [_sendPort] genuinely private to this file otherwise.
  SendPort get sendPort => _sendPort;

  /// `true` once the worker isolate has exited (either via [close], an
  /// uncaught error, or an explicit kill). [send] starts rejecting
  /// immediately after this flips so callers don't queue up new requests
  /// against a dead worker.
  bool get isDead => _dead;

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

  /// Send [cmd] with [args] and await its reply.
  ///
  /// Two races resolve the returned Future:
  ///
  ///   1. The worker replies → the awaiting Completer completes with
  ///      that value (or throws an [Smb2Exception] reconstructed from
  ///      the wire-format [ErrorMsg]).
  ///   2. The worker dies → [_markDead] iterates every pending
  ///      Completer and finishes it with a typed connection
  ///      [Smb2Exception], so the awaiter sees an error instead of a
  ///      Future that never settles.
  ///
  /// Both paths share the same Completer; whichever fires first wins,
  /// and the other side is a no-op (the second check guards against
  /// `Completer.complete` being called twice).
  Future<T> send<T>(String cmd, Map<String, dynamic> args) async {
    if (_dead || _closing) {
      throw const Smb2Exception(
        'Worker isolate is dead',
        null,
        Smb2ErrorType.connection,
      );
    }
    final replyPort = ReceivePort();
    final completer = Completer<dynamic>();
    _pending.add(completer);
    StreamSubscription<dynamic>? sub;
    try {
      sub = replyPort.listen((msg) {
        if (!completer.isCompleted) completer.complete(msg);
      });
      _sendPort.send({...args, 'cmd': cmd, 'replyTo': replyPort.sendPort});
      final result = await completer.future;
      if (result is ErrorMsg) {
        throw Smb2Exception(
          result.message,
          result.errorCode,
          result.errorTypeIndex != null
              ? Smb2ErrorType.values[result.errorTypeIndex!]
              : Smb2ErrorType.unknown,
        );
      }
      if (result is TransferableTypedData) {
        return result.materialize().asUint8List() as T;
      }
      return result as T;
    } finally {
      _pending.remove(completer);
      await sub?.cancel();
      replyPort.close();
    }
  }

  /// Mark the worker dead and fail every pending [send]. Called from
  /// the [Isolate.addOnExitListener] callback and from [close].
  ///
  /// Idempotent: calling it twice is harmless.
  void _markDead() {
    if (_dead) return;
    _dead = true;
    const error = Smb2Exception(
      'Worker isolate died with in-flight requests',
      null,
      Smb2ErrorType.connection,
    );
    // Snapshot to a list — completing a Completer triggers `finally`
    // blocks in `send` that mutate `_pending`.
    for (final c in _pending.toList()) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
    _exitPort.close();
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
    final replyPort = ReceivePort();
    try {
      // Closing invalidates all outstanding requests. Complete them before
      // waiting for the worker's native abort acknowledgement.
      const error = Smb2Exception(
        'Worker is closing',
        null,
        Smb2ErrorType.connection,
      );
      for (final c in _pending.toList()) {
        if (!c.isCompleted) c.completeError(error);
      }
      _sendPort.send({'cmd': 'close', 'replyTo': replyPort.sendPort});
      // worker_main aborts its native context without waiting for network
      // CLOSE replies, then closes its command port. Never kill an isolate
      // while a native callback may still be unwinding.
      final result = await Future.any<dynamic>([
        replyPort.first,
        _exitedFuture.then((_) => _workerExited),
      ]);
      // An isolate which exits before replying has completed teardown. If it
      // acknowledges first, wait for the actual isolate exit as well; an ACK
      // only means that abort() returned, not that native callbacks are no
      // longer able to run during isolate shutdown.
      if (identical(result, _workerExited)) return;
      if (result is ErrorMsg) {
        throw Smb2Exception(
          result.message,
          result.errorCode,
          result.errorTypeIndex != null
              ? Smb2ErrorType.values[result.errorTypeIndex!]
              : Smb2ErrorType.unknown,
        );
      }
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
