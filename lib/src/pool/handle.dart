// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Pool-scoped file handles. [Smb2PoolHandle] binds an open file to a
/// specific worker isolate (handles can only be used on the worker that
/// opened them); [Smb2File] is the scoped wrapper [Smb2Pool.withFile]
/// hands to user code.
library;

import 'dart:async';
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
  /// The worker isolate that owns this open file. Swapped on reconnect.
  ///
  /// Assigning moves the handle's slot in the per-worker open-handle
  /// count, which keeps the pool from retiring an idle worker that still
  /// owns open files.
  Worker get worker => _worker;
  set worker(Worker value) {
    if (identical(value, _worker)) return;
    if (!closed) {
      _worker.openHandles--;
      value.openHandles++;
    }
    _worker = value;
  }

  Worker _worker;

  /// The worker-local handle id. Swapped when the handle is reopened.
  int id;

  /// Placeholder [id] while a reopen is pending (or after it failed). Worker
  /// ids are non-negative, so the worker rejects it as an invalid handle.
  static const int noId = -1;

  /// The share-relative path this handle was opened for (used to reopen).
  final String path;

  /// Whether [Smb2Pool.closeHandle] has been called for this handle.
  bool closed = false;

  /// Bind a handle to its owning [worker] / [id] and arm the GC finalizer.
  Smb2PoolHandle(Worker worker, this.id, this.path) : _worker = worker {
    worker.openHandles++;
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
    if (!closed) _worker.openHandles--;
    closed = true;
    _finalizer.detach(this);
  }

  /// Finalizer that best-effort-closes handles leaked by the caller.
  /// The callback must not reference the enclosing `Smb2PoolHandle` —
  /// only the captured worker + id are allowed (otherwise the object
  /// can never become unreachable).
  ///
  /// Fire-and-forget: no reply port is allocated since nobody awaits the
  /// outcome (the worker skips the reply when `replyTo` is null).
  static final Finalizer<HandleRef> _finalizer = Finalizer<HandleRef>((ref) {
    ref.worker.openHandles--;
    if (ref.id != noId) {
      ref.worker.post('closeHandle', {'handleId': ref.id});
    }
  });
}

/// A captured {worker, handleId} pair the finalizer can close without
/// holding a reference to the [Smb2PoolHandle] Dart object.
class HandleRef {
  /// The worker isolate that owns the handle.
  final Worker worker;

  /// The worker-local handle id to close.
  final int id;

  /// Capture the {worker, id} pair for the finalizer.
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

  /// Wrap a pool-bound [handle] for the duration of a `withFile` callback.
  Smb2File(this._pool, this._handle, this.size);

  /// Read [length] bytes at [offset]. Same semantics as
  /// [Smb2Pool.readFromHandle] — transparently reconnects on failure.
  Future<Uint8List> read({int offset = 0, required int length}) =>
      _pool.readFromHandle(_handle, offset: offset, length: length);
}
