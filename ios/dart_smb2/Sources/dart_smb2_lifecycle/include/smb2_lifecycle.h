#ifndef DART_SMB2_LIFECYCLE_ANCHOR_H
#define DART_SMB2_LIFECYCLE_ANCHOR_H

// SwiftPM references this function to retain the C implementation.
// The remaining entry points are loaded by Dart through FFI.
#ifdef __cplusplus
extern "C" {
#endif
int dsmb_lifecycle_abi_version(void);
#ifdef __cplusplus
}
#endif
#endif
