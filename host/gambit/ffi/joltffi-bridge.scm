;; Ahead-of-time native bridge for the bounded Gambit FFI tier.
;; generated-shims.scm supplies typed calls from shapes.json (including the
;; variadic boundary). Blocking, callables, aggregates, runtime signatures and
;; pinning remain refused in the adapter/compiler. See README.md for coverage.
;;
;; Capture cells are allocated per invocation before entering C. Each typed
;; shim saves errno immediately after its target, before conversion or cleanup,
;; then writes the caller-owned cell. No last-errno global/TLS cell is used.
;; The test build injects a clobber AFTER that save; the wrong-order control
;; saves AFTER its clobber. Neither control qualifies callbacks or blocking.
;;
;; Native pointers cross as exact integers through unsigned-long. Static
;; assertions enforce LP64. Only the provisioned macOS arm64 leg is qualified.
;; Bulk copies borrow a u8vector body for one non-allocating synchronous C call;
;; they retain no Scheme address and are never collect-safe.

(c-declare #<<JOLTFFI-C-BEGIN

#include <errno.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <time.h>
_Static_assert(sizeof(void*) == 8 && sizeof(long) == 8 && sizeof(int) == 4, "stage-1 requires LP64");

static int joltffi_capture_test_enabled(void)
{
#ifdef JOLTFFI_CAPTURE_TEST
  return 1;
#else
  return 0;
#endif
}
static char *joltffi_c_os(void)
{
#ifdef __APPLE__
  return "darwin";
#else
  return "linux";
#endif
}

/* ---- loader flags (compile-time platform, as the Chez loader probes them) ---
   RTLD_NOW on every POSIX host; RTLD_LOCAL on darwin is 0x4, on Linux 0 (the
   default, matching Chez's ffi-rtld-flags table in host/chez/java/ffi.ss). */
#define JOLTFFI_RTLD_NOW   2
#ifdef __APPLE__
#define JOLTFFI_RTLD_LOCAL 0x4
#else
#define JOLTFFI_RTLD_LOCAL 0
#endif

/* ---- loader ----------------------------------------------------------------- */
static unsigned long joltffi_c_dlopen (const char *path)
{ return ___CAST(unsigned long, dlopen (path, JOLTFFI_RTLD_NOW | JOLTFFI_RTLD_LOCAL)); }

static unsigned long joltffi_c_dlsym (unsigned long h, const char *name)
{ return ___CAST(unsigned long, dlsym (___CAST(void *, h), name)); }

/* process-global resolution (RTLD_DEFAULT): the process's own symbols plus
   RTLD_GLOBAL objects. RTLD_LOCAL loaded natives are deliberately NOT visible
   here — the scoped-before-global isolation guarantee. */
static unsigned long joltffi_c_dlsym_global (const char *name)
{ return ___CAST(unsigned long, dlsym (RTLD_DEFAULT, name)); }

static unsigned long joltffi_c_dlopen_global (const char *path)
{ return ___CAST(unsigned long, dlopen (path, JOLTFFI_RTLD_NOW)); }   /* sa-load-shared-object of #f */

static char *joltffi_c_dlerror (void)
{ return ___CAST(char *, dlerror ()); }

static int joltffi_c_dlclose (unsigned long h)
{ return dlclose (___CAST(void *, h)); }

/* Datagram cleanup stays off the Gambit processor. On Darwin a content
   filter can delay close even with SO_LINGER disabled. The native worker
   owns only a C allocation and an fd, and never enters the Scheme runtime. */
struct joltffi_close_job {
  atomic_int refs;
  atomic_int done;
  int fd;
  int result;
  int error;
};

static void joltffi_close_job_release(unsigned long address)
{
  struct joltffi_close_job *job = (struct joltffi_close_job *)address;
  if (atomic_fetch_sub_explicit(&job->refs, 1, memory_order_acq_rel) == 1)
    free(job);
}

static void *joltffi_close_worker(void *arg)
{
  struct joltffi_close_job *job = arg;
  errno = 0;
  int result = close(job->fd);
  int error = errno;
  job->result = result;
  job->error = error;
  atomic_store_explicit(&job->done, 1, memory_order_release);
  joltffi_close_job_release((unsigned long)job);
  return NULL;
}

static unsigned long joltffi_start_datagram_close(int fd)
{
  struct joltffi_close_job *job = malloc(sizeof *job);
  if (job == NULL)
    return 0;
  atomic_init(&job->refs, 2);
  atomic_init(&job->done, 0);
  job->fd = fd;

  pthread_attr_t attrs;
  pthread_t worker;
  int error = pthread_attr_init(&attrs);
  if (error == 0) {
    error = pthread_attr_setdetachstate(&attrs, PTHREAD_CREATE_DETACHED);
    if (error == 0)
      error = pthread_create(&worker, &attrs, joltffi_close_worker, job);
    pthread_attr_destroy(&attrs);
  }
  if (error != 0) {
    job->result = -2; /* submission failed; close() was never called */
    job->error = error;
    atomic_store_explicit(&job->done, 1, memory_order_release);
    joltffi_close_job_release((unsigned long)job);
  }
  return (unsigned long)job;
}

static int64_t joltffi_poll_datagram_close(unsigned long address)
{
  struct joltffi_close_job *job = (struct joltffi_close_job *)address;
  if (!atomic_load_explicit(&job->done, memory_order_acquire))
    return INT64_MIN;
  return job->result * INT64_C(4294967296) + job->error;
}


/* Store syscalls with no Gambit port equivalent. Submission copies the path
   and returns immediately. All filesystem calls, including fd disposal,
   take place on the worker. No worker sees a Scheme object or runs Scheme. */
enum joltffi_file_op {
  JOLT_FILE_LOCK, JOLT_FILE_UNLOCK, JOLT_FILE_TRUNCATE,
  JOLT_FILE_SYNC_DIR, JOLT_FILE_WRITABLE
};
enum joltffi_file_state { JOLT_FILE_RUNNING, JOLT_FILE_READY,
                         JOLT_FILE_TAKEN, JOLT_FILE_ABANDONED };

struct joltffi_file_job {
  atomic_int refs;
  atomic_int state;
  int op;
  int fd;
  int64_t size;
  uint64_t device;
  uint64_t inode;
  int result;
  char path[];
};

static int joltffi_file_open(const char *path, int flags)
{
  int fd;
  do {
    fd = open(path, flags | O_CLOEXEC | O_NONBLOCK, 0666);
  } while (fd < 0 && errno == EINTR);
  return fd;
}

static int joltffi_file_close(int fd)
{
  if (close(fd) == 0 || errno == EINTR)
    return 0;
  return -errno;
}

static int joltffi_file_run(struct joltffi_file_job *job)
{
  if (job->op == JOLT_FILE_UNLOCK)
    return joltffi_file_close(job->fd);
  if (job->op == JOLT_FILE_WRITABLE)
    return access(job->path, W_OK | X_OK) == 0 ? 1 : 0;

  int flags = job->op == JOLT_FILE_SYNC_DIR ? O_RDONLY | O_DIRECTORY :
              job->op == JOLT_FILE_LOCK ? O_RDWR | O_CREAT | O_NOFOLLOW :
              O_WRONLY;
  int fd = joltffi_file_open(job->path, flags);
  if (fd < 0)
    return -errno;

  int result;
  struct stat st;
  if (job->op == JOLT_FILE_SYNC_DIR) {
    result = fsync(fd) == 0 ? 0 : -errno;
  } else if (fstat(fd, &st) != 0) {
    result = -errno;
  } else if (!S_ISREG(st.st_mode)) {
    result = -EINVAL;
  } else if (job->op == JOLT_FILE_LOCK) {
    /* F_SETLK excludes the Chez, JVM and Dart record locks. Never queue
       behind another owner. Reject aliased lock inodes in separate dirs. */
    struct flock lock = { .l_type = F_WRLCK, .l_whence = SEEK_SET };
    if (st.st_nlink != 1)
      result = -EINVAL;
    else {
      int rc;
      do {
        rc = fcntl(fd, F_SETLK, &lock);
      } while (rc < 0 && errno == EINTR);
      if (rc == 0)
        return fd;
      result = errno == EACCES || errno == EAGAIN ? INT_MAX : -errno;
    }
  } else if ((uint64_t)st.st_dev != job->device ||
             (uint64_t)st.st_ino != job->inode) {
    result = -ESTALE;
  } else {
    int rc;
    do {
      rc = ftruncate(fd, (off_t)job->size);
    } while (rc < 0 && errno == EINTR);
    result = rc == 0 ? 0 : -errno;
  }
  int closed = joltffi_file_close(fd);
  return result == 0 ? closed : result;
}

static void joltffi_file_job_unref(struct joltffi_file_job *job)
{
  if (atomic_fetch_sub_explicit(&job->refs, 1, memory_order_acq_rel) == 1)
    free(job);
}

static void *joltffi_file_worker(void *arg)
{
  struct joltffi_file_job *job = arg;
  job->result = joltffi_file_run(job);
  int expected = JOLT_FILE_RUNNING;
  atomic_compare_exchange_strong_explicit(&job->state, &expected,
      JOLT_FILE_READY, memory_order_release, memory_order_relaxed);
  if (job->op == JOLT_FILE_LOCK && job->result >= 0 && job->result != INT_MAX) {
    /* An interrupted wait hands the unclaimed lock back to this worker. */
    int state;
    const struct timespec delay = { .tv_nsec = 1000000 };
    while ((state = atomic_load_explicit(&job->state, memory_order_acquire))
           == JOLT_FILE_READY)
      nanosleep(&delay, NULL);
    if (state == JOLT_FILE_ABANDONED)
      joltffi_file_close(job->result);
  }
  joltffi_file_job_unref(job);
  return NULL;
}

static unsigned long joltffi_start_file(int op, const char *path, int fd,
                                        int64_t size, uint64_t device, uint64_t inode)
{
  size_t length = strlen(path) + 1;
  struct joltffi_file_job *job = malloc(sizeof *job + length);
  if (job == NULL)
    return 0;
  atomic_init(&job->refs, 2);
  atomic_init(&job->state, JOLT_FILE_RUNNING);
  job->op = op;
  job->fd = fd;
  job->size = size;
  job->device = device;
  job->inode = inode;
  memcpy(job->path, path, length);

  pthread_attr_t attrs;
  pthread_t worker;
  int error = pthread_attr_init(&attrs);
  if (error == 0) {
    error = pthread_attr_setdetachstate(&attrs, PTHREAD_CREATE_DETACHED);
    if (error == 0)
      error = pthread_create(&worker, &attrs, joltffi_file_worker, job);
    pthread_attr_destroy(&attrs);
  }
  if (error != 0) {
    /* Distinct from a syscall failure: the job never started. */
    job->result = INT_MIN + error;
    atomic_store_explicit(&job->state, JOLT_FILE_READY, memory_order_release);
    joltffi_file_job_unref(job);
  }
  return (unsigned long)job;
}

static int64_t joltffi_poll_file(unsigned long address)
{
  struct joltffi_file_job *job = (struct joltffi_file_job *)address;
  if (atomic_load_explicit(&job->state, memory_order_acquire) != JOLT_FILE_READY)
    return INT64_MIN;
  return job->result;
}

static void joltffi_release_file(unsigned long address, int taken)
{
  struct joltffi_file_job *job = (struct joltffi_file_job *)address;
  atomic_store_explicit(&job->state,
      taken ? JOLT_FILE_TAKEN : JOLT_FILE_ABANDONED, memory_order_release);
  joltffi_file_job_unref(job);
}

/* ---- memory ----------------------------------------------------------------- */
static unsigned long joltffi_c_malloc (unsigned long n)
{ return ___CAST(unsigned long, malloc (___CAST(size_t, n))); }

static void joltffi_c_free (unsigned long p)
{ free (___CAST(void *, p)); }

static void joltffi_c_zero (unsigned long p, unsigned long n)
{ memset (___CAST(void *, p), 0, ___CAST(size_t, n)); }

/* foreign -> bytevector. Returns 0 ok, -1 bad count. */
static int joltffi_c_bytes_to_bv (___SCMOBJ bv, unsigned long src, unsigned long n)
{
  ___SCMOBJ ___temp; /* the subtype test macros need a temp cell */
  if (___HAS_TAG_AND_IS_NOT_DOUBLE (bv, ___tSUBTYPED, ___TB) && ___TESTSUBTYPE (bv, ___sU8VECTOR))
    {
      size_t len = ___U8VECTORSIZE (bv);
      if (___CAST(unsigned long, len) < n)
        return -1;
      if (n > 0)
        memcpy (___BODY_AS (bv, ___tU8VECTOR), ___CAST(void *, src), ___CAST(size_t, n));
      return 0;
    }
  return -1;
}

/* bytevector -> foreign. Returns 0 ok, -1 bad count. */
static int joltffi_c_bytes_from_bv (unsigned long dst, ___SCMOBJ bv, unsigned long n)
{
  ___SCMOBJ ___temp; /* the subtype test macros need a temp cell */
  if (___HAS_TAG_AND_IS_NOT_DOUBLE (bv, ___tSUBTYPED, ___TB) && ___TESTSUBTYPE (bv, ___sU8VECTOR))
    {
      size_t len = ___U8VECTORSIZE (bv);
      if (___CAST(unsigned long, len) < n)
        return -1;
      if (n > 0)
        memcpy (___CAST(void *, dst), ___BODY_AS (bv, ___tU8VECTOR), ___CAST(size_t, n));
      return 0;
    }
  return -1;
}

/* read one int (4 bytes) from a caller-allocated errno cell */
static int joltffi_c_read_i32 (unsigned long p)
{ int v; memcpy (&v, ___CAST(void *, p), 4); return v; }

/* Gate controls invoke the SAME errno-setting target, then clobber before or
   after capture. Production capture shims also run the post-capture clobber
   when built with JOLTFFI_CAPTURE_TEST; production builds omit that hook. */
static int joltffi_c_ctrl_wrong_order(unsigned long fn, unsigned long out)
{
  int r = ((int (*)(int,int,int))fn)(-1,0,0);
  errno = 4242;
  *(int *)out = errno;
  return r;
}
static int joltffi_c_preserve_control(unsigned long fn, unsigned long out)
{
  errno = 7777; /* preset inside this C invocation, before the target */
  int r = ((int (*)(int,int,int))fn)(1,2,3);
  int saved = errno;
  *(int *)out = saved;
  errno = 4242;
  return r;
}
/* ---- typed data-plane access (sa-foreign-ref / sa-foreign-set!) -------------
   memcpy-based so unaligned offsets behave; no errno semantics here — these are
   plain readers, not call shims. Each returns through a caller-supplied
   ___SCMOBJ only for the c-lambda wrapper below to keep ONE conversion shape;
   the scalar wrappers return the value directly through the c-lambda result
   conversion instead. */

static signed char joltffi_c_ref_i8 (unsigned long p, unsigned long off)
{ signed char v; memcpy (&v, ___CAST(void *, p + off), 1); return v; }
static unsigned char joltffi_c_ref_u8 (unsigned long p, unsigned long off)
{ unsigned char v; memcpy (&v, ___CAST(void *, p + off), 1); return v; }
static short joltffi_c_ref_i16 (unsigned long p, unsigned long off)
{ short v; memcpy (&v, ___CAST(void *, p + off), 2); return v; }
static unsigned short joltffi_c_ref_u16 (unsigned long p, unsigned long off)
{ unsigned short v; memcpy (&v, ___CAST(void *, p + off), 2); return v; }
static int32_t joltffi_c_ref_i32 (unsigned long p, unsigned long off)
{ int32_t v; memcpy (&v, ___CAST(void *, p + off), 4); return v; }
static uint32_t joltffi_c_ref_u32 (unsigned long p, unsigned long off)
{ uint32_t v; memcpy (&v, ___CAST(void *, p + off), 4); return v; }
static int64_t joltffi_c_ref_i64 (unsigned long p, unsigned long off)
{ int64_t v; memcpy (&v, ___CAST(void *, p + off), 8); return v; }
static uint64_t joltffi_c_ref_u64 (unsigned long p, unsigned long off)
{ uint64_t v; memcpy (&v, ___CAST(void *, p + off), 8); return v; }
static float joltffi_c_ref_f32 (unsigned long p, unsigned long off)
{ float v; memcpy (&v, ___CAST(void *, p + off), 4); return v; }
static double joltffi_c_ref_f64 (unsigned long p, unsigned long off)
{ double v; memcpy (&v, ___CAST(void *, p + off), 8); return v; }

static void joltffi_c_set_i8 (unsigned long p, unsigned long off, signed char v)
{ memcpy (___CAST(void *, p + off), &v, 1); }
static void joltffi_c_set_u8 (unsigned long p, unsigned long off, unsigned char v)
{ memcpy (___CAST(void *, p + off), &v, 1); }
static void joltffi_c_set_i16 (unsigned long p, unsigned long off, short v)
{ memcpy (___CAST(void *, p + off), &v, 2); }
static void joltffi_c_set_u16 (unsigned long p, unsigned long off, unsigned short v)
{ memcpy (___CAST(void *, p + off), &v, 2); }
static void joltffi_c_set_i32 (unsigned long p, unsigned long off, int32_t v)
{ memcpy (___CAST(void *, p + off), &v, 4); }
static void joltffi_c_set_u32 (unsigned long p, unsigned long off, uint32_t v)
{ memcpy (___CAST(void *, p + off), &v, 4); }
static void joltffi_c_set_i64 (unsigned long p, unsigned long off, int64_t v)
{ memcpy (___CAST(void *, p + off), &v, 8); }
static void joltffi_c_set_u64 (unsigned long p, unsigned long off, uint64_t v)
{ memcpy (___CAST(void *, p + off), &v, 8); }
static void joltffi_c_set_f32 (unsigned long p, unsigned long off, float v)
{ memcpy (___CAST(void *, p + off), &v, 4); }
static void joltffi_c_set_f64 (unsigned long p, unsigned long off, double v)
{ memcpy (___CAST(void *, p + off), &v, 8); }

JOLTFFI-C-BEGIN

)

;; ---- Scheme wrappers ----------------------------------------------------------
;; One per shim: the c-lambda IS the conversion boundary (arguments convert at
;; the call; the C body runs with the converted values). Capture wrappers take
;; the errout cell address between fn and the declared args; the adapter
;; allocates and frees the cell around each call.

(define (joltffi-capture-test-enabled?)
  (= 1 ((c-lambda () int "joltffi_capture_test_enabled"))))
(define (joltffi-platform-key)
  ((c-lambda () char-string "joltffi_c_os")))

;; The result packs close's signed int and the worker's captured errno.
;; Yield using Gambit's scheduler while the worker holds its own reference.
(define (joltffi-await-datagram-close fd)
  (let* ((start (c-lambda (int) unsigned-long "joltffi_start_datagram_close"))
         (poll (c-lambda (unsigned-long) int64 "joltffi_poll_datagram_close"))
         (release (c-lambda (unsigned-long) void "joltffi_close_job_release"))
         (job (start fd)))
    (if (= job 0)
        (error "jolt.ffi: could not allocate datagram close job")
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (let loop ()
              (let ((result (poll job)))
                (cond ((= result -9223372036854775808)
                       (thread-sleep! 0.001)
                       (loop))
                      ((< result -4294967296)
                       (error "jolt.ffi: could not start datagram close worker"
                              (+ result 8589934592)))
                      (else result)))))
          (lambda () (release job))))))


;; Private store bridge. The VM polls atomic state and parks between polls.
;; The operation IDs are joltffi_file_op's closed set above.
(define (joltffi-await-file op path fd size dev ino)
  (let* ((start (c-lambda (int char-string int int64 unsigned-int64 unsigned-int64)
                          unsigned-long "joltffi_start_file"))
         (poll (c-lambda (unsigned-long) int64 "joltffi_poll_file"))
         (release (c-lambda (unsigned-long int) void "joltffi_release_file"))
         (job (start op path fd size dev ino))
         (taken 0))
    (when (= job 0)
      (error "Gambit file worker allocation failed"))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let loop ()
          (let ((result (poll job)))
            (cond ((= result -9223372036854775808)
                   (thread-sleep! 0.001)
                   (loop))
                  ((< result -1073741824)
                   (error "Gambit file worker submission failed"
                          (+ result 2147483648)))
                  (else
                   (set! taken 1)
                   result)))))
      (lambda () (release job taken)))))

;; ---- loader wrappers ----------------------------------------------------------
(define (joltffi-dlopen path)
  ((c-lambda (char-string) unsigned-long "joltffi_c_dlopen") path))
(define (joltffi-dlopen-global path)
  ((c-lambda (char-string) unsigned-long "joltffi_c_dlopen_global") path))
(define (joltffi-dlsym handle name)
  ((c-lambda (unsigned-long char-string) unsigned-long "joltffi_c_dlsym") handle name))
(define (joltffi-dlsym-global name)
  ((c-lambda (char-string) unsigned-long "joltffi_c_dlsym_global") name))
(define (joltffi-dlerror)
  ((c-lambda () char-string "joltffi_c_dlerror")))
(define (joltffi-dlclose handle)
  ((c-lambda (unsigned-long) int "joltffi_c_dlclose") handle))

;; ---- memory wrappers ----------------------------------------------------------
(define (joltffi-malloc n)
  ((c-lambda (unsigned-long) unsigned-long "joltffi_c_malloc") n))
(define (joltffi-free p)
  ((c-lambda (unsigned-long) void "joltffi_c_free") p))
(define (joltffi-zero p n)
  ((c-lambda (unsigned-long unsigned-long) void "joltffi_c_zero") p n))
;; 0 ok / -1 count-too-large: the adapter raises before dereferencing anything.
(define (joltffi-bytes-to-bv! bv src n)
  ((c-lambda (scheme-object unsigned-long unsigned-long) int "joltffi_c_bytes_to_bv") bv src n))
(define (joltffi-bytes-from-bv! dst bv n)
  ((c-lambda (unsigned-long scheme-object unsigned-long) int "joltffi_c_bytes_from_bv") dst bv n))
(define (joltffi-read-i32 p)
  ((c-lambda (unsigned-long) int "joltffi_c_read_i32") p))

;; ---- the negative-control entry (gate-only; see the C comment above) ----------
(define (joltffi-ctrl-wrong-order fn errout)
  ((c-lambda (unsigned-long unsigned-long) int "joltffi_c_ctrl_wrong_order") fn errout))


(define (joltffi-preserve-control fn out)
  ((c-lambda (unsigned-long unsigned-long) int "joltffi_c_preserve_control") fn out))

;; ---- typed data-plane wrappers (sa-foreign-ref / sa-foreign-set!) ------------
(define (joltffi-ref-i8 addr off) ((c-lambda (unsigned-long unsigned-long) int8 "joltffi_c_ref_i8") addr off))
(define (joltffi-ref-u8 addr off) ((c-lambda (unsigned-long unsigned-long) unsigned-int8 "joltffi_c_ref_u8") addr off))
(define (joltffi-ref-i16 addr off) ((c-lambda (unsigned-long unsigned-long) int16 "joltffi_c_ref_i16") addr off))
(define (joltffi-ref-u16 addr off) ((c-lambda (unsigned-long unsigned-long) unsigned-int16 "joltffi_c_ref_u16") addr off))
(define (joltffi-ref-i32 addr off) ((c-lambda (unsigned-long unsigned-long) int32 "joltffi_c_ref_i32") addr off))
(define (joltffi-ref-u32 addr off) ((c-lambda (unsigned-long unsigned-long) unsigned-int32 "joltffi_c_ref_u32") addr off))
(define (joltffi-ref-i64 addr off) ((c-lambda (unsigned-long unsigned-long) int64 "joltffi_c_ref_i64") addr off))
(define (joltffi-ref-u64 addr off) ((c-lambda (unsigned-long unsigned-long) unsigned-int64 "joltffi_c_ref_u64") addr off))
(define (joltffi-ref-f32 addr off) ((c-lambda (unsigned-long unsigned-long) float32 "joltffi_c_ref_f32") addr off))
(define (joltffi-ref-f64 addr off) ((c-lambda (unsigned-long unsigned-long) float64 "joltffi_c_ref_f64") addr off))
(define (joltffi-set-i8! addr off v) ((c-lambda (unsigned-long unsigned-long int8) void "joltffi_c_set_i8") addr off v))
(define (joltffi-set-u8! addr off v) ((c-lambda (unsigned-long unsigned-long unsigned-int8) void "joltffi_c_set_u8") addr off v))
(define (joltffi-set-i16! addr off v) ((c-lambda (unsigned-long unsigned-long int16) void "joltffi_c_set_i16") addr off v))
(define (joltffi-set-u16! addr off v) ((c-lambda (unsigned-long unsigned-long unsigned-int16) void "joltffi_c_set_u16") addr off v))
(define (joltffi-set-i32! addr off v) ((c-lambda (unsigned-long unsigned-long int32) void "joltffi_c_set_i32") addr off v))
(define (joltffi-set-u32! addr off v) ((c-lambda (unsigned-long unsigned-long unsigned-int32) void "joltffi_c_set_u32") addr off v))
(define (joltffi-set-i64! addr off v) ((c-lambda (unsigned-long unsigned-long int64) void "joltffi_c_set_i64") addr off v))
(define (joltffi-set-u64! addr off v) ((c-lambda (unsigned-long unsigned-long unsigned-int64) void "joltffi_c_set_u64") addr off v))
(define (joltffi-set-f32! addr off v) ((c-lambda (unsigned-long unsigned-long float32) void "joltffi_c_set_f32") addr off v))
(define (joltffi-set-f64! addr off v) ((c-lambda (unsigned-long unsigned-long float64) void "joltffi_c_set_f64") addr off v))

(##include "generated-shims.scm")
