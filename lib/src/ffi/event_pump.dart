// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Dart-side event pump for libsmb2's async API.
///
/// This replaces libsmb2's own sync wrappers (`sync.c`): every operation is
/// started with its upstream `*_async` function and then driven to
/// completion by a poll/`smb2_service` loop owned by Dart. Two problems
/// with the C sync wrappers made this necessary:
///
///   1. `sync.c`'s `wait_for_reply` aborts with "Poll failed" whenever
///      `poll()` returns `EINTR` — and the Dart/ART VMs routinely interrupt
///      syscalls with signals (GC safepoints, profilers). The Dart loop
///      below simply retries on `EINTR`, which is the standard treatment.
///   2. The sync wrappers swallow the completion `status` for several
///      compound operations (stat/mkdir/rename/…), leaving the context's
///      NT-error stale. Driving the callback ourselves hands us the fresh
///      `-errno` for every operation.
///
/// Both were previously worked around by patching libsmb2 itself; owning
/// the wait loop in Dart lets the package run against **unmodified
/// upstream libsmb2**.
///
/// Threading model: everything here is synchronous and isolate-local.
/// `smb2_service` is only ever called from the same thread that started
/// the operation, so completion callbacks (created with
/// [NativeCallable.isolateLocal]) always fire synchronously inside
/// [Smb2EventPump.run] — never concurrently.
library;

import 'dart:ffi';
import 'dart:io' show Platform, sleep;

import 'package:ffi/ffi.dart';

import '../smb2_error_type.dart';
import '../smb2_exceptions.dart';
import 'libsmb2_bindings.dart';

/// Result of one completed async libsmb2 operation.
class Smb2OpResult {
  /// The `status` value passed to the completion callback.
  ///
  /// `>= 0` means success (for pread/pwrite it is the byte count);
  /// a negative value is `-errno`.
  final int status;

  /// The `command_data` pointer passed to the completion callback
  /// (operation-specific: `smb2fh*`, `smb2dir*`, response trees, …).
  ///
  /// Only pointers that stay valid after the callback returns may be
  /// consumed through this field. For callback-transient data (e.g.
  /// `smb2_readlink_async`'s target string, which libsmb2 frees as soon
  /// as the callback returns) pass a `capture` function to
  /// [Smb2EventPump.run] and read [captured] instead.
  final Pointer<Void> data;

  /// The value produced by the `capture` callback inside the completion
  /// callback, while [data] was still valid. `null` when no capture was
  /// requested (or the capture itself returned null).
  final Object? captured;

  /// Creates a result snapshot of one completed operation.
  const Smb2OpResult(this.status, this.data, this.captured);
}

/// Mutable slot the native completion callback writes into.
class _OpSlot {
  final int id;
  final Object? Function(int status, Pointer<Void> data)? capture;
  bool finished = false;
  int status = 0;
  Pointer<Void> data = nullptr;
  Object? captured;
  _OpSlot(this.id, this.capture);
}

/// Native signature of libsmb2's completion callback.
typedef _CbNative = Void Function(
  Pointer<smb2_context> smb2,
  Int status,
  Pointer<Void> commandData,
  Pointer<Void> cbData,
);

/// Drives libsmb2 async operations to completion with a Dart-owned
/// poll loop. One instance per [LibSmb2Bindings] holder (per isolate);
/// operations are strictly sequential.
class Smb2EventPump {
  final LibSmb2Bindings _native;
  final _Poller _poller;

  NativeCallable<_CbNative>? _callable;
  _OpSlot? _active;
  int _opSeq = 0;

  /// Creates a pump over [LibSmb2Bindings] with the host platform's poller.
  Smb2EventPump(this._native) : _poller = _Poller.forPlatform();

  /// The persistent native callback. Created lazily, recreated after
  /// [dispose]. Keeping ONE callable per pump (instead of one per
  /// operation) means a completion that arrives late — e.g. delivered by
  /// `smb2_destroy_context` after an operation was abandoned on timeout —
  /// never dereferences a freed function pointer; the op-id check below
  /// just ignores it.
  smb2_command_cb get _cb {
    final existing = _callable;
    if (existing != null) return existing.nativeFunction;
    final created = NativeCallable<_CbNative>.isolateLocal(_onComplete);
    created.keepIsolateAlive = false;
    _callable = created;
    return created.nativeFunction;
  }

  void _onComplete(
    Pointer<smb2_context> smb2,
    int status,
    Pointer<Void> commandData,
    Pointer<Void> cbData,
  ) {
    final slot = _active;
    // cbData carries the op id — a completion for an operation that was
    // abandoned (deadline breach) must not touch the current slot.
    if (slot == null || slot.id != cbData.address) return;
    slot.finished = true;
    slot.status = status;
    slot.data = commandData;
    final capture = slot.capture;
    if (capture != null) {
      // Runs while commandData is still valid — some operations
      // (readlink) free it the moment this callback returns.
      slot.captured = capture(status, commandData);
    }
  }

  /// Release the native callable. Safe to call repeatedly; the pump
  /// recreates the callable if used again. Only call when no operation
  /// can still be pending on any live context (i.e. after the context
  /// has been destroyed).
  void dispose() {
    _callable?.close();
    _callable = null;
    _active = null;
  }

  /// Start one async operation via [start] and pump the context's socket
  /// until the completion callback fires.
  ///
  /// [start] receives the native callback + cb_data to pass to the
  /// `*_async` function and must return that function's return code.
  ///
  /// [timeoutSeconds] mirrors `smb2_set_timeout`: PDU-level timeouts are
  /// raised by `smb2_service` itself (invoked at least once a second);
  /// the outer deadline here additionally covers the TCP-connect phase
  /// where no PDU exists yet. `0` disables both (waits forever).
  ///
  /// Throws [Smb2Exception] if the operation could not be started or the
  /// transport failed; completion status (including negative statuses) is
  /// returned to the caller for operation-specific handling.
  Smb2OpResult run(
    Pointer<smb2_context> ctx, {
    required String opName,
    required int Function(smb2_command_cb cb, Pointer<Void> cbData) start,
    int timeoutSeconds = 0,
    Object? Function(int status, Pointer<Void> data)? capture,
  }) {
    final slot = _OpSlot(++_opSeq, capture);
    _active = slot;
    try {
      final rc = start(_cb, Pointer<Void>.fromAddress(slot.id));
      if (rc < 0) {
        throw _error(ctx, opName, errno: -rc);
      }

      // Outer deadline with a small grace period: when both fire, prefer
      // libsmb2's own PDU timeout (surfaced as a normal -ETIMEDOUT
      // completion) over the fallback below, which has to abandon the op.
      final deadline = timeoutSeconds > 0
          ? DateTime.now().add(Duration(seconds: timeoutSeconds + 2))
          : null;

      while (!slot.finished) {
        final fd = _native.smb2_get_fd(ctx);
        final events = _native.smb2_which_events(ctx);

        // 1000 ms cap so smb2_service runs at least once a second — that
        // is what drives libsmb2's PDU timeout processing (see the
        // smb2_set_timeout docs).
        final revents = _poller.poll(fd, events, 1000);

        // smb2_service also processes PDU timeouts, so call it on idle
        // wakeups too (revents == 0 is explicitly safe upstream).
        final rcService = _native.smb2_service(ctx, revents);
        if (slot.finished) break;
        if (rcService < 0) {
          throw _error(ctx, opName);
        }

        if (deadline != null && DateTime.now().isAfter(deadline)) {
          throw Smb2Exception(
            '$opName: timed out after ${timeoutSeconds}s',
            _etimedout,
            Smb2ErrorType.timeout,
          );
        }
      }
      return Smb2OpResult(slot.status, slot.data, slot.captured);
    } finally {
      _active = null;
    }
  }

  /// Build a typed exception from the context's current error message.
  ///
  /// With the async API the freshest signal is [errno] (from a callback
  /// status or an `*_async` return code) — classify on it first and use
  /// the message only as a fallback, because `smb2_get_error` is not
  /// reset between operations and may carry stale text.
  Smb2Exception _error(
    Pointer<smb2_context> ctx,
    String prefix, {
    int errno = 0,
  }) {
    final ptr = _native.smb2_get_error(ctx);
    final msg =
        ptr == nullptr ? 'Unknown error' : ptr.cast<Utf8>().toDartString();
    final type = errno != 0
        ? Smb2ErrorType.fromErrno(errno)
        : Smb2ErrorType.fromMessage(msg);
    return Smb2Exception(
      '$prefix: $msg',
      errno,
      type == Smb2ErrorType.unknown && errno == 0
          ? Smb2ErrorType.connection // transport failed with no errno signal
          : type,
    );
  }
}

/// ETIMEDOUT for the host platform (110 Linux/Android, 60 Darwin,
/// 138 Windows CRT) — used for the pump's own fallback deadline.
final int _etimedout = Platform.isWindows
    ? 138
    : (Platform.isMacOS || Platform.isIOS)
        ? 60
        : 110;

// ─── poll() abstraction ─────────────────────────────────────────────────────

/// One-entry poll wrapper. POSIX uses libc `poll` (retrying on EINTR);
/// Windows uses `WSAPoll` from ws2_32.dll.
///
/// `events`/`revents` are passed through verbatim between
/// `smb2_which_events` → poll → `smb2_service`: libsmb2 and the host's
/// poll implementation are compiled against the same platform constants,
/// so no translation is required.
abstract class _Poller {
  /// Polls [fd] for [events] for at most [timeoutMs].
  ///
  /// Returns the raised `revents` (0 on timeout). Throws [Smb2Exception]
  /// on unrecoverable poll failure.
  int poll(int fd, int events, int timeoutMs);

  factory _Poller.forPlatform() =>
      Platform.isWindows ? _WsaPoller() : _PosixPoller();
}

// POSIX ----------------------------------------------------------------------

final class _PollFdPosix extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

typedef _PosixPollNative = Int32 Function(
  Pointer<_PollFdPosix> fds,
  UnsignedLong nfds,
  Int32 timeout,
);
typedef _PosixPollDart = int Function(
  Pointer<_PollFdPosix> fds,
  int nfds,
  int timeout,
);

/// EINTR is 4 on every supported POSIX platform (Linux, Android/bionic,
/// macOS, iOS).
const int _eintr = 4;

class _PosixPoller implements _Poller {
  static final _PosixPollDart _poll = DynamicLibrary.process()
      .lookupFunction<_PosixPollNative, _PosixPollDart>('poll');

  /// `errno` accessor — the symbol name differs per libc:
  /// `__error` (Darwin), `__errno_location` (glibc), `__errno` (bionic).
  static final Pointer<Int32> Function() _errnoLocation = () {
    final process = DynamicLibrary.process();
    for (final name in ['__error', '__errno_location', '__errno']) {
      if (process.providesSymbol(name)) {
        return process.lookupFunction<Pointer<Int32> Function(),
            Pointer<Int32> Function()>(name);
      }
    }
    throw UnsupportedError('dart_smb2: no errno symbol found in this libc');
  }();

  // The client is synchronous and isolate-local, so a single reusable
  // pollfd allocation per poller is safe.
  final Pointer<_PollFdPosix> _pfd = calloc<_PollFdPosix>();

  @override
  int poll(int fd, int events, int timeoutMs) {
    while (true) {
      _pfd.ref
        ..fd = fd
        ..events = events
        ..revents = 0;
      final rc = _poll(_pfd, 1, timeoutMs);
      if (rc >= 0) return _pfd.ref.revents;
      final errno = _errnoLocation().value;
      if (errno == _eintr) {
        // Interrupted by a signal (Dart/ART VM safepoints do this
        // routinely) — retry. The pump's outer deadline still bounds the
        // total wait.
        continue;
      }
      throw Smb2Exception(
        'Poll failed (errno $errno)',
        errno,
        Smb2ErrorType.connection,
      );
    }
  }
}

// Windows ---------------------------------------------------------------------

final class _WsaPollFd extends Struct {
  /// SOCKET. Windows guarantees kernel handles use only the low 32 bits
  /// ("Interprocess Communication Between 32-bit and 64-bit Applications"),
  /// so zero-extending the 32-bit value from `smb2_get_fd` is lossless.
  @UintPtr()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

typedef _WsaPollNative = Int32 Function(
  Pointer<_WsaPollFd> fds,
  Uint32 nfds,
  Int32 timeout,
);
typedef _WsaPollDart = int Function(
  Pointer<_WsaPollFd> fds,
  int nfds,
  int timeout,
);

class _WsaPoller implements _Poller {
  static final _WsaPollDart _wsaPoll = DynamicLibrary.open('ws2_32.dll')
      .lookupFunction<_WsaPollNative, _WsaPollDart>('WSAPoll');

  final Pointer<_WsaPollFd> _pfd = calloc<_WsaPollFd>();

  @override
  int poll(int fd, int events, int timeoutMs) {
    if (fd < 0) {
      // INVALID_SOCKET (or no socket yet). POSIX poll ignores negative
      // fds; WSAPoll errors on them — emulate the POSIX behaviour with a
      // plain sleep so the pump's service/deadline logic still runs.
      sleep(Duration(milliseconds: timeoutMs));
      return 0;
    }
    _pfd.ref
      ..fd = fd.toUnsigned(32)
      ..events = events
      ..revents = 0;
    final rc = _wsaPoll(_pfd, 1, timeoutMs);
    if (rc >= 0) return _pfd.ref.revents;
    throw const Smb2Exception(
      'WSAPoll failed',
      0,
      Smb2ErrorType.connection,
    );
  }
}
