/* joltffi-fixture.c — the stage-1 gate fixture library (P1b-stage1).
 *
 * One extern "C" target per registered ordinary ABI shape the bridge carries
 * (p1b-inv/shim-registry.edn), plus the errno negative controls the repaired
 * W1-r2 pattern requires, and the errno-value probes so the assertions hold on
 * any OS. Built by the gambitffi* Makefile targets into
 * build/gambit-ffi/libjoltffi-fixture.dylib (and the two loader-smoke
 * libraries) with cc, loaded through jolt's own loader path.
 *
 * The TARGETS own their errno, exactly as W1's repair demands:
 *   - capture targets set errno themselves and return -1 (failure), or return
 *     a success value and PRESERVE the caller's errno (contract: do not
 *     normalize success to zero);
 *   - the intervening/post-capture clobbers are written AFTER the "target"
 *     portion of the call returns, so a shim that captures immediately defeats
 *     them, and one that does not is observable.
 *
 * Every symbol is exported with default visibility so dlsym sees it.
 */

#include <errno.h>
#include <stdint.h>
#include <sys/types.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define JOLTFFI_CLOBBER 7777

/* ---- errno probes (s01-shaped, so the gate reads them through the tier) ---- */
int joltffi_fx_eagain (void) { return EAGAIN; }
int joltffi_fx_eacces (void) { return EACCES; }
int joltffi_fx_ebadf  (void) { return EBADF; }
int joltffi_fx_eio    (void) { return EIO; }
int joltffi_fx_eintr_c (void) { return EINTR; }
int joltffi_fx_clobber_const (void) { return JOLTFFI_CLOBBER; }

/* ---- ordinary shapes ------------------------------------------------------- */

/* s01: () -> int */
int joltffi_fx_layout_version (void) { return 42; }

/* s01b: () -> int32 */
int32_t joltffi_fx_eintr (void) { return (int32_t) EINTR; }

/* s02: (void*, size_t) -> int — provenance-style writer */
int joltffi_fx_provenance (void *buf, size_t n)
{
  const char *text = "joltffi-fixture";
  size_t len = strlen (text);
  if (buf == NULL || n < len + 1)
    return -1;
  memcpy (buf, text, len + 1);
  return (int) len;
}

/* s03: (void*, size_t) -> void */
void joltffi_fx_cleanse (void *p, size_t n) { memset (p, 0, n); }

/* s03-shaped errno clobber: sets errno AFTER zeroing, so a capture call made
   after it reads the clobber and an EARLIER captured pair proves untouched. */
void joltffi_fx_seterrno_cleanse (void *p, size_t n)
{
  if (n > 0)
    memset (p, 0, n);
  errno = JOLTFFI_CLOBBER;
}

/* s12: (void*, int64) -> int32 — big-endian field read */
int32_t joltffi_fx_s32be_get (void *p, int64_t off)
{
  const unsigned char *b = (const unsigned char *) p + off;
  return (int32_t) (((uint32_t) b[0] << 24) | ((uint32_t) b[1] << 16)
                    | ((uint32_t) b[2] << 8) | (uint32_t) b[3]);
}

/* s12b: (void*, int64, int32) -> void — big-endian field write */
void joltffi_fx_s32be_put (void *p, int64_t off, int32_t v)
{
  unsigned char *b = (unsigned char *) p + off;
  uint32_t u = (uint32_t) v;
  b[0] = (unsigned char) (u >> 24);
  b[1] = (unsigned char) (u >> 16);
  b[2] = (unsigned char) (u >> 8);
  b[3] = (unsigned char) u;
}

/* s13: (int64, void*, int64) -> int64 — decimal error-text writer */
int64_t joltffi_fx_strerror (int64_t code, void *buf, int64_t n)
{
  if (buf == NULL || n < 2)
    return -1;
  int written = snprintf ((char *) buf, (size_t) n, "err-%lld", (long long) code);
  return (int64_t) written;
}

/* s18: (void*) -> void */
static int frees;
void joltffi_fx_free (void *p) { free (p); ++frees; }

/* s19: () -> void* */
void *joltffi_fx_worker_new (void) { return malloc (64); }

/* s20: () -> void* — the errno ACCESSOR shape (the ffi/errno read path) */
static int joltffi_fx_errno_cell;
void *joltffi_fx_errno_location (void) { return &joltffi_fx_errno_cell; }

/* s21: (int) -> string — nullable char* return (NULL -> jolt nil) */
static const char *joltffi_fx_errtext_one = "joltffi-error-one";
static const char *joltffi_fx_errtext_two = "joltffi-error-two";
const char *joltffi_fx_errtext (int code)
{
  switch (code)
    {
    case 1: return joltffi_fx_errtext_one;
    case 2: return joltffi_fx_errtext_two;
    default: return NULL;             /* NULL must surface as jolt nil */
    }
}

/* ---- declared-tail varargs shapes (variadic boundary) ---------------------- */

/* s22 / s22b: (int, int, ...) -> int. The declared tail is ONE int. cmd==99
   sets EAGAIN and returns -1 (capture targets own their errno); otherwise the
   sum travels back with the caller's errno untouched. */
int joltffi_fx_vfcntl (int fd, int cmd, ...)
{
  va_list ap;
  int tail;
  va_start (ap, cmd);
  tail = va_arg (ap, int);
  va_end (ap);
  if (cmd == 99)
    {
      errno = EAGAIN;
      return -1;
    }
  return fd + cmd + tail;
}

/* s22c: (int, unsigned long, ...) -> int with capture. req==88 sets EBADF. */
int joltffi_fx_vioctl (int fd, unsigned long req, ...)
{
  va_list ap;
  void *arg;
  va_start (ap, req);
  arg = va_arg (ap, void *);
  va_end (ap);
  if (req == 88)
    {
      errno = EBADF;
      return -1;
    }
  return fd + (int) (req & 0xff) + (arg != NULL ? 1 : 0);
}

/* ---- capture shapes (ordinary, no blocking): errno is the target's own ----- */

/* s23: (int, int, int, void*, void*) -> int */
int joltffi_fx_getsockoptlike (int fd, int lvl, int opt, void *val, void *len)
{
  if (fd < 0)
    {
      errno = EBADF;
      return -1;
    }
  return fd + lvl + opt + (val != NULL ? 1 : 0) + (len != NULL ? 1 : 0);
}

/* s26: (int, int, int) -> int */
int joltffi_fx_socketlike (int a, int b, int c)
{
  if (a < 0)
    {
      errno = EACCES;
      return -1;
    }
  return a + b + c;
}

/* s26b: (int, void*, int) -> int */
int joltffi_fx_bindlike (int fd, void *addr, int len)
{
  if (fd < 0)
    {
      errno = EACCES;
      return -1;
    }
  return fd + len + (addr != NULL ? 1 : 0);
}

/* s26c: (int, int) -> int */
int joltffi_fx_listenlike (int fd, int backlog)
{
  if (fd < 0)
    {
      errno = EBADF;
      return -1;
    }
  return fd * 10 + backlog;
}

/* s26d: (int, int, int, void*, int) -> int */
int joltffi_fx_setsockoptlike (int fd, int lvl, int opt, void *val, int len)
{
  if (fd < 0)
    {
      errno = EBADF;
      return -1;
    }
  return fd + lvl + opt + len + (val != NULL ? 1 : 0);
}

/* s26e: (int, void*, void*) -> int */
int joltffi_fx_getsocknamelike (int fd, void *addr, void *len)
{
  if (fd < 0)
    {
      errno = EBADF;
      return -1;
    }
  return fd + (addr != NULL ? 2 : 0) + (len != NULL ? 3 : 0);
}

/* ---- loader smoke helpers ---------------------------------------------------
   Exported twice (here and in the fixture-2 duplicate library) so the gate can
   pin the duplicate-definers detection: two ADDRESSES, first declared wins. */
int joltffi_fx_dup_symbol (void) { return 111; }

/* Present-but-unloadable: the Makefile links a copy of this library against a
   dependency dylib it then REMOVES from the build dir, so dlopen fails with the
   loader's own preserved reason (a missing dependency, not a missing file). */
int joltffi_fx_never_called (void) { return -2; }

int8_t joltffi_fx_scalar_0(int8_t x) { return x; }

uint8_t joltffi_fx_scalar_1(uint8_t x) { return x; }

int16_t joltffi_fx_scalar_2(int16_t x) { return x; }

uint16_t joltffi_fx_scalar_3(uint16_t x) { return x; }

int32_t joltffi_fx_scalar_4(int32_t x) { return x; }

uint32_t joltffi_fx_scalar_5(uint32_t x) { return x; }

int64_t joltffi_fx_scalar_6(int64_t x) { return x; }

uint64_t joltffi_fx_scalar_7(uint64_t x) { return x; }

size_t joltffi_fx_scalar_8(size_t x) { return x; }

ssize_t joltffi_fx_scalar_9(ssize_t x) { return x; }

float joltffi_fx_scalar_10(float x) { return x; }

double joltffi_fx_scalar_11(double x) { return x; }

void * joltffi_fx_scalar_12(void * x) { return x; }

int joltffi_fx_success_errno(int a, int b, int c) {
  errno = 7777;
  return a + b + c;
}

int joltffi_fx_vsetopt(void *handle, int option, ...) {
  va_list ap;
  va_start(ap, option);
  void *value = va_arg(ap, void *);
  va_end(ap);
  return (handle != NULL) + option + (value != NULL);
}
int joltffi_fx_free_count(void) { return frees; }
