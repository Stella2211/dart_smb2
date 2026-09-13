import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'libsmb2_bindings.dart';

/// Native signature of `smb2_init_context`.
typedef Smb2InitNative = ffi.Pointer<smb2_context> Function();
typedef _DestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
final Map<int, ffi.NativeFinalizer> _ownerFinalizers = {};

typedef _CommandNative =
    ffi.Void Function(
      ffi.Pointer<smb2_context>,
      ffi.Int,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );

/// Bindings for the native owner and completion-slot helper.
///
/// libsmb2 may invoke command callbacks while a context is being destroyed.
/// Keeping those callbacks entirely in C makes finalizer-driven destruction
/// safe even when the owning Dart isolate is already unwinding.
class NativeLifecycle {
  /// Loads and validates the lifecycle helper ABI from [library].
  NativeLifecycle(ffi.DynamicLibrary library)
    : _abi = library.lookupFunction<ffi.Int32 Function(), int Function()>(
        'dsmb_lifecycle_abi_version',
      ),
      _ownerInit = library
          .lookupFunction<
            ffi.Pointer<ffi.Void> Function(
              ffi.Pointer<ffi.NativeFunction<Smb2InitNative>>,
              ffi.Pointer<ffi.NativeFunction<_DestroyNative>>,
            ),
            ffi.Pointer<ffi.Void> Function(
              ffi.Pointer<ffi.NativeFunction<Smb2InitNative>>,
              ffi.Pointer<ffi.NativeFunction<_DestroyNative>>,
            )
          >('dsmb_owner_init'),
      _ownerContext = library
          .lookupFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
          >('dsmb_owner_context'),
      _ownerDestroy = library
          .lookupFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>),
            void Function(ffi.Pointer<ffi.Void>)
          >('dsmb_owner_destroy'),
      _ownerDestroyPointer = library.lookup<ffi.NativeFunction<_DestroyNative>>(
        'dsmb_owner_destroy',
      ),
      _slotCreate = library
          .lookupFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Int32),
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int)
          >('dsmb_slot_create'),
      _slotCallback = library
          .lookupFunction<
            ffi.Pointer<ffi.NativeFunction<_CommandNative>> Function(),
            ffi.Pointer<ffi.NativeFunction<_CommandNative>> Function()
          >('dsmb_slot_callback'),
      _slotDone = library
          .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<ffi.Void>),
            int Function(ffi.Pointer<ffi.Void>)
          >('dsmb_slot_done'),
      _slotStatus = library
          .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<ffi.Void>),
            int Function(ffi.Pointer<ffi.Void>)
          >('dsmb_slot_status'),
      _slotData = library
          .lookupFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
          >('dsmb_slot_data'),
      _slotCString = library
          .lookupFunction<
            ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>),
            ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>)
          >('dsmb_slot_cstring'),
      _slotFree = library
          .lookupFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>),
            void Function(ffi.Pointer<ffi.Void>)
          >('dsmb_slot_free') {
    if (_abi() != 1) {
      throw StateError('Unsupported dart_smb2 lifecycle helper ABI');
    }
    _finalizer = _ownerFinalizers.putIfAbsent(
      _ownerDestroyPointer.address,
      () => ffi.NativeFinalizer(_ownerDestroyPointer),
    );
  }

  final int Function() _abi;
  final ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.NativeFunction<Smb2InitNative>>,
    ffi.Pointer<ffi.NativeFunction<_DestroyNative>>,
  )
  _ownerInit;
  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>) _ownerContext;
  final void Function(ffi.Pointer<ffi.Void>) _ownerDestroy;
  final ffi.Pointer<ffi.NativeFunction<_DestroyNative>> _ownerDestroyPointer;
  late final ffi.NativeFinalizer _finalizer;
  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int) _slotCreate;
  final ffi.Pointer<ffi.NativeFunction<_CommandNative>> Function()
  _slotCallback;
  final int Function(ffi.Pointer<ffi.Void>) _slotDone;
  final int Function(ffi.Pointer<ffi.Void>) _slotStatus;
  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>) _slotData;
  final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>) _slotCString;
  final void Function(ffi.Pointer<ffi.Void>) _slotFree;

  /// Initializes a context under the process-wide native lifecycle lock.
  NativeSmb2Context create(
    ffi.Pointer<ffi.NativeFunction<Smb2InitNative>> init,
    ffi.Pointer<
      ffi.NativeFunction<ffi.Void Function(ffi.Pointer<smb2_context>)>
    >
    destroy,
  ) {
    final owner = _ownerInit(init, destroy.cast());
    if (owner == ffi.nullptr) {
      throw StateError('Failed to initialize an SMB2 lifecycle owner');
    }
    final context = _ownerContext(owner).cast<smb2_context>();
    if (context == ffi.nullptr) {
      _ownerDestroy(owner);
      throw StateError('Lifecycle owner returned a null SMB2 context');
    }
    return NativeSmb2Context._(this, context, owner);
  }

  /// Allocates a completion slot owned by [context].
  ffi.Pointer<ffi.Void> slotCreate(
    NativeSmb2Context context, {
    bool copyCString = false,
  }) => _slotCreate(context.owner, copyCString ? 1 : 0);

  /// The native C completion callback shared by every slot.
  smb2_command_cb get slotCallback => _slotCallback();

  /// Whether the native callback has completed [slot].
  bool slotDone(ffi.Pointer<ffi.Void> slot) => _slotDone(slot) != 0;

  /// Returns the completion status stored in [slot].
  int slotStatus(ffi.Pointer<ffi.Void> slot) => _slotStatus(slot);

  /// Returns the command data pointer stored in [slot].
  ffi.Pointer<ffi.Void> slotData(ffi.Pointer<ffi.Void> slot) => _slotData(slot);

  /// Reads the optional C-owned string copy from [slot].
  String? slotCString(ffi.Pointer<ffi.Void> slot) {
    final value = _slotCString(slot);
    return value == ffi.nullptr ? null : value.cast<Utf8>().toDartString();
  }

  /// Releases a completed slot.
  void slotFree(ffi.Pointer<ffi.Void> slot) => _slotFree(slot);
}

/// A libsmb2 context whose context, callbacks, and completion slots share one
/// native lifetime.
class NativeSmb2Context implements ffi.Finalizable {
  NativeSmb2Context._(this._lifecycle, this._pointer, this._owner) {
    _lifecycle._finalizer.attach(this, _owner, detach: _detachKey);
  }

  final NativeLifecycle _lifecycle;
  final Object _detachKey = Object();
  ffi.Pointer<smb2_context> _pointer;
  ffi.Pointer<ffi.Void> _owner;

  /// Whether the native owner still holds a live libsmb2 context.
  bool get isAlive => _owner != ffi.nullptr;

  /// The context pointer, or nullptr after [abort].
  ffi.Pointer<smb2_context> get pointer =>
      isAlive ? _pointer : ffi.nullptr.cast<smb2_context>();

  /// The native owner token used when allocating completion slots.
  ffi.Pointer<ffi.Void> get owner {
    if (!isAlive) {
      throw StateError('The SMB2 context has already been destroyed');
    }
    return _owner;
  }

  /// Destroys the context locally without waiting for a server response.
  /// Pending C completion slots are released by the same owner teardown.
  void abort() {
    final owner = _owner;
    if (owner == ffi.nullptr) return;

    _owner = ffi.nullptr;
    _pointer = ffi.nullptr.cast<smb2_context>();
    _lifecycle._finalizer.detach(_detachKey);
    _lifecycle._ownerDestroy(owner);
  }
}

/// Opens the lifecycle helper produced by the Flutter plugin build.
ffi.DynamicLibrary openLifecycleLibrary() {
  final override = Platform.environment['DART_SMB2_LIFECYCLE_LIBRARY'];
  if (override != null && override.isNotEmpty) {
    return ffi.DynamicLibrary.open(override);
  }

  if (Platform.isMacOS) {
    final process = ffi.DynamicLibrary.process();
    if (process.providesSymbol('dsmb_lifecycle_abi_version')) return process;
    return ffi.DynamicLibrary.open('dart_smb2.framework/dart_smb2');
  }
  if (Platform.isIOS) return ffi.DynamicLibrary.process();
  if (Platform.isWindows) {
    return ffi.DynamicLibrary.open('dart_smb2_lifecycle.dll');
  }
  if (Platform.isLinux || Platform.isAndroid) {
    return ffi.DynamicLibrary.open('libdart_smb2_lifecycle.so');
  }
  throw UnsupportedError(
    'dart_smb2 lifecycle: unsupported platform ${Platform.operatingSystem}',
  );
}
