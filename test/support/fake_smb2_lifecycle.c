#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct smb2_context smb2_context;
typedef void (*smb2_cb)(smb2_context *, int, void *, void *);

struct smb2_context {
  int fd;
  smb2_cb pending_cb;
  void *pending_data;
};

static void append_marker(const char *environment_name, const char *value) {
  const char *path = getenv(environment_name);
  if (path == NULL) {
    return;
  }

  FILE *file = fopen(path, "a");
  if (file == NULL) {
    return;
  }
  fprintf(file, "%s\n", value);
  fclose(file);
}

static void register_pending(smb2_context *context, smb2_cb callback,
                             void *data) {
  context->pending_cb = callback;
  context->pending_data = data;
  append_marker("DART_SMB2_PENDING_MARKER", "pending");
}

smb2_context *smb2_init_context(void) {
  return (smb2_context *)calloc(1, sizeof(smb2_context));
}

void smb2_set_user(smb2_context *context, const char *value) {
  (void)context;
  (void)value;
}

void smb2_set_password(smb2_context *context, const char *value) {
  (void)context;
  (void)value;
}

void smb2_set_domain(smb2_context *context, const char *value) {
  (void)context;
  (void)value;
}

void smb2_set_timeout(smb2_context *context, int value) {
  (void)context;
  (void)value;
}

void smb2_set_seal(smb2_context *context, int value) {
  (void)context;
  (void)value;
}

void smb2_set_sign(smb2_context *context, int value) {
  (void)context;
  (void)value;
}

void smb2_set_version(smb2_context *context, int value) {
  (void)context;
  (void)value;
}

int smb2_connect_share_async(smb2_context *context, const char *host,
                             const char *share, const char *user,
                             smb2_cb callback, void *data) {
  (void)host;
  (void)share;
  (void)user;
  if (getenv("DART_SMB2_FAKE_CONNECT_PENDING") != NULL) {
    register_pending(context, callback, data);
    return 0;
  }
  callback(context, 0, NULL, data);
  return 0;
}

int smb2_readlink_async(smb2_context *context, const char *path,
                        smb2_cb callback, void *data) {
  (void)path;
  char *target = (char *)malloc(sizeof("fake-target"));
  if (target == NULL) {
    callback(context, -12, NULL, data);
    return 0;
  }
  memcpy(target, "fake-target", sizeof("fake-target"));
  callback(context, 0, target, data);
  free(target);
  return 0;
}

int smb2_disconnect_share_async(smb2_context *context, smb2_cb callback,
                                void *data) {
  callback(context, 0, NULL, data);
  return 0;
}

int smb2_echo_async(smb2_context *context, smb2_cb callback, void *data) {
  register_pending(context, callback, data);
  return 0;
}

int smb2_get_fd(smb2_context *context) {
  (void)context;
  return -1;
}

int smb2_which_events(smb2_context *context) {
  (void)context;
  return 0;
}

int smb2_service(smb2_context *context, int revents) {
  (void)context;
  (void)revents;
  return 0;
}

const char *smb2_get_error(smb2_context *context) {
  (void)context;
  return "fake";
}

void smb2_destroy_context(smb2_context *context) {
  if (context->pending_cb != NULL) {
    smb2_cb callback = context->pending_cb;
    void *data = context->pending_data;
    context->pending_cb = NULL;
    context->pending_data = NULL;
    callback(context, 0, NULL, data);
  }
  free(context);
  append_marker("DART_SMB2_LIFECYCLE_MARKER", "destroy");
}
