/* W7 fixture — foreign pthread entering Scheme through scm_with_guile.
 *
 * Manual §5.2.1 "Guile Initialization Functions" documents scm_with_guile
 * as "the most portable way to initialize Guile... Multiple threads can
 * call scm_with_guile concurrently and it can also be called more than
 * once in a given thread."
 *
 * good mode (default): two pthreads enter Scheme CONCURRENTLY through
 *   scm_with_guile, each evaluating a Scheme lambda applied to its own
 *   argument, printing W7-FIXTURE-ENTRY-OK lines with the results.
 * bad mode (argv[1] == "bad"): a pthread calls libguile directly WITHOUT
 *   attaching through scm_with_guile — the p1a/Gambit-style refusal probe;
 *   any outcome (crash, corruption, accidental success) is recorded by the
 *   driver as evidence, never as a pass.
 */

#include <libguile.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

static SCM addfn = SCM_BOOL_F;

static void *worker_body (void *data)
{
  long id = (long) data;
  SCM r = scm_call_1 (addfn, scm_from_long (id));
  printf ("W7-FIXTURE-ENTRY-OK thread=%ld result=%ld\n",
          id, (long) scm_to_long (r));
  fflush (stdout);
  return NULL;
}

struct arg
{
  long id;
};

static void *thread_trampoline (void *ap)
{
  struct arg *a = ap;
  return scm_with_guile (worker_body, (void *) a->id);
}

static void *bad_body (void *data)
{
  (void) data;
  /* Raw entry: NO scm_with_guile attachment. */
  SCM r = scm_c_eval_string ("(+ 1 2)");
  printf ("W7-FIXTURE-BAD-RETURNED result=%ld\n", (long) scm_to_long (r));
  fflush (stdout);
  return NULL;
}

static void *main_body_good (void *unused)
{
  (void) unused;
  addfn = scm_c_eval_string ("(lambda (x) (+ x 40))");
  pthread_t t1, t2;
  struct arg a1 = { 1 }, a2 = { 2 };
  pthread_create (&t1, NULL, thread_trampoline, &a1);
  pthread_create (&t2, NULL, thread_trampoline, &a2);
  pthread_join (t1, NULL);
  pthread_join (t2, NULL);
  printf ("W7-FIXTURE-VERDICT: PASS\n");
  fflush (stdout);
  return NULL;
}

static void *main_body_bad (void *unused)
{
  (void) unused;
  pthread_t t;
  pthread_create (&t, NULL, bad_body, NULL);
  pthread_join (t, NULL);
  printf ("W7-FIXTURE-BAD-SURVIVED\n");
  fflush (stdout);
  return NULL;
}

int main (int argc, char **argv)
{
  if (argc > 1 && strcmp (argv[1], "bad") == 0)
    {
      scm_with_guile (main_body_bad, NULL);
      printf ("W7-FIXTURE-BAD-MAIN-SURVIVED\n");
    }
  else
    scm_with_guile (main_body_good, NULL);
  return 0;
}
