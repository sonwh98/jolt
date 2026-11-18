/* W3 fixture — raw-pthread entry into Scheme.
 *
 * p1a-r2 REPAIR of review finding F1:
 *   - the exported entries are now TWO-ARGUMENT (scheme_w3_add,
 *     scheme_w3_add_alloc) matching their two-formal Scheme procedures; the
 *     Makefile regenerates with gsc -keep-temp and VERIFIES the generated C
 *     shows ___NARGS 2 for both BEFORE any run (the P1a fixture converted
 *     one argument for two-formal procedures, so its 3/3 SIGSEGVs
 *     reproduced a malformed entry fixture). scheme_w3_phase3 is now
 *     declared void-arg consistent with the generated ()-formal entry.
 *   - an OWNER-THREAD CONTROL runs BEFORE any foreign-thread phase in every
 *     mode: the Gambit thread that ran ___setup drives the SAME c-define
 *     entries with exact expected values. A wrong value aborts the run.
 *   - verdict semantics: a worker that completes with correct values is
 *     REFUSAL-NOT-REPRODUCED (undocumented serialized reuse — NEVER
 *     qualification); wrong values are UNSAFE-ENTRY-OBSERVED; fatal exits
 *     (70 = Gambit fatal, 134/138/139 = SIGABRT/SIGBUS/SIGSEGV) are all the
 *     DOCUMENTED REFUSAL-FAILURE — unsafe entry — and none is ever a
 *     success.
 *
 * Build (the manual's documented "Scheme server" pattern, tests/makefile.in:166):
 *   gsc -exe -cc-options "-D___LIBRARY" -o w3.exe w3-fthread.c w3-server.scm
 *
 * Run one phase per process so a crash in one phase cannot erase the
 * evidence of another (each run is watchdogged by the Makefile; the
 * owner-thread control runs first inside every mode):
 *
 *   ./w3.exe control          owner-thread control only (must exit 0)
 *   ./w3.exe phase1           serialized entry, heartbeat ON (default runtime)
 *   ./w3.exe phase1-nobeat    serialized entry, heartbeat DISABLED during the
 *                             worker run (undocumented ___set_heartbeat_interval,
 *                             lib/os_time.c:937 — used ONLY to isolate the
 *                             cause of the phase1 crash)
 *   ./w3.exe phase2           concurrent entry: worker pthread calls Scheme
 *                             WHILE the primordial thread runs Scheme
 *   ./w3.exe phase3           owner Gambit thread parked inside a cfun call
 *                             while the worker enters — the shape under
 *                             which W4-M4's callback survived
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

/* OWNER-THREAD CONTROL: the Gambit thread that ran ___setup drives the SAME
   c-define entries the worker will use. This must succeed BEFORE any
   foreign-thread phase; a wrong value aborts the run (exit 1). */
static int w3_control (void)
{
  int r1, r2, g;
  int fail = 0;

  printf ("W3-CONTROL: owner-thread callbacks through the SAME c-define entries the worker will use\n");
  fflush (stdout);
  r1 = scheme_w3_add (20, 22);
  printf ("W3-CONTROL: scheme_w3_add(20,22) = %d (expected 42)\n", r1);
  fflush (stdout);
  if (r1 != 42)
    fail = 1;
  r2 = scheme_w3_add_alloc (50, 22);
  printf ("W3-CONTROL: scheme_w3_add_alloc(50,22) = %d (expected 1072)\n", r2);
  fflush (stdout);
  if (r2 != 1072)
    fail = 1;
  g = scheme_w3_gc_rounds (2);
  printf ("W3-CONTROL: scheme_w3_gc_rounds(2) = %d (expected 2; real collections on the owner thread)\n", g);
  fflush (stdout);
  if (g != 2)
    fail = 1;
  printf ("W3-CONTROL-VERDICT: %s\n",
          fail
            ? "FAIL (wrong values on the owner thread — ABORTING before any foreign-thread phase)"
            : "PASS (owner Gambit thread drives the same c-define entries with correct values before any foreign-thread phase)");
  fflush (stdout);
  return fail;
}

static void *w3_worker_serialized (void *arg)
{
  int i, r, g;
  (void) arg;
  /* discriminator FIRST: the allocating shape (W4-M4's callback body) entered
     exactly like the trivial add. */
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
  return (void *) (long) (bad > 0 ? 1 : 0);
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
  int worker_ret;

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
  worker_ret = (int) (long) ret;

  if (disable_heartbeat)
    ___set_heartbeat_interval (saved_beat);

  printf ("W3-PHASE1: worker joined, exit=%d\n", worker_ret);
  fflush (stdout);
  /* p1a-r2 verdict semantics: survival is NEVER a pass. */
  printf ("W3-PHASE1-VERDICT: %s\n",
          worker_ret == 0
            ? "REFUSAL-NOT-REPRODUCED (worker survived with correct values — undocumented serialized reuse of the single pstate; a nondeterminism caveat, NEVER qualification of foreign-thread entry)"
            : "UNSAFE-ENTRY-OBSERVED (worker entered but produced wrong values — corruption of the shared single pstate)");
  fflush (stdout);
  return worker_ret == 0 ? 0 : 2;
}

static int w3_phase2 (void)
{
  void *ret = 0;
  int spin;
  int worker_ret;

  printf ("W3-PHASE2: spawning raw pthread WHILE primordial runs scheme_w3_spin\n");
  fflush (stdout);
  spin = scheme_w3_spin (3000);   /* spawns worker, then allocates ~3s */
  pthread_join (w3_tid, &ret);
  worker_ret = (int) (long) ret;
  printf ("W3-PHASE2: primordial survived scheme_w3_spin (allocs=%d), worker joined exit=%d\n",
          spin, worker_ret);
  fflush (stdout);
  printf ("W3-PHASE2-VERDICT: %s\n",
          worker_ret == 0
            ? "REFUSAL-NOT-REPRODUCED (concurrent entry survived this run — two threads shared one pstate; nondeterminism caveat, NEVER qualification; exit 70 and 139 are both the documented refusal-failure)"
            : "UNSAFE-ENTRY-OBSERVED (concurrent entry produced wrong values — corruption of the shared single pstate)");
  fflush (stdout);
  return worker_ret == 0 ? 0 : 2;
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
            ? "REFUSAL-NOT-REPRODUCED (worker entry survived with owner parked in a cfun frame — undocumented serialized reuse; a nondeterminism caveat, NEVER qualification)"
            : "UNSAFE-ENTRY-OBSERVED (worker entered but produced wrong values — corruption of the shared single pstate)");
  fflush (stdout);
  return r == 0 ? 0 : 2;
}

int main (int argc, char **argv)
{
  const char *phase = (argc > 1) ? argv[1] : "all";
  int phase_exit = 0;

  w3_setup_runtime ();

  /* the owner-thread control MUST succeed before ANY foreign-thread phase */
  if (w3_control () != 0)
    {
      printf ("W3: control failed — no foreign-thread phase run\n");
      fflush (stdout);
      ___cleanup ();
      return 1;
    }

  if (strcmp (phase, "control") == 0)
    phase_exit = 0;   /* control-only mode: stop here, exit 0 */
  else if (strcmp (phase, "phase1") == 0)
    phase_exit = w3_phase1 (0);
  else if (strcmp (phase, "phase1-nobeat") == 0)
    phase_exit = w3_phase1 (1);
  else if (strcmp (phase, "phase2") == 0)
    phase_exit = w3_phase2 ();
  else if (strcmp (phase, "phase3") == 0)
    phase_exit = w3_phase3 ();
  else /* "all": manual diagnostic only; the recorded runs use one phase per
          process so a crash cannot erase another phase's evidence */
    {
      phase_exit = w3_phase1 (0);
      if (phase_exit == 0)
        phase_exit = w3_phase1 (1);
      if (phase_exit == 0)
        phase_exit = w3_phase2 ();
      if (phase_exit == 0)
        phase_exit = w3_phase3 ();
    }

  printf ("W3: calling ___cleanup\n");
  fflush (stdout);
  ___cleanup ();
  printf ("W3: ___cleanup returned\n");
  fflush (stdout);
  return phase_exit;
}
