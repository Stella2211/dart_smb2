// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Callback-free event pump for libsmb2's asynchronous API.
///
/// Completion callbacks write into native C slots. Dart only polls those
/// slots after [smb2_service] returns, so context destruction never enters
/// the Dart VM through a native callback.
library;

import 'dart:ffi';
import 'dart:io' show Platform, sleep;

import 'package:ffi/ffi.dart';

import '../smb2_error_type.dart';
import '../smb2_exceptions.dart';
import 'libsmb2_bindings.dart';
import 'native_lifecycle.dart';

/// Result of one completed async libsmb2 operation.
class Smb2OpResult {
  /// The completion status. Non-negative values indicate success.
  final int status;

  /// The operation-specific command data pointer.
  final Pointer<Void> data;

  /// A copied callback-transient C string, when requested by the operation.
  final String? captured;

  /// Creates a snapshot from a completed native slot.
  const Smb2OpResult(this.status, this.data, this.captured);
}

/// Drives one context's sequential asynchronous operations to completion.
class Smb2EventPump {
  /// Creates a pump backed by [lifecycle] completion slots.
  Smb2EventPump(this._native, this._lifecycle)
    : _poller = _Poller.forPlatform();

  final LibSmb2Bindings _native;
  final NativeLifecycle _lifecycle;
  final _Poller _poller;

  /// Starts one operation and services its socket until the native slot is
  /// complete. If a started operation must be abandoned, this method destroys
  /// the whole context before unwinding so every pointer passed to libsmb2
  /// remains valid until its callback has been cancelled or delivered.
  Smb2OpResult run(
    NativeSmb2Context context, {
    required String opName,
    required int Function(smb2_command_cb cb, Pointer<Void> cbData) start,
    int timeoutSeconds = 0,
    bool copyCString = false,
  }) {
    final ctx = context.pointer;
    if (ctx == nullptr) {
      throw const Smb2Exception('SMB2 context has already been destroyed');
    }

    final slot = _lifecycle.slotCreate(context, copyCString: copyCString);
    if (slot == nullptr) {
      throw Smb2Exception(
        '$opName: failed to allocate completion state',
        _enomem,
        Smb2ErrorType.fromErrno(_enomem),
      );
    }

    var accepted = false;
    var slotDestroyedWithContext = false;
    try {
      final rc = start(_lifecycle.slotCallback, slot);
      if (rc < 0) {
        throw _error(ctx, opName, errno: -rc);
      }
      accepted = true;

      _serviceUntilDone(ctx, slot, opName, timeoutSeconds);

      return Smb2OpResult(
        _lifecycle.slotStatus(slot),
        _lifecycle.slotData(slot),
        copyCString ? _lifecycle.slotCString(slot) : null,
      );
    } catch (_) {
      if (accepted && !_lifecycle.slotDone(slot)) {
        // owner_destroy invokes libsmb2's pending callbacks entirely in C and
        // releases their slots. Do this before an Arena or I/O buffer in the
        // caller can leave scope.
        slotDestroyedWithContext = true;
        context.abort();
      }
      rethrow;
    } finally {
      if (!slotDestroyedWithContext) {
        _lifecycle.slotFree(slot);
      }
    }
  }

  /// Starts a batch of operations that may be in flight concurrently on
  /// [context] — see [Smb2OpBatch].
  Smb2OpBatch batch(NativeSmb2Context context, {int timeoutSeconds = 0}) =>
      Smb2OpBatch._(this, context, timeoutSeconds);

  /// Polls and services [ctx] until [slot] completes. Other slots on the
  /// same context complete as a side effect when their replies arrive.
  void _serviceUntilDone(
    Pointer<smb2_context> ctx,
    Pointer<Void> slot,
    String opName,
    int timeoutSeconds,
  ) {
    final deadline = timeoutSeconds > 0
        ? DateTime.now().add(Duration(seconds: timeoutSeconds + 2))
        : null;

    while (!_lifecycle.slotDone(slot)) {
      final fd = _native.smb2_get_fd(ctx);
      final events = _native.smb2_which_events(ctx);
      final revents = _poller.poll(fd, events, 1000);

      final serviceResult = _native.smb2_service(ctx, revents);
      if (_lifecycle.slotDone(slot)) break;
      if (serviceResult < 0) {
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
  }

  Smb2Exception _error(
    Pointer<smb2_context> ctx,
    String prefix, {
    int errno = 0,
  }) {
    final ptr = _native.smb2_get_error(ctx);
    final msg = ptr == nullptr
        ? 'Unknown error'
        : ptr.cast<Utf8>().toDartString();
    final type = errno != 0
        ? Smb2ErrorType.fromErrno(errno)
        : Smb2ErrorType.fromMessage(msg);
    return Smb2Exception(
      '$prefix: $msg',
      errno,
      type == Smb2ErrorType.unknown && errno == 0
          ? Smb2ErrorType.connection
          : type,
    );
  }
}

/// A set of operations that are in flight **concurrently** on one context.
///
/// [Smb2EventPump.run] issues one request and waits for its reply before
/// the next one can start, which caps throughput at one request per round
/// trip. A batch lets the caller [start] several requests (e.g. a window of
/// pread/pwrite chunks) and then [wait] for them one by one; every
/// `smb2_service` call completes whichever replies have arrived.
///
/// Lifetime rules — every buffer handed to a started operation must stay
/// valid until one of these happens:
///   * [wait] returned for that slot (the slot is released), or
///   * [cancel] returned (all remaining slots drained or the context
///     destroyed), or
///   * any method threw: a pump failure destroys the whole context before
///     unwinding, exactly like [Smb2EventPump.run], so no pending callback
///     can touch caller memory afterwards.
class Smb2OpBatch {
  Smb2OpBatch._(this._pump, this._context, this._timeoutSeconds);

  final Smb2EventPump _pump;
  final NativeSmb2Context _context;
  final int _timeoutSeconds;

  /// Slots started but not yet released, in start order.
  final List<Pointer<Void>> _pending = [];

  /// Number of operations started and not yet released.
  int get length => _pending.length;

  /// Starts one operation without waiting for it. Returns its slot token
  /// for [wait]. Throws (and releases the slot) if libsmb2 rejects it.
  Pointer<Void> start(
    String opName,
    int Function(smb2_command_cb cb, Pointer<Void> cbData) start,
  ) {
    final ctx = _liveContext(opName);
    final lifecycle = _pump._lifecycle;
    final slot = lifecycle.slotCreate(_context);
    if (slot == nullptr) {
      throw Smb2Exception(
        '$opName: failed to allocate completion state',
        _enomem,
        Smb2ErrorType.fromErrno(_enomem),
      );
    }
    try {
      final rc = start(lifecycle.slotCallback, slot);
      if (rc < 0) throw _pump._error(ctx, opName, errno: -rc);
    } catch (_) {
      lifecycle.slotFree(slot);
      rethrow;
    }
    _pending.add(slot);
    return slot;
  }

  /// Services the context until [slot] completes, releases it and returns
  /// its completion status (negative errno on failure).
  int wait(Pointer<Void> slot, String opName) {
    final ctx = _liveContext(opName);
    final lifecycle = _pump._lifecycle;
    try {
      _pump._serviceUntilDone(ctx, slot, opName, _timeoutSeconds);
    } catch (_) {
      _destroy();
      rethrow;
    }
    final status = lifecycle.slotStatus(slot);
    _pending.remove(slot);
    lifecycle.slotFree(slot);
    return status;
  }

  /// Waits for every still-pending operation and discards the results, so
  /// their buffers can be reused or freed. Never throws: if the context
  /// cannot be serviced it is destroyed instead, which has the same effect
  /// on buffer ownership. Intended for error paths.
  void cancel() {
    while (_pending.isNotEmpty) {
      if (!_context.isAlive) {
        _pending.clear();
        return;
      }
      try {
        wait(_pending.first, 'Cancel');
      } on Object {
        // wait() destroyed the context; nothing is pending any more.
        _destroy();
        return;
      }
    }
  }

  /// The live context pointer. If another operation already destroyed the
  /// context, owner teardown freed our slots with it — forget them.
  Pointer<smb2_context> _liveContext(String opName) {
    final ctx = _context.pointer;
    if (ctx == nullptr) {
      _pending.clear();
      throw Smb2Exception(
        '$opName: SMB2 context has been destroyed',
        null,
        Smb2ErrorType.connection,
      );
    }
    return ctx;
  }

  /// Destroys the context when any started operation is still pending —
  /// owner teardown cancels them in C and releases their slots.
  void _destroy() {
    final lifecycle = _pump._lifecycle;
    if (_pending.any((slot) => !lifecycle.slotDone(slot))) {
      _pending.clear();
      _context.abort();
    } else {
      for (final slot in _pending) {
        lifecycle.slotFree(slot);
      }
      _pending.clear();
    }
  }
}

/// ENOMEM has value 12 on every supported target's C runtime.
const int _enomem = 12;

/// ETIMEDOUT for the host platform.
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
///
/// Each poller owns one `calloc`'d pollfd for its whole lifetime (the pump
/// is reused by every operation of a client). Pollers are [Finalizable]:
/// the struct is released by a native finalizer once the owning pump is
/// unreachable — the client has no explicit dispose, so a GC-driven
/// release is the only path that cannot leak.
abstract class _Poller implements Finalizable {
  /// Polls [fd] for [events] for at most [timeoutMs].
  ///
  /// Returns the raised `revents` (0 on timeout). Throws [Smb2Exception]
  /// on unrecoverable poll failure.
  int poll(int fd, int events, int timeoutMs);

  factory _Poller.forPlatform() =>
      Platform.isWindows ? _WsaPoller() : _PosixPoller();
}

/// Frees a poller's pollfd when the poller is garbage collected.
final NativeFinalizer _pollFdFinalizer = NativeFinalizer(calloc.nativeFree);

/// Ties [pointer] (a `calloc`'d pollfd of [size] bytes) to [owner]'s
/// lifetime and returns it.
Pointer<T> _ownPollFd<T extends NativeType>(
  Finalizable owner,
  Pointer<T> pointer,
  int size,
) {
  _pollFdFinalizer.attach(owner, pointer.cast(), externalSize: size);
  return pointer;
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

typedef _PosixPollNative =
    Int32 Function(Pointer<_PollFdPosix> fds, UnsignedLong nfds, Int32 timeout);
typedef _PosixPollDart =
    int Function(Pointer<_PollFdPosix> fds, int nfds, int timeout);

/// EINTR is 4 on every supported POSIX platform (Linux, Android/bionic,
/// macOS, iOS).
const int _eintr = 4;

/// `errno` accessor — the symbol name differs per libc:
/// `__error` (Darwin), `__errno_location` (glibc), `__errno` (bionic).
///
/// Top-level on purpose: as a static of the [Finalizable] `_PosixPoller`,
/// this closure initializer crashed release (AOT) builds in type-flow
/// analysis ("Null check operator used on a null value").
final Pointer<Int32> Function() _errnoLocation = () {
  final process = DynamicLibrary.process();
  for (final name in ['__error', '__errno_location', '__errno']) {
    if (process.providesSymbol(name)) {
      return process
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            name,
          );
    }
  }
  throw UnsupportedError('dart_smb2: no errno symbol found in this libc');
}();

class _PosixPoller implements _Poller {
  static final _PosixPollDart _poll = DynamicLibrary.process()
      .lookupFunction<_PosixPollNative, _PosixPollDart>('poll');

  _PosixPoller() {
    _pfd = _ownPollFd(this, calloc<_PollFdPosix>(), sizeOf<_PollFdPosix>());
  }

  // The client is synchronous and isolate-local, so a single reusable
  // pollfd allocation per poller is safe.
  late final Pointer<_PollFdPosix> _pfd;

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

typedef _WsaPollNative =
    Int32 Function(Pointer<_WsaPollFd> fds, Uint32 nfds, Int32 timeout);
typedef _WsaPollDart =
    int Function(Pointer<_WsaPollFd> fds, int nfds, int timeout);

class _WsaPoller implements _Poller {
  static final _WsaPollDart _wsaPoll = DynamicLibrary.open(
    'ws2_32.dll',
  ).lookupFunction<_WsaPollNative, _WsaPollDart>('WSAPoll');

  _WsaPoller() {
    _pfd = _ownPollFd(this, calloc<_WsaPollFd>(), sizeOf<_WsaPollFd>());
  }

  late final Pointer<_WsaPollFd> _pfd;

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
    throw const Smb2Exception('WSAPoll failed', 0, Smb2ErrorType.connection);
  }
}
