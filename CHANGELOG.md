## [Unreleased]

### Added
- `Smb2Pool.listSharesOn` and `Smb2Client.listShares` now accept `seal`/`signing` parameters, mirroring `connect`/`Smb2Pool.connect`. Share enumeration against a security-hardened server can now require SMB3 encryption and/or packet signing, matching the guarantees already available for `connect`.

## [0.2.0] - 02-07-2026

### Changed
- **Runs against unmodified upstream libsmb2.** All behavior that previously required patched libsmb2 binaries now lives in the Dart layer, resolving the LGPL concern of shipping modified binaries without published patches:
  - Replaced libsmb2's sync wrappers (`sync.c`) with a Dart-side event pump (`smb2_*_async` + `poll`/`smb2_service` loop). The pump retries `poll()` on `EINTR` itself — the former `sync.c` patch.
  - Error classification now consumes the async completion status (a fresh `-errno`) directly instead of the patched `smb2_set_nterror` plumbing. Classification prefers the errno and falls back to the message.
  - Share enumeration uses the upstream `smb2_share_enum_async` API instead of the custom `smb2_share_enum_sync` addition.
- Upstream libsmb2 `6.1.0` is vendored as a git submodule (`third_party/libsmb2`, tag `libsmb2-6.1`) — the pinned hash is the upstream hash, no patches. ffigen and all native builds consume it.
- Windows errno values (MSVC CRT) are now classified correctly (`ETIMEDOUT`=138, `ECONNREFUSED`=107, …).
- Kerberos/GSSAPI is disabled in the native builds (build configuration); authentication is NTLMSSP as before.

### Build
- New `tool/native/` scripts build every platform binary from the pristine submodule sources (macOS/iOS xcframeworks, Android 3 ABIs, Linux x86_64/aarch64, Windows x64/arm64 via MSVC).
- New `native-release` GitHub workflow: pushing a `libsmb2-r<N>` tag builds all platforms and publishes a GitHub Release with a `SHA256SUMS` manifest. `tool/update_native_checksums.dart` rewrites the pinned checksums in the platform build files from that manifest.
- New `ci` GitHub workflow: analyze + format, unit tests on Linux/macOS/Windows, the full Samba integration suite on Linux against a vanilla libsmb2 built from the submodule, an ffigen smoke test on macOS, and example-app builds for android/ios/macos/linux/windows.

## [0.1.0] - 28-05-2026

### Changed
- General refactor of the code.
- Rewrote the FFI layer with ffigen and simplified the internals; temporary native memory is now freed automatically.
- `Smb2Client.open()` no longer takes a path; the native library already loads automatically.

### Removed
- `CachedSmb2Pool` and built-in caching. The pool no longer caches `stat` / `listDirectory` — cache at your own layer if you need to.

### Fixed
- `listDirectory` and `listShares` now work correctly on 32-bit Android.
- `readlink` handles long symlink targets correctly.
- File paths containing NUL characters are rejected instead of being silently cut short.
- Pool operations no longer hang if a worker dies mid-request — they fail fast and reconnect.
- Interrupted downloads now raise an error instead of finishing short and silent.
- Several handle and reconnect edge cases under heavy concurrency are handled cleanly.

## [0.0.8] - 25-05-2026

### Fixed
- General minor fixes.

## [0.0.7] - 25-05-2026

### Docs
- Branding realignment with the rest of the libraries.

### Build
- Improvements to Swift Package Manager on both iOS and macOS.
- iOS and macOS now ship a dynamic xcframework.
- Bumped minimum deployment targets to iOS `15.0` and macOS `12.0`.
- Added Android `armeabi-v7a` (32-bit ARM), Linux `aarch64` and Windows `arm64` binaries.
- Updated libs to `libsmb2-r5` across all platforms.

## [0.0.6] - 24-04-2026

### Added
- `Smb2Pool.withFile(path, body, {knownSize})` and scoped `Smb2File` — opens a read handle, runs the callback, guarantees `closeHandle` on any exit (exception, early return, cancellation). Replaces the `openFileWithSize` + `readFromHandle` + `closeHandle` boilerplate at every call site.
- `Smb2Pool.downloadToFile(path, File destFile, {chunkSize, onProgress, isCanceled})` — one-call download of an SMB file to a local `File` streaming through a single persistent handle.
- `onProgress(received, total)` and `isCanceled()` callbacks to `Smb2Pool.streamFile`. Cancellation throws `Smb2Exception`; the handle is always closed.
- `Finalizer` on `Smb2PoolHandle` that best-effort-closes handles leaked by the caller. Safety net only — prefer explicit `closeHandle` or `withFile` for deterministic cleanup.

### Fixed
- `streamFile` was implemented on top of `readFileRange`, which does `open + pread + close` per chunk — a 50 MiB read in 1 MiB chunks meant 50 SMB2 Create/Close pairs on the wire. It now uses a single persistent handle (1 Create + N Reads + 1 Close) and chunks at libsmb2's server-negotiated `MaxReadSize`.
- `Smb2Pool.fsyncHandle` and `ftruncateHandle` now go through the auto-reconnect path. A disconnect mid-operation previously surfaced a raw worker-send failure instead of a clean reconnect + retry.
- `closeHandle` is idempotent; calling it twice on the same handle is a no-op (previously it would fail with "Invalid handle" on the second call).

### Removed
- `Smb2Isolate`. It duplicated `Smb2Pool(workers: 1)` with a divergent error format and no auto-reconnect. Use `Smb2Pool.connect(..., workers: 1)` instead.

### Docs
- Rewrote the README around `Smb2Pool` as the default entry point. New sections: Scoped File Access (`withFile`), Download to File, Low-Level File Handles.

### Example
- New demo cards in the example app for `withFile`, `downloadToFile`, `openFileWithSize`, `fsyncHandle`, and an Error Classification card that exercises `stat` / `exists` / `deleteFile` on missing paths and reports the resolved `Smb2ErrorType`. Wired `onProgress` into the `streamFile` card.

### Build
- Patched libsmb2's completion callbacks (`create_cb_1`, `fstat_cb_1`, `getinfo_cb_3`, `trunc_cb_3`, `rename_cb_3`, `ftrunc_cb_1`) to populate the NT error on the context via `smb2_set_nterror`. Previously `stat`/`exists`/`mkdir`/`rmdir`/`deleteFile`/`rename`/`truncate`/`ftruncate` silently surfaced as `Smb2ErrorType.unknown` with `errno=0` and an empty message on any failure — so `exists()` could not detect `fileNotFound` and `mkdir()` could not detect `alreadyExists`.
- Updated binaries to `libsmb2-r4`.


## [0.0.5] - 12-04-2026

### Fixed
- Incorrect lib version in `.podspec`.


## [0.0.4] - 12-04-2026

### Fixed
- Linux `libsmb2.so` was built as ARM64 (Docker default on Apple Silicon) and failed to load on x86_64 hosts; build now forces `--platform=linux/amd64`.
- Windows `libsmb2.dll` had unbundled MinGW runtime dependencies (`libgcc_s_seh-1.dll`, `libwinpthread-1.dll`); now statically linked with `-static -static-libgcc`.
- `Smb2Exception: Poll failed` on Android and Linux during connect — patched libsmb2 `sync.c` to retry `poll()` on `EINTR` (signals from ART/Dart VM were aborting the syscall).

### Build
- Updated binaries to `libsmb2-r3`.


## [0.0.3] - 12-04-2026

### Fixed
- Transport failures (`POLLHUP`, `POLLERR`, socket read/write errors, connect failures, lost tree-id after server-side idle teardown, …) now classify as `Smb2ErrorType.connection` instead of `unknown`.


## [0.0.2] - 09-04-2026

### Added
- Write operations, write handles, file management (`mkdir`, `rmdir`, `deleteFile`, `rename`, `truncate`), filesystem info (`statvfs`, `readlink`, `echo`, `fsync`, `ftruncate`, `exists`), security options (`seal`, `signing`, `version`), `Smb2Version` enum, `Smb2StatVfs` type.

### Fixed
- libsmb2 thread safety mutex, zero-copy isolate transfers, `Smb2Isolate.disconnect()` graceful shutdown, `streamWrite` no retry on failure, unified error encoding, write loop infinite hang, `fileSize()` now throws, `truncate()` negative length validation, allocator consistency, `listdir` capacity overflow, `TransferableTypedData` fresh per retry.

### Example
- Flutter app with server management, 12 read demo cards, 10 write demo cards.

### Build
- Updated binaries to `libsmb2-r2`.


## [0.0.1+2] - 08-04-2026

### Fixed
- AndroidManifest.xml.


## [0.0.1+1] - 08-04-2026

### Fixed
- Minor fixes.


## [0.0.1] - 07-04-2026

### Added
- Initial release.
