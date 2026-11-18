/* W1 fixture — errno-atomicity call shapes.
 *
 * p1a-r2 REPAIR of review finding F2 (the P1a shims read errno AFTER malloc
 * and shapes A/C manufactured the expected errno after the "target" returned,
 * which cannot qualify capture-before-allocation).
 *
 * EVERY shim below follows the astra essential sequence exactly:
 *
 *   target call  ->  int saved = errno;   IMMEDIATELY, before ANY
 *                 ->  malloc / conversion / cleanup / Scheme re-entry
 *                 ->  the pair travels out as one malloc'd struct
 *
 * The TARGETS own their errno (like real syscalls) — the shims never
 * manufacture one after the fact:
 *   w1_target_a sets EAGAIN itself and returns -1 (failure);
 *   w1_target_c sets EACCES itself and returns -2 (failure);
 *   w1_target_b is a SUCCESS that must preserve the caller's errno = 42
 *   (contract: do not normalize success to zero).
 *
 * Capture-order negative controls (the reviewer's required addition —
 * capture position must be load-bearing, i.e. observable):
 *   shape F: an intervening clobber (errno = W1_INTERVENING_CLOBBER) is
 *            written BETWEEN the target call and the use of the captured
 *            value; the immediate capture MUST defeat it — the Scheme side
 *            asserts the TARGET's errno, never the clobber.
 *   shape G: a deliberately WRONG shim that captures AFTER the intervening
 *            clobber; the witness asserts it yields the CLOBBERED value.
 *            This proves the assertions can distinguish capture order at
 *            all: a harness in which G also reported the target's errno
 *            would be insensitive, and the immediate-capture shapes would
 *            not be load-bearing.
 *
 * The pair travels out of the shim as one malloc'd struct, so the Scheme
 * side reads result and errno from a single allocation — no second read of
 * errno can intervene. A global "last errno" cell would fail the interleaved
 * and threaded iterations; re-reading errno after any cleanup would fail the
 * post-capture clobber; capturing after malloc (the F2 defect) would fail
 * shape F's intervening clobber whenever malloc touches errno.
 */

#include <errno.h>
#include <stdlib.h>
#include <stdio.h>

/* c-define'd in w1-errno.scm */
extern int w1_nested_cb (int x);

#define W1_INTERVENING_CLOBBER 4242
#define W1_POST_CAPTURE_CLOBBER 7777

typedef struct { int res; int err; } w1_pair;

static int w1_target_a (void) { errno = EAGAIN; return -1; }  /* failure: target's OWN errno */
static int w1_target_b (void) { return 7; }                   /* success: errno 42 preserved */
static int w1_target_c (void) { errno = EACCES; return -2; }  /* failure: target's OWN errno */

/* shape A: failure; the target's real EAGAIN must survive allocation */
w1_pair *w1_shape_a (void)
{
  int r;
  int saved;
  w1_pair *p;
  errno = 0;
  r = w1_target_a ();
  saved = errno;                    /* capture IMMEDIATELY after the target */
  p = malloc (sizeof (w1_pair));    /* allocation AFTER capture */
  p->res = r;
  p->err = saved;
  errno = W1_POST_CAPTURE_CLOBBER;  /* deliberate post-capture clobber */
  return p;
}

/* shape B: success that PRESERVES errno = 42 (contract: do not normalize
   success to zero); capture still immediately after the target */
w1_pair *w1_shape_b (void)
{
  int r;
  int saved;
  w1_pair *p;
  errno = 42;
  r = w1_target_b ();
  saved = errno;                    /* capture IMMEDIATELY, success included */
  p = malloc (sizeof (w1_pair));
  p->res = r;
  p->err = saved;
  errno = W1_POST_CAPTURE_CLOBBER;
  return p;
}

/* shape C: failure; the target's real EACCES must survive allocation */
w1_pair *w1_shape_c (void)
{
  int r;
  int saved;
  w1_pair *p;
  errno = 0;
  r = w1_target_c ();
  saved = errno;                    /* capture IMMEDIATELY after the target */
  p = malloc (sizeof (w1_pair));
  p->res = r;
  p->err = saved;
  errno = W1_POST_CAPTURE_CLOBBER;
  return p;
}

/* shape D: like C, but the c-lambda body adds an ___AT_END clobber that runs
   AFTER the result conversion — the captured pair must not change. */

/* shape E: nested calls. Captures EIO BEFORE any allocation and BEFORE the
   re-entry into Scheme via the c-define'd callback w1_nested_cb (which
   itself performs a nested foreign call and clobbers errno through its own
   shim), then returns the pair captured BEFORE the re-entry. A shim that
   allocated first or re-read errno after the nested call would show the
   callback's post-clobber value instead of EIO. */
w1_pair *w1_shape_e (void)
{
  w1_pair *p;
  int saved;
  int cb;
  errno = EIO;
  saved = errno;                    /* capture IMMEDIATELY, before ANY malloc */
  p = malloc (sizeof (w1_pair));
  p->res = -3;
  p->err = saved;
  cb = w1_nested_cb (5);            /* re-enter Scheme; inner shim B runs inside */
  if (cb != 12)                     /* callback sanity: must return exactly 12 */
    {
      p->res = -999;
      p->err = cb;
    }
  errno = W1_POST_CAPTURE_CLOBBER;  /* deliberate post-capture clobber */
  return p;
}

/* shape F: intervening-clobber negative control (GOOD order). The clobber
   lands BETWEEN the target call and the use of the captured value; the
   immediate capture defeats it. */
w1_pair *w1_shape_f (void)
{
  int r;
  int saved;
  w1_pair *p;
  errno = 0;
  r = w1_target_a ();
  saved = errno;                    /* immediate capture ... */
  errno = W1_INTERVENING_CLOBBER;   /* ... defeats this intervening clobber */
  p = malloc (sizeof (w1_pair));
  p->res = r;
  p->err = saved;                   /* the TARGET's errno, never the clobber */
  errno = W1_POST_CAPTURE_CLOBBER;
  return p;
}

/* shape G: intervening-clobber negative control (deliberately WRONG order —
   captures AFTER the clobber). The witness asserts this shim reports the
   CLOBBERED value: proof that the assertions distinguish capture order. */
w1_pair *w1_shape_g (void)
{
  int r;
  int saved;
  w1_pair *p;
  errno = 0;
  r = w1_target_a ();
  errno = W1_INTERVENING_CLOBBER;   /* intervening clobber ... */
  saved = errno;                    /* ... captured AFTER it (wrong order) */
  p = malloc (sizeof (w1_pair));
  p->res = r;
  p->err = saved;                   /* the clobber leaks in — by design */
  return p;
}

void w1_free_pair (w1_pair *p) { free (p); }

/* Platform errno values probed by the Scheme side so the assertions hold on
   any OS (EAGAIN/EACCES/EIO differ between macOS and Linux), plus the
   intervening-clobber constant so the negative-control assertion compares
   against the C-declared value, not a Scheme-side magic number. */
int w1_errno_again (void) { return EAGAIN; }
int w1_errno_acces (void) { return EACCES; }
int w1_errno_io    (void) { return EIO; }
int w1_intervening_clobber (void) { return W1_INTERVENING_CLOBBER; }
