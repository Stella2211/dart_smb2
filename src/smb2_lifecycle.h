#ifndef DART_SMB2_LIFECYCLE_H
#define DART_SMB2_LIFECYCLE_H

#ifdef _WIN32
#define DSMB_API __declspec(dllexport)
#else
#define DSMB_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef void *(*dsmb_init_fn)(void);
typedef void (*dsmb_destroy_fn)(void *ctx);
typedef void (*dsmb_command_cb)(void *ctx, int status, void *command_data,
                                void *cb_data);

DSMB_API int dsmb_lifecycle_abi_version(void);
DSMB_API void *dsmb_owner_init(dsmb_init_fn init_fn,
                               dsmb_destroy_fn destroy_fn);
DSMB_API void *dsmb_owner_context(void *owner);
DSMB_API void dsmb_owner_destroy(void *owner);
DSMB_API void *dsmb_slot_create(void *owner, int copy_cstring);
DSMB_API dsmb_command_cb dsmb_slot_callback(void);
DSMB_API int dsmb_slot_done(void *slot);
DSMB_API int dsmb_slot_status(void *slot);
DSMB_API void *dsmb_slot_data(void *slot);
DSMB_API char *dsmb_slot_cstring(void *slot);
DSMB_API void dsmb_slot_free(void *slot);

#ifdef __cplusplus
}
#endif

#endif
