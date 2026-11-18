/* W2MT fixture — blocking-call shape with a C-side completion handshake.
 *
 * Differences from the P1a W2 fixture (all required by the codex review, F3):
 *
 *   - w2mt_block returns HOW the blocked interval ended:
 *       0 = released by the handshake (w2mt_release_handshake), meaning all
 *           of B's GC rounds completed WHILE C was blocked;
 *       1 = the C-side deadline fired (independent timeout detection);
 *       2 = unexpected.
 *     This makes the verdict derivable from observed state, not printed
 *     unconditionally.
 *
 *   - w2mt_block sets w2mt_a_inside_c (atomic) BEFORE blocking, so thread B
 *     can poll (via w2mt_a_inside_p, a NON-blocking foreign call) and only
 *     start its real-GC rounds once A is provably inside C.
 *
 *   - w2mt_release_handshake is actually called — by B, and only AFTER B has
 *     completed every GC round and updated the live rooted objects.
 *
 *   - All timestamps are CLOCK_MONOTONIC seconds, printed flushed, so the
 *     ordering of C-fixture prints and Scheme prints is exact in the record.
 *
 * The real collection used by the witness goes through the documented runtime
 * API (gambit.h):
 *   ___IMP_FUNC(___BOOL,___garbage_collect)
 *      ___P((___PSD ___SIZE_TS requested_words_still),());
 */

#include <stdio.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>

static pthread_mutex_t w2mt_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  w2mt_cv = PTHREAD_COND_INITIALIZER;
static int w2mt_proceed = 0;
static atomic_int w2mt_a_inside_c = 0;

static double w2mt_now (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (double) ts.tv_sec + 1e-9 * (double) ts.tv_nsec;
}

int w2mt_block (int deadline_seconds)
{
  struct timespec ts;
  int result = 2;
  double t_enter;

  clock_gettime (CLOCK_REALTIME, &ts);   /* pthread_cond_timedwait needs realtime */
  ts.tv_sec += deadline_seconds;

  t_enter = w2mt_now ();
  atomic_store (&w2mt_a_inside_c, 1);

  fprintf (stdout, "W2MTC: t=%.6f foreign call ENTERED, blocking on handshake (deadline %ds)\n",
           t_enter, deadline_seconds);
  fflush (stdout);

  pthread_mutex_lock (&w2mt_mu);
  while (!w2mt_proceed)
    {
      int r = pthread_cond_timedwait (&w2mt_cv, &w2mt_mu, &ts);
      if (r == ETIMEDOUT)
        break;
    }
  if (w2mt_proceed)
    result = 0;
  else
    result = 1;   /* deadline fired: independent timeout detection */
  pthread_mutex_unlock (&w2mt_mu);

  fprintf (stdout, "W2MTC: t=%.6f foreign call RETURNING, reason=%d (%s)\n",
           w2mt_now (), result,
           result == 0 ? "released-by-handshake"
           : result == 1 ? "C-side-deadline (B did NOT complete its rounds in time)"
           : "unexpected");
  fflush (stdout);
  return result;
}

void w2mt_release_handshake (void)
{
  pthread_mutex_lock (&w2mt_mu);
  w2mt_proceed = 1;
  pthread_cond_broadcast (&w2mt_cv);
  pthread_mutex_unlock (&w2mt_mu);
  fprintf (stdout, "W2MTC: t=%.6f handshake released by B\n", w2mt_now ());
  fflush (stdout);
}

int w2mt_a_inside_p (void)
{
  return atomic_load (&w2mt_a_inside_c);
}

int w2mt_noblock (void)
{
  return 1;
}
