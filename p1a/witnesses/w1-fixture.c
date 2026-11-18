/* W1 fixture — errno-atomicity call shapes.
 *
 * Each w1_*_ptr function is the "typed C shim" of the jolt contract: it
 * performs a target "call" and captures (result, errno) IMMEDIATELY after the
 * target returns, before any cleanup or re-entry (the astra essential
 * sequence). A deliberate post-capture clobber (errno = 7777) inside the shim
 * proves the capture order: the Scheme side must see the captured value, not
 * the clobbered one.
 *
 * The pair travels out of the shim as one malloc'd struct, so the Scheme side
 * reads result and errno from a single allocation — no second read of errno
 * can intervene. A global "last errno" cell would fail the interleaved and
 * threaded iterations; re-reading errno after any cleanup would fail the
 * post-capture clobber.
 */

#include <errno.h>
#include <stdlib.h>
#include <stdio.h>

/* c-define'd in w1-errno.scm */
extern int w1_nested_cb (int x);

typedef struct { int res; int err; } w1_pair;

static int w1_target_a (void) { errno = 0; return -1; }   /* caller maps to EAGAIN */
static int w1_target_b (void) { return 7; }               /* success, errno 42 preserved */
static int w1_target_c (void) { errno = 0; return -2; }   /* caller maps to EACCES */

/* shape A: failure with EAGAIN */
w1_pair *w1_shape_a (void)
{
  int r;
  w1_pair *p;
  errno = 0;
  r = w1_target_a ();
  if (r < 0) errno = EAGAIN;
  p = malloc (sizeof (w1_pair));
  p->res = r;
  p->err = errno;      /* capture immediately after target */
  errno = 7777;        /* deliberate post-capture clobber */
  return p;
}

/* shape B: success that PRESERVES errno = 42 (contract: do not normalize
   success to zero) */
w1_pair *w1_shape_b (void)
{
  int r;
  w1_pair *p;
  errno = 42;
  r = w1_target_b ();
  p = malloc (sizeof (w1_pair));
  p->res = r;
  p->err = errno;      /* capture immediately, success included */
  errno = 7777;
  return p;
}

/* shape C: failure with EACCES */
w1_pair *w1_shape_c (void)
{
  int r;
  w1_pair *p;
  errno = 0;
  r = w1_target_c ();
  if (r < 0) errno = EACCES;
  p = malloc (sizeof (w1_pair));
  p->res = r;
  p->err = errno;
  errno = 7777;
  return p;
}

/* shape D: like C, but the c-lambda body adds an ___AT_END clobber that runs
   AFTER the result conversion — the captured pair must not change. */

/* shape E: nested calls. Captures EIO first, then re-enters Scheme via the
   c-define'd callback w1_nested_cb (which itself performs a nested foreign
   call and clobbers errno through its own shim), then returns the pair
   captured BEFORE the re-entry. A shim that re-read errno after the nested
   call would show the callback's post-clobber value instead of EIO. */
w1_pair *w1_shape_e (void)
{
  w1_pair *p;
  int cb;
  errno = EIO;
  p = malloc (sizeof (w1_pair));
  p->res = -3;
  p->err = errno;      /* capture immediately */
  cb = w1_nested_cb (5);   /* re-enter Scheme; inner shim B runs inside */
  if (cb != 12)        /* callback sanity: must return exactly 12 */
    {
      p->res = -999;
      p->err = cb;
    }
  errno = 7777;        /* deliberate post-capture clobber */
  return p;
}

void w1_free_pair (w1_pair *p) { free (p); }

/* Platform errno values probed by the Scheme side so the assertions hold on
   any OS (EAGAIN/EACCES/EIO differ between macOS and Linux). */
int w1_errno_again (void) { return EAGAIN; }
int w1_errno_acces (void) { return EACCES; }
int w1_errno_io    (void) { return EIO; }
