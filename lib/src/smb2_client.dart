// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:typed_data';

import 'ffi/libsmb2_bindings.dart';
import 'ffi/native_lib.dart';
import 'native/smb2_native.dart';
import 'smb2_error_type.dart';
import 'smb2_exceptions.dart';
import 'smb2_types.dart';

/// SMB2/3 client powered by libsmb2 via Dart FFI.
///
/// All operations are **synchronous** — run this client inside a
/// [Dart Isolate](https://api.dart.dev/stable/dart-isolate/Isolate-class.html)
/// to keep the UI responsive.
///
/// ```dart
/// final client = Smb2Client.open();
/// client.connect(host: '192.168.1.1', share: 'Music', user: 'guest');
/// final entries = client.listDirectory('');
/// client.disconnect();
/// ```
class Smb2Client implements Finalizable {
  final DynamicLibrary _lib;
  final LibSmb2Bindings _native;
  Pointer<smb2_context> _ctx = nullptr;
  Smb2Native? _ops;
  late final NativeFinalizer _finalizer;

  Smb2Client._(this._lib) : _native = LibSmb2Bindings(_lib) {
    // Last-resort safety net for a leaked client: free the libsmb2
    // context if the caller forgets to call `disconnect()`. The bound
    // function is `smb2_destroy_context` (signature: void(void*)) — it
    // closes the socket and releases internal allocations, but does NOT
    // send a wire-level logoff first. Explicit `disconnect()` is still
    // preferred so the server can reclaim the session immediately.
    _finalizer = NativeFinalizer(
      _lib.lookup<NativeFunction<Void Function(Pointer)>>(
        'smb2_destroy_context',
      ),
    );
  }

  /// Create a client. The native library is resolved automatically via
  /// the Flutter plugin mechanism — no path arguments to wire up.
  factory Smb2Client.open() => Smb2Client._(openLibSmb2());

  /// Whether this client is connected to a share.
  bool get isConnected => _ctx != nullptr;

  // ─── Share enumeration ───────────────────────────────────────────────────

  /// List available shares on a server.
  ///
  /// This does **not** require an existing connection — it connects to `IPC$`
  /// internally, enumerates shares, and disconnects.
  ///
  /// Returns a list of [Smb2ShareInfo] with name and type.
  List<Smb2ShareInfo> listShares({
    required String host,
    String? user,
    String? password,
    String? domain,
    int timeoutSeconds = 30,
  }) =>
      Smb2Native.listShares(
        _native,
        host: host,
        user: user,
        password: password,
        domain: domain,
        timeoutSeconds: timeoutSeconds,
      );

  // ─── Connection ─────────────────────────────────────────────────────────

  /// Connect to an SMB share.
  ///
  /// Paths in subsequent calls are **relative to the share root**.
  /// Use `''` (empty string) to refer to the share root — not `/`.
  ///
  /// Throws [Smb2Exception] on failure.
  void connect({
    required String host,
    required String share,
    String? user,
    String? password,
    String? domain,
    int timeoutSeconds = 30,
    bool seal = false,
    bool signing = false,
    Smb2Version version = Smb2Version.any,
  }) {
    if (isConnected) disconnect();

    _ctx = Smb2Native.connect(
      _native,
      host: host,
      share: share,
      user: user,
      password: password,
      domain: domain,
      timeoutSeconds: timeoutSeconds,
      seal: seal,
      signing: signing,
      version: version,
    );
    _ops = Smb2Native(_native, _ctx);
    _finalizer.attach(this, _ctx.cast(), detach: this);
  }

  /// Disconnect from the share and release all resources.
  void disconnect() {
    if (_ctx == nullptr) return;
    _finalizer.detach(this);
    Smb2Native.disconnectContext(_native, _ctx);
    _ctx = nullptr;
    _ops = null;
  }

  /// Send a keepalive echo to the server.
  ///
  /// Returns normally if the connection is healthy.
  /// Throws [Smb2Exception] if the server is unreachable or the
  /// connection has been lost.
  void echo() {
    _ensureConnected();
    _ops!.echo();
  }

  // ─── Directory listing ──────────────────────────────────────────────────

  /// List all entries in a directory.
  ///
  /// [path] is relative to the share root. Use `''` for the root directory.
  /// Returns entries with name, type, size, and timestamps — no additional
  /// per-entry round-trips required.
  ///
  /// Throws [Smb2Exception] if the directory cannot be opened.
  List<Smb2DirEntry> listDirectory(String path) {
    _ensureConnected();
    return _ops!.listDirectory(path);
  }

  // ─── File reading ───────────────────────────────────────────────────────

  /// Read [length] bytes from a file at [offset].
  ///
  /// Ideal for reading partial content without downloading the entire file.
  ///
  /// Throws [Smb2Exception] on read failure.
  Uint8List readFileRange(String path, {int offset = 0, required int length}) {
    _ensureConnected();
    return _ops!.readFileRange(path, offset: offset, length: length);
  }

  /// Read an entire file into memory.
  ///
  /// Loads the entire file into a [Uint8List]. For large files prefer
  /// [readFileRange] to read only the bytes you need.
  ///
  /// Throws [Smb2Exception] on failure.
  Uint8List readFile(String path) {
    _ensureConnected();
    return _ops!.readFile(path);
  }

  // ─── File info ──────────────────────────────────────────────────────────

  /// Get file or directory metadata without opening the file.
  ///
  /// Uses an SMB2 compound request internally (Create + QueryInfo + Close)
  /// so it completes in a single network round-trip.
  ///
  /// Throws [Smb2Exception] on failure.
  Smb2Stat stat(String path) {
    _ensureConnected();
    return _ops!.stat(path);
  }

  /// Get the size of a file in bytes without opening it.
  ///
  /// Throws [Smb2Exception] on failure.
  int fileSize(String path) {
    _ensureConnected();
    return _ops!.fileSize(path);
  }

  /// Get filesystem statistics (total/free space, block sizes).
  ///
  /// [path] can be any path on the share — typically `''` for the share root.
  ///
  /// Throws [Smb2Exception] on failure.
  Smb2StatVfs statvfs(String path) {
    _ensureConnected();
    return _ops!.statvfs(path);
  }

  /// Read the target path of a symbolic link.
  ///
  /// Throws [Smb2Exception] on failure (e.g., path is not a symlink).
  String readlink(String path) {
    _ensureConnected();
    return _ops!.readlink(path);
  }

  /// Check whether a file or directory exists.
  ///
  /// Returns `true` if the path exists, `false` if it does not.
  /// Throws [Smb2Exception] on connection or permission errors.
  bool exists(String path) {
    _ensureConnected();
    try {
      stat(path);
      return true;
    } on Smb2Exception catch (e) {
      if (e.type == Smb2ErrorType.fileNotFound) return false;
      rethrow;
    }
  }

  // ─── File handles (open once, read many, close once) ─────────────────

  /// Open a file for reading and return a reusable handle.
  ///
  /// Use [readHandle] to read from the handle, then [closeHandle] when done.
  /// This avoids repeated open/close network round-trips when reading
  /// multiple ranges from the same file.
  ///
  /// Throws [Smb2Exception] if the file cannot be opened.
  Pointer openFileHandle(String path) {
    _ensureConnected();
    return _ops!.openFileHandle(path);
  }

  /// Open a file and get its size in one call.
  ///
  /// Saves a round-trip compared to calling [fileSize] + [openFileHandle]
  /// separately. Returns `(handle, fileSize)`.
  ///
  /// Throws [Smb2Exception] on failure.
  (Pointer handle, int size) openFileWithSize(String path) {
    _ensureConnected();
    return _ops!.openFileWithSize(path);
  }

  /// Read [length] bytes at [offset] from an open file handle.
  ///
  /// The handle must have been obtained from [openFileHandle] or [openFileWithSize].
  Uint8List readHandle(Pointer handle, {int offset = 0, required int length}) {
    _ensureConnected();
    return _ops!.readHandle(handle, offset: offset, length: length);
  }

  /// Close a file handle opened with [openFileHandle] or [openFileWithSize].
  void closeHandle(Pointer handle) {
    if (_ctx == nullptr || handle == nullptr) return;
    _ops?.closeHandle(handle);
  }

  // ─── Streaming ──────────────────────────────────────────────────────

  /// Read a file in chunks without loading everything into RAM.
  ///
  /// Yields [Uint8List] chunks of up to [chunkSize] bytes.
  /// Uses a file handle internally — opens once, reads sequentially, closes.
  Iterable<Uint8List> readFileChunked(
    String path, {
    int chunkSize = 1024 * 1024,
  }) sync* {
    final (handle, size) = openFileWithSize(path);
    try {
      int offset = 0;
      while (offset < size) {
        final toRead = (size - offset).clamp(0, chunkSize);
        yield readHandle(handle, offset: offset, length: toRead);
        offset += toRead;
      }
    } finally {
      closeHandle(handle);
    }
  }

  // ─── File writing ───────────────────────────────────────────────────────

  /// Write [data] to a file at [offset], creating it if it doesn't exist.
  ///
  /// Ideal for writing partial content or appending to a file.
  ///
  /// Throws [Smb2Exception] on write failure.
  void writeFileRange(String path, Uint8List data, {int offset = 0}) {
    _ensureConnected();
    _ops!.writeFileRange(path, data, offset: offset);
  }

  /// Write [data] to a file, creating or truncating it.
  ///
  /// Replaces the entire file content with [data].
  ///
  /// Throws [Smb2Exception] on failure.
  void writeFile(String path, Uint8List data) {
    _ensureConnected();
    _ops!.writeFile(path, data);
  }

  // ─── Write handles (open once, write many, close once) ─────────────────

  /// Open a file for writing and return a reusable handle.
  ///
  /// The file is created if it doesn't exist.
  /// Use [writeHandle] to write, then [closeHandle] when done.
  ///
  /// Throws [Smb2Exception] if the file cannot be opened.
  Pointer openFileHandleWrite(String path) {
    _ensureConnected();
    return _ops!.openFileHandleWrite(path);
  }

  /// Write [data] at [offset] to an open file handle.
  ///
  /// The handle must have been obtained from [openFileHandleWrite].
  void writeHandle(Pointer handle, Uint8List data, {int offset = 0}) {
    _ensureConnected();
    _ops!.writeHandle(handle, data, offset: offset);
  }

  /// Flush all buffered writes on a file handle to the server.
  ///
  /// Ensures all previously written data is persisted on the remote disk.
  /// The handle must have been obtained from [openFileHandleWrite].
  ///
  /// Throws [Smb2Exception] on failure.
  void fsync(Pointer handle) {
    _ensureConnected();
    _ops!.fsync(handle);
  }

  /// Truncate an open file handle to [length] bytes.
  ///
  /// [length] must be non-negative.
  /// Throws [Smb2Exception] on failure.
  void ftruncate(Pointer handle, int length) {
    _ensureConnected();
    _ops!.ftruncate(handle, length);
  }

  // ─── Streaming write ────────────────────────────────────────────────────

  /// Write data from [chunks] to a file without loading everything into RAM.
  ///
  /// Creates or truncates the file, then writes each chunk sequentially.
  /// Uses a write handle internally — opens once, writes sequentially, closes.
  void writeFileChunked(String path, Iterable<Uint8List> chunks) {
    final handle = openFileHandleWrite(path);
    try {
      ftruncate(handle, 0);
      int offset = 0;
      for (final chunk in chunks) {
        writeHandle(handle, chunk, offset: offset);
        offset += chunk.length;
      }
    } finally {
      closeHandle(handle);
    }
  }

  // ─── File/directory management ─────────────────────────────────────────

  /// Delete a file.
  ///
  /// Throws [Smb2Exception] if the file cannot be deleted.
  void deleteFile(String path) {
    _ensureConnected();
    _ops!.deleteFile(path);
  }

  /// Create a directory.
  ///
  /// Throws [Smb2Exception] if the directory cannot be created.
  void mkdir(String path) {
    _ensureConnected();
    _ops!.mkdir(path);
  }

  /// Delete an empty directory.
  ///
  /// Throws [Smb2Exception] if the directory cannot be removed.
  void rmdir(String path) {
    _ensureConnected();
    _ops!.rmdir(path);
  }

  /// Rename or move a file or directory.
  ///
  /// Throws [Smb2Exception] on failure.
  void rename(String oldPath, String newPath) {
    _ensureConnected();
    _ops!.rename(oldPath, newPath);
  }

  /// Truncate a file to [length] bytes.
  ///
  /// [length] must be non-negative.
  /// Throws [Smb2Exception] on failure.
  void truncate(String path, int length) {
    _ensureConnected();
    _ops!.truncate(path, length);
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  void _ensureConnected() {
    if (_ctx == nullptr || _ops == null) {
      throw const Smb2Exception('Not connected. Call connect() first.');
    }
  }
}
