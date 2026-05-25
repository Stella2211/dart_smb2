// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Pool-scoped file handles. [Smb2PoolHandle] binds an open file to a
/// specific worker isolate (handles can only be used on the worker that
/// opened them); [Smb2File] is the scoped wrapper [Smb2Pool.withFile]
/// hands to user code.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'pool.dart';
import 'worker.dart';

/// Opaque handle to an open file on a specific worker.
///
/// Use with [Smb2Pool.readFromHandle] and [Smb2Pool.closeHandle], or
/// prefer [Smb2Pool.withFile] / [Smb2Pool.streamFile] /
/// [Smb2Pool.downloadToFile] which manage the handle lifecycle for you.
///
/// If this object is garbage-collected without [Smb2Pool.closeHandle]
/// being called, a `closeHandle` command is sent to the worker as a
/// best-effort safety net. Rely on explicit close (or the scoped
/// helpers) for deterministic cleanup.
class Smb2PoolHandle {
  Worker worker;
  int id;
  final String path;
  bool closed = false;

  Smb2PoolHandle(this.worker, this.id, this.path) {
    _finalizer.attach(this, HandleRef(worker, id), detach: this);
  }

  /// Re-attach the finalizer after a reconnect swapped [worker] / [id].
  /// Without this, a leaked handle would send `closeHandle` to the dead
  /// original worker and miss the live handle on the reconnected one.
  void refreshFinalizer() {
    if (closed) return;
    _finalizer.detach(this);
    _finalizer.attach(this, HandleRef(worker, id), detach: this);
  }

  /// Internal cleanup hook called by [Smb2Pool.closeHandle] right before
  /// the close cmd is sent. Detaches the finalizer so we don't double-
  /// close on GC.
  void markClosed() {
    closed = true;
    _finalizer.detach(this);
  }

  /// Finalizer that best-effort-closes handles leaked by the caller.
  /// The callback must not reference the enclosing `Smb2PoolHandle` —
  /// only the captured worker + id are allowed (otherwise the object
  /// can never become unreachable).
  static final Finalizer<HandleRef> _finalizer = Finalizer<HandleRef>((ref) {
    try {
      final port = ReceivePort();
      ref.worker.sendPort.send({
        'cmd': 'closeHandle',
        'handleId': ref.id,
        'replyTo': port.sendPort,
      });
      // Drain and close the reply port so it doesn't linger; we don't
      // care about the result since the Dart object is already gone.
      port.first.then((_) => port.close(), onError: (_) => port.close());
    } catch (_) {
      // Worker may be dead; best-effort is all we can promise here.
    }
  });
}

/// A captured {worker, handleId} pair the finalizer can close without
/// holding a reference to the [Smb2PoolHandle] Dart object.
class HandleRef {
  final Worker worker;
  final int id;
  HandleRef(this.worker, this.id);
}

/// A file opened inside [Smb2Pool.withFile].
///
/// Lives only for the duration of the callback — the underlying
/// handle is closed automatically when `withFile` returns.
class Smb2File {
  final Smb2Pool _pool;
  final Smb2PoolHandle _handle;

  /// Total file size in bytes, captured at open time.
  final int size;

  Smb2File(this._pool, this._handle, this.size);

  /// Read [length] bytes at [offset]. Same semantics as
  /// [Smb2Pool.readFromHandle] — transparently reconnects on failure.
  Future<Uint8List> read({int offset = 0, required int length}) =>
      _pool.readFromHandle(_handle, offset: offset, length: length);
}
