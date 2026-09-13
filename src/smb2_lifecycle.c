#include "smb2_lifecycle.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
static SRWLOCK context_lock = SRWLOCK_INIT;
#define LOCK_CONTEXTS() AcquireSRWLockExclusive(&context_lock)
#define UNLOCK_CONTEXTS() ReleaseSRWLockExclusive(&context_lock)
#else
#include <pthread.h>
static pthread_mutex_t context_lock = PTHREAD_MUTEX_INITIALIZER;
#define LOCK_CONTEXTS() pthread_mutex_lock(&context_lock)
#define UNLOCK_CONTEXTS() pthread_mutex_unlock(&context_lock)
#endif

typedef struct dsmb_owner dsmb_owner;
typedef struct dsmb_slot dsmb_slot;

struct dsmb_slot {
  dsmb_owner *owner;
  dsmb_slot *next;
  int done;
  int status;
  int copy_cstring;
  void *data;
  char *text;
};

struct dsmb_owner {
  void *ctx;
  dsmb_destroy_fn destroy;
  int destroying;
  dsmb_slot *slots;
};

DSMB_API int dsmb_lifecycle_abi_version(void) { return 1; }

DSMB_API void *dsmb_owner_init(dsmb_init_fn init_fn,
                               dsmb_destroy_fn destroy_fn) {
  if (init_fn == NULL || destroy_fn == NULL) {
    return NULL;
  }

  dsmb_owner *owner = (dsmb_owner *)calloc(1, sizeof(*owner));
  if (owner == NULL) {
    return NULL;
  }

  LOCK_CONTEXTS();
  owner->ctx = init_fn();
  UNLOCK_CONTEXTS();

  if (owner->ctx == NULL) {
    free(owner);
    return NULL;
  }
  owner->destroy = destroy_fn;
  return owner;
}

DSMB_API void *dsmb_owner_context(void *owner_pointer) {
  dsmb_owner *owner = (dsmb_owner *)owner_pointer;
  return owner == NULL ? NULL : owner->ctx;
}

static void unlink_slot(dsmb_slot *slot) {
  dsmb_owner *owner = slot->owner;
  if (owner == NULL) {
    return;
  }

  dsmb_slot **cursor = &owner->slots;
  while (*cursor != NULL && *cursor != slot) {
    cursor = &(*cursor)->next;
  }
  if (*cursor == slot) {
    *cursor = slot->next;
  }
}

static void free_slot(dsmb_slot *slot) {
  if (slot == NULL) {
    return;
  }

  unlink_slot(slot);
  free(slot->text);
  free(slot);
}

static void slot_callback(void *ctx, int status, void *data, void *opaque) {
  dsmb_slot *slot = (dsmb_slot *)opaque;
  (void)ctx;

  if (slot == NULL) {
    return;
  }
  if (slot->owner == NULL || slot->owner->destroying) {
    free_slot(slot);
    return;
  }

  slot->status = status;
  slot->data = data;

  if (slot->copy_cstring && status >= 0 && data != NULL) {
    const char *source = (const char *)data;
    const size_t length = strlen(source) + 1;
    slot->text = (char *)malloc(length);
    if (slot->text == NULL) {
      slot->status = -ENOMEM;
      slot->data = NULL;
    } else {
      memcpy(slot->text, source, length);
    }
  }

  slot->done = 1;
}

DSMB_API void *dsmb_slot_create(void *owner_pointer, int copy_cstring) {
  dsmb_owner *owner = (dsmb_owner *)owner_pointer;
  if (owner == NULL || owner->destroying) {
    return NULL;
  }

  dsmb_slot *slot = (dsmb_slot *)calloc(1, sizeof(*slot));
  if (slot == NULL) {
    return NULL;
  }

  slot->owner = owner;
  slot->copy_cstring = copy_cstring;
  slot->next = owner->slots;
  owner->slots = slot;
  return slot;
}

DSMB_API dsmb_command_cb dsmb_slot_callback(void) { return slot_callback; }

DSMB_API int dsmb_slot_done(void *slot) {
  return slot == NULL ? 1 : ((dsmb_slot *)slot)->done;
}

DSMB_API int dsmb_slot_status(void *slot) {
  return slot == NULL ? -EINVAL : ((dsmb_slot *)slot)->status;
}

DSMB_API void *dsmb_slot_data(void *slot) {
  return slot == NULL ? NULL : ((dsmb_slot *)slot)->data;
}

DSMB_API char *dsmb_slot_cstring(void *slot) {
  return slot == NULL ? NULL : ((dsmb_slot *)slot)->text;
}

DSMB_API void dsmb_slot_free(void *slot) { free_slot((dsmb_slot *)slot); }

DSMB_API void dsmb_owner_destroy(void *owner_pointer) {
  dsmb_owner *owner = (dsmb_owner *)owner_pointer;
  if (owner == NULL || owner->destroying) {
    return;
  }

  owner->destroying = 1;
  LOCK_CONTEXTS();
  if (owner->destroy != NULL) {
    owner->destroy(owner->ctx);
  }
  UNLOCK_CONTEXTS();

  while (owner->slots != NULL) {
    dsmb_slot *slot = owner->slots;
    owner->slots = slot->next;
    free(slot->text);
    free(slot);
  }
  free(owner);
}
