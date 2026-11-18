/* W2 fixture — the blocking-call shape with an OBSERVABLE release handshake.
 *
 * p1a-r2 REPAIR of review finding F3 (the P1a handshake existed in C but was
 * never called from Scheme, and the witness printed its verdict
 * unconditionally).
 *
 * w2_block blocks on a handshake that ONLY a call to w2_release_handshake()
 * can end early; a C-side deadline bounds the block so a build that cannot
 * release converts what is otherwise a permanent deadlock into structured
 * evidence. The external watchdog (watchdog.sh) is the second line of
 * defense and its exit 124 is an INDEPENDENT timeout detection — always a
 * recorded failure.
 *
 * Everything the Scheme witness needs to DERIVE its verdict from observed
 * state (never an unconditional print) is exported:
 *   w2_block(deadline)  returns the OBSERVED release cause:
 *                         0 = released by a w2_release_handshake() call,
 *                         1 = the C-side deadline fired first
 *   w2_release_handshake()  counts its calls and whether any arrived while
 *                           the wait was still active (w2_handshake_calls,
 *                           w2_handshake_during_block)
 *   w2_in_block_p()     the live in-block flag, so the Scheme side can
 *                       observe "round started while C was blocked" directly
 *                       from the C fixture's own state
 *   w2_block_blocked_ms()  how long the block actually lasted
 *
 * The real collection used by the witness goes through the documented runtime
 * API gambit.h:14772-14774:
 *   ___IMP_FUNC(___BOOL,___garbage_collect)
 *      ___P((___PSD ___SIZE_TS requested_words_still),());
 */

#include <stdio.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>

static pthread_mutex_t w2_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  w2_cv = PTHREAD_COND_INITIALIZER;
static int w2_proceed = 0;
static int w2_wait_active = 0;
static int w2_in_block = 0;
static int w2_handshake_calls = 0;
static int w2_handshake_during_block = 0;
static long w2_blocked_ms = 0;

int w2_block (int deadline_seconds)
{
  struct timespec ts;
  struct timespec t0, t1;
  int cause = 1;   /* deadline, unless a handshake ends the wait */

  clock_gettime (CLOCK_MONOTONIC, &t0);
  clock_gettime (CLOCK_REALTIME, &ts);
  ts.tv_sec += deadline_seconds;

  w2_in_block = 1;
  fprintf (stdout, "W2C: foreign call ENTERED, blocking on handshake (deadline %ds)\n",
           deadline_seconds);
  fflush (stdout);

  pthread_mutex_lock (&w2_mu);
  w2_wait_active = 1;
  while (!w2_proceed)
    {
      int r = pthread_cond_timedwait (&w2_cv, &w2_mu, &ts);
      if (r == ETIMEDOUT)
        break;
    }
  if (w2_proceed)
    cause = 0;
  w2_wait_active = 0;
  pthread_mutex_unlock (&w2_mu);

  w2_in_block = 0;
  clock_gettime (CLOCK_MONOTONIC, &t1);
  w2_blocked_ms = (long) (t1.tv_sec - t0.tv_sec) * 1000
                + (t1.tv_nsec - t0.tv_nsec) / 1000000;

  fprintf (stdout, "W2C: foreign call RETURNING (cause=%s, blocked %ldms)\n",
           cause == 0 ? "handshake" : "deadline", w2_blocked_ms);
  fflush (stdout);
  return cause;
}

/* The release handshake. Called FROM SCHEME (via c-lambda) in the qualify
   mode — the qualification design releases C only after the contender has
   completed a REAL collection; on a build where the contender cannot run
   while C is blocked, the handshake provably cannot arrive during the block,
   which is exactly what the counters record. */
void w2_release_handshake (void)
{
  pthread_mutex_lock (&w2_mu);
  w2_handshake_calls++;
  if (w2_wait_active)
    w2_handshake_during_block++;
  w2_proceed = 1;
  pthread_cond_broadcast (&w2_cv);
  pthread_mutex_unlock (&w2_mu);
}

int w2_handshake_calls_total (void) { return w2_handshake_calls; }
int w2_handshake_during_block_total (void) { return w2_handshake_during_block; }
int w2_in_block_p (void) { return w2_in_block; }
int w2_block_blocked_ms (void) { return (int) w2_blocked_ms; }

int w2_noblock (void)
{
  fprintf (stdout, "W2C: non-blocking foreign call entered+returned\n");
  fflush (stdout);
  return 1;
}
