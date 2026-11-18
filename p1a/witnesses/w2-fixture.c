/* W2 fixture — the blocking-call shape.
 *
 * w2_block announces entry on stdout (flushed), then blocks on a handshake
 * that NO Scheme thread can perform while this foreign call occupies the
 * only processor of the provisioned single-threaded-VMS build. A C-side
 * deadline converts what is otherwise a permanent deadlock into structured
 * evidence; the external watchdog (watchdog.sh) is the second line of
 * defense.
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

int w2_block (int deadline_seconds)
{
  struct timespec ts;
  clock_gettime (CLOCK_REALTIME, &ts);
  ts.tv_sec += deadline_seconds;

  fprintf (stdout, "W2C: foreign call ENTERED, blocking on handshake (deadline %ds)\n",
           deadline_seconds);
  fflush (stdout);

  pthread_mutex_lock (&w2_mu);
  while (!w2_proceed)
    {
      int r = pthread_cond_timedwait (&w2_cv, &w2_mu, &ts);
      if (r == ETIMEDOUT)
        break;
    }
  pthread_mutex_unlock (&w2_mu);

  fprintf (stdout, "W2C: foreign call RETURNING after blocked interval\n");
  fflush (stdout);
  return 1;
}

void w2_release_handshake (void)
{
  pthread_mutex_lock (&w2_mu);
  w2_proceed = 1;
  pthread_cond_broadcast (&w2_cv);
  pthread_mutex_unlock (&w2_mu);
}

int w2_noblock (void)
{
  fprintf (stdout, "W2C: non-blocking foreign call entered+returned\n");
  fflush (stdout);
  return 1;
}
