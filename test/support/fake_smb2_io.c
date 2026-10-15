/*
 * Fake libsmb2 for the pipelined I/O tests (test/io_pipeline_test.dart).
 *
 * Serves one in-memory file. pread/pwrite are queued and only complete
 * (copying data to/from the caller's buffer at that point, like the real
 * library) when smb2_service runs, so several requests can be in flight at
 * once. Behaviour knobs (environment):
 *
 *   DART_SMB2_FAKE_FILE_SIZE   initial file size (pattern byte i = i * 7 + 3)
 *   DART_SMB2_FAKE_MAX_IO      reported max_read_size / max_write_size
 *   DART_SMB2_FAKE_CLAMP       every reply is capped at this many bytes
 *                              (like libsmb2's MaxReadSize / credit clamp)
 *   DART_SMB2_FAKE_FAIL_AT     a pread covering this offset fails with EIO
 *
 * fake_max_in_flight() / fake_reset_stats() let the test observe pipelining.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct smb2_context smb2_context;
typedef void (*smb2_cb)(smb2_context *, int, void *, void *);

struct smb2_stat_64 {
  uint32_t smb2_type;
  uint32_t smb2_nlink;
  uint64_t smb2_ino;
  uint64_t smb2_size;
  uint64_t smb2_atime;
  uint64_t smb2_atime_nsec;
  uint64_t smb2_mtime;
  uint64_t smb2_mtime_nsec;
  uint64_t smb2_ctime;
  uint64_t smb2_ctime_nsec;
  uint64_t smb2_btime;
  uint64_t smb2_btime_nsec;
};

typedef struct op {
  struct op *next;
  int is_write;
  uint8_t *buf;
  uint32_t count;
  uint64_t offset;
  smb2_cb cb;
  void *data;
} op;

struct smb2_context {
  int pipe_fds[2];
  op *head;
  op *tail;
  int in_flight;
};

static uint8_t *file_data;
static size_t file_size;
static size_t file_capacity;
static int max_in_flight;
static int fh_token;

static long env_long(const char *name, long fallback) {
  const char *value = getenv(name);
  return value == NULL ? fallback : strtol(value, NULL, 10);
}

static void ensure_file(void) {
  if (file_data != NULL) {
    return;
  }
  file_size = (size_t)env_long("DART_SMB2_FAKE_FILE_SIZE", 0);
  file_capacity = file_size == 0 ? 1 : file_size;
  file_data = (uint8_t *)malloc(file_capacity);
  for (size_t i = 0; i < file_size; i++) {
    file_data[i] = (uint8_t)(i * 7 + 3);
  }
}

int fake_max_in_flight(void) { return max_in_flight; }

void fake_reset_stats(void) { max_in_flight = 0; }

smb2_context *smb2_init_context(void) {
  smb2_context *context = (smb2_context *)calloc(1, sizeof(smb2_context));
  /* A pipe with one unread byte: always readable, so poll() never blocks. */
  if (pipe(context->pipe_fds) != 0 || write(context->pipe_fds[1], "x", 1) != 1) {
    free(context);
    return NULL;
  }
  ensure_file();
  return context;
}

void smb2_set_user(smb2_context *c, const char *v) { (void)c; (void)v; }
void smb2_set_password(smb2_context *c, const char *v) { (void)c; (void)v; }
void smb2_set_domain(smb2_context *c, const char *v) { (void)c; (void)v; }
void smb2_set_timeout(smb2_context *c, int v) { (void)c; (void)v; }

int smb2_connect_share_async(smb2_context *context, const char *host,
                             const char *share, const char *user,
                             smb2_cb callback, void *data) {
  (void)host;
  (void)share;
  (void)user;
  callback(context, 0, NULL, data);
  return 0;
}

int smb2_disconnect_share_async(smb2_context *context, smb2_cb callback,
                                void *data) {
  callback(context, 0, NULL, data);
  return 0;
}

int smb2_open_async(smb2_context *context, const char *path, int flags,
                    smb2_cb callback, void *data) {
  (void)path;
  if (flags & O_TRUNC) {
    file_size = 0;
  }
  callback(context, 0, &fh_token, data);
  return 0;
}

int smb2_close_async(smb2_context *context, void *fh, smb2_cb callback,
                     void *data) {
  (void)fh;
  callback(context, 0, NULL, data);
  return 0;
}

int smb2_fstat_async(smb2_context *context, void *fh, struct smb2_stat_64 *st,
                     smb2_cb callback, void *data) {
  (void)fh;
  memset(st, 0, sizeof(*st));
  st->smb2_size = file_size;
  callback(context, 0, NULL, data);
  return 0;
}

int smb2_ftruncate_async(smb2_context *context, void *fh, uint64_t length,
                         smb2_cb callback, void *data) {
  (void)fh;
  if (length <= file_size) {
    file_size = (size_t)length;
  }
  callback(context, 0, NULL, data);
  return 0;
}

uint32_t smb2_get_max_read_size(smb2_context *context) {
  (void)context;
  return (uint32_t)env_long("DART_SMB2_FAKE_MAX_IO", 65536);
}

uint32_t smb2_get_max_write_size(smb2_context *context) {
  (void)context;
  return (uint32_t)env_long("DART_SMB2_FAKE_MAX_IO", 65536);
}

static int enqueue(smb2_context *context, int is_write, uint8_t *buf,
                   uint32_t count, uint64_t offset, smb2_cb callback,
                   void *data) {
  op *o = (op *)calloc(1, sizeof(op));
  if (o == NULL) {
    return -ENOMEM;
  }
  o->is_write = is_write;
  o->buf = buf;
  o->count = count;
  o->offset = offset;
  o->cb = callback;
  o->data = data;
  if (context->tail == NULL) {
    context->head = o;
  } else {
    context->tail->next = o;
  }
  context->tail = o;
  context->in_flight++;
  if (context->in_flight > max_in_flight) {
    max_in_flight = context->in_flight;
  }
  return 0;
}

int smb2_pread_async(smb2_context *context, void *fh, uint8_t *buf,
                     uint32_t count, uint64_t offset, smb2_cb callback,
                     void *data) {
  (void)fh;
  return enqueue(context, 0, buf, count, offset, callback, data);
}

int smb2_pwrite_async(smb2_context *context, void *fh, const uint8_t *buf,
                      uint32_t count, uint64_t offset, smb2_cb callback,
                      void *data) {
  (void)fh;
  return enqueue(context, 1, (uint8_t *)buf, count, offset, callback, data);
}

static int complete(op *o) {
  uint32_t count = o->count;
  const long clamp = env_long("DART_SMB2_FAKE_CLAMP", 0);
  if (clamp > 0 && count > (uint32_t)clamp) {
    count = (uint32_t)clamp;
  }

  if (o->is_write) {
    const size_t end = (size_t)o->offset + count;
    if (end > file_capacity) {
      file_capacity = end * 2;
      file_data = (uint8_t *)realloc(file_data, file_capacity);
    }
    if (o->offset > file_size) {
      memset(file_data + file_size, 0, (size_t)o->offset - file_size);
    }
    memcpy(file_data + o->offset, o->buf, count);
    if (end > file_size) {
      file_size = end;
    }
    return (int)count;
  }

  const long fail_at = env_long("DART_SMB2_FAKE_FAIL_AT", -1);
  if (fail_at >= 0 && (uint64_t)fail_at >= o->offset &&
      (uint64_t)fail_at < o->offset + o->count) {
    return -EIO;
  }
  if (o->offset >= file_size) {
    return 0;
  }
  if (o->offset + count > file_size) {
    count = (uint32_t)(file_size - o->offset);
  }
  memcpy(o->buf, file_data + o->offset, count);
  return (int)count;
}

int smb2_get_fd(smb2_context *context) { return context->pipe_fds[0]; }

int smb2_which_events(smb2_context *context) {
  (void)context;
  return 1; /* POLLIN */
}

/* Completes everything queued so far, in reverse order to make sure the
 * client doesn't rely on replies arriving in request order. */
int smb2_service(smb2_context *context, int revents) {
  (void)revents;
  op *list = context->head;
  context->head = NULL;
  context->tail = NULL;

  op *reversed = NULL;
  while (list != NULL) {
    op *next = list->next;
    list->next = reversed;
    reversed = list;
    list = next;
  }
  while (reversed != NULL) {
    op *next = reversed->next;
    context->in_flight--;
    reversed->cb(context, complete(reversed), NULL, reversed->data);
    free(reversed);
    reversed = next;
  }
  return 0;
}

const char *smb2_get_error(smb2_context *context) {
  (void)context;
  return "fake I/O error";
}

void smb2_destroy_context(smb2_context *context) {
  op *o = context->head;
  while (o != NULL) {
    op *next = o->next;
    o->cb(context, -ECONNRESET, NULL, o->data);
    free(o);
    o = next;
  }
  close(context->pipe_fds[0]);
  close(context->pipe_fds[1]);
  free(context);
}
