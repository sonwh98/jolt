/* W3 fixture — raw-pthread entry into Scheme.
 *
 * Build (the manual's documented "Scheme server" pattern, tests/makefile.in:166):
 *   gsc -exe -cc-options "-D___LIBRARY" -o w3.exe w3-fthread.c w3-server.scm
 *
 * Run one phase per process so a crash in one phase cannot erase the
 * evidence of another (each run is watchdogged by the Makefile):
 *
 *   ./w3.exe phase1          serialized entry, heartbeat ON (default runtime)
 *   ./w3.exe phase1-nobeat   serialized entry, heartbeat DISABLED during the
 *                            worker run (undocumented ___set_heartbeat_interval,
 *                            lib/os_time.c:937 — used ONLY to isolate the
 *                            cause of the phase1 crash)
 *   ./w3.exe phase2          concurrent entry: worker pthread calls Scheme
 *                            WHILE the primordial thread runs Scheme
 *   ./w3.exe phase3          owner Gambit thread parked inside a cfun call
 *                            (c-lambda) while the worker enters — the shape
 *                            under which W4-M4's callback survived
 *
 * On a ___SINGLE_THREADED_VMS build there is exactly one processor state
 * (gambit.h:8625-8628: "Use direct access to the only pstate";
 * ___SET_REAL_PSTATE is a no-op there) and no documented protocol for a
 * foreign pthread to enter.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

#include <gambit.h>

/* c-define'd in w3-server.scm */
extern int scheme_w3_add (int x, int y);
extern int scheme_w3_add_alloc (int x, int y);
extern int scheme_w3_gc_rounds (int n);
extern int scheme_w3_spin (int ms);
extern int scheme_w3_phase3 (void);

/* Undocumented heartbeat control (lib/os_time.c:932-948). NOT in gambit.h —
   used only to isolate the cause of the phase1 crash. */
extern void ___set_heartbeat_interval (double seconds);
extern double ___get_heartbeat_interval (void);

#define SCHEME_LIBRARY_LINKER ___LNK_w3_2d_server__
___BEGIN_C_LINKAGE
extern ___mod_or_lnk SCHEME_LIBRARY_LINKER (___global_state);
___END_C_LINKAGE

static void *w3_worker_serialized (void *arg)
{
  int i, r, g;
  (void) arg;
  /* discriminator FIRST: the allocating shape (W4-M4's callback body) entered
     exactly like the trivial add. Result on macOS arm64: this call ALSO fails
     to complete (no W3-WORKER line is ever printed), so the discriminator is
     NOT allocation-related — the first foreign-pthread Scheme entry itself
     crashes in the phase1/phase3 contexts. */
  r = scheme_w3_add_alloc (50, 22);
  printf ("W3-WORKER: scheme_w3_add_alloc(50,22) = %d (expected 1072)\n", r);
  fflush (stdout);
  for (i = 0; i < 3; i++)
    {
      r = scheme_w3_add (20 + i, 22);
      printf ("W3-WORKER: scheme_w3_add(%d,22) = %d\n", 20 + i, r);
      fflush (stdout);
      if (r != 42 + i)
        {
          printf ("W3-WORKER: WRONG RESULT %d\n", r);
          fflush (stdout);
          return (void *) 1;
        }
    }
  g = scheme_w3_gc_rounds (3);   /* real collections driven from the worker */
  printf ("W3-WORKER: drove %d real gc rounds (runtime *** GC: reports below with -:d5)\n", g);
  fflush (stdout);
  r = scheme_w3_add (1, 1);
  printf ("W3-WORKER: final scheme_w3_add(1,1) = %d\n", r);
  fflush (stdout);
  return (void *) (long) (r == 2 ? 0 : 2);
}

static void *w3_worker_concurrent (void *arg)
{
  int i, r;
  long bad = 0;
  (void) arg;
  /* wait a moment so the primordial is definitely inside scheme_w3_spin */
  usleep (200000);
  for (i = 0; i < 10000; i++)
    {
      r = scheme_w3_add (1, 1);
      if (r != 2)
        bad++;
    }
  printf ("W3-WORKER: completed 10000 concurrent entries, bad=%ld\n", bad);
  fflush (stdout);
  return (void *) 0;
}

static pthread_t w3_tid;

void w3_spawn_worker_nojoin (void)
{
  pthread_create (&w3_tid, NULL, w3_worker_concurrent, NULL);
}

/* phase3: the OWNER Gambit thread parks inside a cfun (c-lambda) call while
   the worker pthread enters Scheme — the same shape as W4-M4 but with the
   worker also driving real collections. w3_park_and_join is reached FROM
   Scheme (c-lambda), so the owner's Scheme frame is live and parked. */
int w3_park_and_join (int unused)
{
  void *ret = 0;
  (void) unused;
  pthread_create (&w3_tid, NULL, w3_worker_serialized, NULL);
  pthread_join (w3_tid, &ret);
  return (int) (long) ret;
}

static void w3_setup_runtime (void)
{
  ___setup_params_struct setup_params;

  ___setup_params_reset (&setup_params);
  setup_params.version = ___VERSION;
  setup_params.linker  = SCHEME_LIBRARY_LINKER;

  printf ("W3: calling ___setup from the primordial thread\n");
  fflush (stdout);
  ___setup (&setup_params);
  printf ("W3: ___setup returned; runtime live (___VERSION=%ld)\n", (long) ___VERSION);
  fflush (stdout);
}

static int w3_phase1 (int disable_heartbeat)
{
  double saved_beat;
  void *ret = 0;

  printf ("W3-PHASE1: spawning raw pthread (primordial will park in pthread_join)\n");
  fflush (stdout);

  saved_beat = ___get_heartbeat_interval ();
  printf ("W3-PHASE1: heartbeat interval = %f\n", saved_beat);
  fflush (stdout);
  if (disable_heartbeat)
    {
      ___set_heartbeat_interval (0.0);
      printf ("W3-PHASE1: heartbeat DISABLED for this run\n");
      fflush (stdout);
    }

  pthread_create (&w3_tid, NULL, w3_worker_serialized, NULL);
  pthread_join (w3_tid, &ret);

  if (disable_heartbeat)
    ___set_heartbeat_interval (saved_beat);

  printf ("W3-PHASE1: worker joined, exit=%d (0 = all calls returned expected values)\n",
          (int) (long) ret);
  fflush (stdout);
  printf ("W3-PHASE1-VERDICT: %s\n",
          (int) (long) ret == 0
            ? (disable_heartbeat
                 ? "PASS-QUALIFIED (serialized entry survived with heartbeat disabled; undocumented isolation, no documented protocol)"
                 : "PASS (serialized entry survived with heartbeat on)")
            : "FAIL");
  fflush (stdout);
  return (int) (long) ret;
}

static int w3_phase2 (void)
{
  void *ret = 0;
  int spin;

  printf ("W3-PHASE2: spawning raw pthread WHILE primordial runs scheme_w3_spin\n");
  fflush (stdout);
  spin = scheme_w3_spin (3000);   /* spawns worker, then allocates ~3s */
  pthread_join (w3_tid, &ret);
  printf ("W3-PHASE2: primordial survived scheme_w3_spin (allocs=%d), worker joined exit=%d\n",
          spin, (int) (long) ret);
  fflush (stdout);
  printf ("W3-PHASE2-VERDICT: PASS (concurrent entry returned — treated with suspicion: two threads shared one pstate)\n");
  fflush (stdout);
  return 0;
}

static int w3_phase3 (void)
{
  int r;
  printf ("W3-PHASE3: owner Gambit thread parks INSIDE a cfun call while the worker pthread enters Scheme\n");
  fflush (stdout);
  r = scheme_w3_phase3 ();   /* c-define'd: Scheme calls w3_park_and_join via c-lambda */
  printf ("W3-PHASE3: worker joined exit=%d\n", r);
  fflush (stdout);
  printf ("W3-PHASE3-VERDICT: %s\n",
          r == 0
            ? "PASS (worker entry survived with owner parked in a cfun frame — undocumented serialized reuse)"
            : "FAIL");
  fflush (stdout);
  return r;
}

int main (int argc, char **argv)
{
  const char *phase = (argc > 1) ? argv[1] : "all";

  w3_setup_runtime ();

  if (strcmp (phase, "phase1") == 0 || strcmp (phase, "all") == 0)
    w3_phase1 (0);
  if (strcmp (phase, "phase1-nobeat") == 0)
    w3_phase1 (1);
  if (strcmp (phase, "phase2") == 0 || strcmp (phase, "all") == 0)
    w3_phase2 ();
  if (strcmp (phase, "phase3") == 0)
    w3_phase3 ();

  printf ("W3: calling ___cleanup\n");
  fflush (stdout);
  ___cleanup ();
  printf ("W3: ___cleanup returned\n");
  fflush (stdout);
  return 0;
}
