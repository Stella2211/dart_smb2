import Flutter
import UIKit

#if SWIFT_PACKAGE
import dart_smb2_lifecycle
#endif

public class DartSmb2Plugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if SWIFT_PACKAGE
    // Retain the C target when SwiftPM links the plugin statically.
    _ = dsmb_lifecycle_abi_version()
    #endif
    // Native functionality is handled via FFI — no method channel needed.
  }
}
