/* W3MT fixture — foreign-pthread entry into Scheme on the MULTITHREADED-VM
 * 4.9.8 build (codex review step 4 experiment).
 *
 * Build (the manual's documented "Scheme server" pattern):
 *   gsc -exe -cc-options "-D___LIBRARY" -o w3mt.exe w3mt-main.c w3mt-server.scm
 *
 * Explicit parallelism (review step 2 requirement, applied to the server
 * pattern): the driver sets setup_params.parallelism_level = 2 — the
 * library-program equivalent of the gsi/gsc driver's -:p2 (main.c:46-49
 * parses -:p into setup_params.parallelism_level; setup.c consumes it).
 * GC-report verbosity (-:d5 equivalent) is set via debug_settings = 85
 * (level 5 | uncaught-all | error-quit), so real collections print the
 * runtime's own "*** GC:" reports.
 *
 * W3MT does NOT reuse the P1a W3 thunk-resize trick; the runtime's parallelism
 * comes from normal startup (___setup), never (##current-vm-resize ...).
 *
 * Phases (each run in its own process, under the external watchdog, so a
 * crash in one phase cannot erase the evidence of another):
 *
 *   owner    CONTROL (review F1 correction): the OS thread that ran ___setup
 *            — whose TLS is bound to processor 0 by ___setup itself
 *            (setup.c:6383-6406) — round-trips C -> Scheme -> C through the
 *            SAME entry points used later by the foreign pthread:
 *            scheme_w3mt_add (trivial), scheme_w3mt_add_alloc (allocates),
 *            scheme_w3mt_gc_rounds (real collections). This control must pass
 *            FIRST; the (int int) signatures are verified against the
 *            generated C (results/w3mt-generated-signatures.txt).
 *
 *   p1       serialized naive entry: raw pthread (never created by the
 *            runtime, never registered) calls scheme_w3mt_add while the
 *            owner thread parks in pthread_join. On this MT build the raw
 *            pthread's TLS pstate is NULL (gambit.h:8607-8612 vs 8645-8685:
 *            ___GET_REAL_PSTATE reads the thread-local ___tls_ptr, set only
 *            by ___thread_set_pstate — called exclusively at setup.c:6402
 *            for the primordial and setup.c:819 for runtime-created
 *            processors). Expected: crash on first Scheme entry.
 *
 *   p2       concurrent naive entry: raw pthread calls scheme_w3mt_add WHILE
 *            the owner thread runs Scheme (scheme_w3mt_spin allocates ~3s).
 *            Expected: crash/corruption (unregistered thread, NULL TLS).
 *
 *   bridge   BEST-EFFORT ATTACH BRIDGE (undocumented — every ingredient is
 *            cited; this is the review's demanded experiment: does the
 *            exported surface make foreign entry valid?):
 *            from the worker pthread, in order:
 *              1. read TLS pstate (expect NULL)              [TLS]
 *              2. vms = &___GSTATE->vmstate0; slot = vms->processor_count
 *                 (membership is the aligned_pstate[] ARRAY POSITION:
 *                 gambit.h:11966-11973 ___PROCESSOR_ID / 11934-11936;
 *                 ___setup_pstate does NOT touch processor_count —
 *                 setup.c:940-958 does that via OP_SET_PROCESSOR_COUNT
 *                 barrier_sync_op instead, setup.c:958-963)
 *              3. ___setup_pstate (ps, vms)                  [ownership:
 *                 exported gambit.h:14782-14784, but undocumented lifecycle;
 *                 initializes os+mem, processor object, registers, handlers,
 *                 catcher (setup.c:4675-4760)]                 [catcher]
 *              4. bind TLS: ___tls_ptr = ps (or ___set_tls_ptr, os_thread.c:
 *                 802-845 — ___USE_THREAD_LOCAL_STORAGE_GETTER_SETTER mode)  [TLS]
 *              5. scheme_w3mt_pid / add / add_alloc — first foreign entry
 *              6. scheme_w3mt_gc_rounds — real collections FROM the attached
 *                 pstate (membership stress: OP_GARBAGE_COLLECT barrier over
 *                 processor_count, setup.c:1182-1196 + 500-580, while this
 *                 processor's id >= processor_count)  [roots: interrupts are
 *                 raised ONLY for slots 0..processor_count-1 (setup.c:95-104)
 *                 and GC scan work-stealing covers only those pstates
 *                 (mem.c:6269-6280, 6678-6702) — the attached pstate is
 *                 invisible to every collection run by the other processors]
 *              7. teardown attempt: unbind TLS, ___cleanup_pstate
 *                 (gambit.h:14786-14787, setup.c:4665-4672)
 *            then a SECOND attach/detach round on the same slot (repeated
 *            attachment, same process).
 *
 *   bridge-concurrent  the bridge worker attaches and runs Scheme WHILE the
 *            owner thread allocates in Scheme (scheme_w3mt_spin) — the
 *            membership hole exercised concurrently: legit processors collect
 *            (their allocation pressure triggers OP_GARBAGE_COLLECT) without
 *            ever interrupting/scanning the attached mutator.
 *
 *   reattach standalone repeat-attachment run (attach -> call -> teardown ->
 *            attach again), only reached if bridge survived.
 *
 * Any attach sequence tried here is NOT a documented protocol: it mutates
 * runtime-internal state (VM pstate array slots, thread-local ___tls_ptr)
 * through exported-but-undocumented symbols. Membership is never established
 * (processor_count unchanged), so even a "passing" bridge cannot make GC-safe
 * foreign entry — that is the qualification criterion this phase probes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

#include <gambit.h>

/* c-define'd in w3mt-server.scm — all two-argument procedures are declared
   with two C parameters (review F1 correction) */
extern int scheme_w3mt_add (int x, int y);
extern int scheme_w3mt_add_alloc (int x, int y);
extern int scheme_w3mt_gc_rounds (int n);
extern int scheme_w3mt_pid (void);
extern int scheme_w3mt_spin (int ms);

#define SCHEME_LIBRARY_LINKER ___LNK_w3mt_2d_server__
___BEGIN_C_LINKAGE
extern ___mod_or_lnk SCHEME_LIBRARY_LINKER (___global_state);
___END_C_LINKAGE

#define W3MT_MAX_CSCORE 42   /* scheme_w3mt_add(20,22) */
#define W3MT_MAX_ALLOCCSCORE 1072   /* 50+22+vector-length(make-vector 1000 50) */

static void w3mt_log (const char *s)
{
  fputs (s, stdout);
  fputc ('\n', stdout);
  fflush (stdout);
}

static void w3mt_log1 (const char *s, long v)
{
  printf ("%s%ld\n", s, v);
  fflush (stdout);
}

/* ------------------------------------------------------------------ */
/* workers                                                             */
/* ------------------------------------------------------------------ */

static pthread_t w3mt_tid;

static void *w3mt_worker_naive (void *arg)
{
  int r;
  (void) arg;
  w3mt_log ("W3MT-WORKER: raw pthread calling scheme_w3mt_add(20,22) — first foreign Scheme entry");
  r = scheme_w3mt_add (20, 22);
  printf ("W3MT-WORKER: scheme_w3mt_add(20,22) = %d (expected %d)\n",
          r, W3MT_MAX_CSCORE);
  fflush (stdout);
  r = scheme_w3mt_add_alloc (50, 22);
  printf ("W3MT-WORKER: scheme_w3mt_add_alloc(50,22) = %d (expected %d)\n",
          r, W3MT_MAX_ALLOCCSCORE);
  fflush (stdout);
  return (void *) (long) 0;
}

static void *w3mt_worker_concurrent (void *arg)
{
  int i, r;
  long bad = 0;
  (void) arg;
  usleep (200000);   /* owner is definitely inside scheme_w3mt_spin by now */
  for (i = 0; i < 10000; i++)
    {
      r = scheme_w3mt_add (1, 1);
      if (r != 2)
        bad++;
    }
  printf ("W3MT-WORKER: completed 10000 concurrent entries, bad=%ld\n", bad);
  fflush (stdout);
  return (void *) 0;
}

/* ---- the best-effort attach bridge ---- */

static int w3mt_bind_tls (___processor_state ps)
{
#ifdef ___USE_THREAD_LOCAL_STORAGE_GETTER_SETTER
  ___set_tls_ptr (___CAST(void*,ps));
#else
  ___tls_ptr = ___CAST(void*,ps);
#endif
  return 0;
}

static int w3mt_unbind_tls (void)
{
#ifdef ___USE_THREAD_LOCAL_STORAGE_GETTER_SETTER
  ___set_tls_ptr (0);
#else
  ___tls_ptr = 0;
#endif
  return 0;
}

/* one full attach -> enter -> (optional GC) -> teardown round.
   keep_attached != 0 leaves the pstate attached (TLS bound, pstate live) —
   the caller MUST tear down later.
   returns 0 on full success, #failures otherwise (crash aborts everything). */
static int w3mt_bridge_round (int round_no, int do_gc, int keep_attached)
{
  ___virtual_machine_state vms = &___GSTATE->vmstate0;
  int n = vms->processor_count;
  int slot = n;
  ___processor_state ps;
  ___SCMOBJ err;
  int failures = 0;
  int r, g;
  long pid;

  printf ("W3MT-BRIDGE: round %d: TLS pstate before attach = %p (raw pthread is unregistered: expected 0)\n",
          round_no, ___CAST (void *, ___GET_REAL_PSTATE ()));
  fflush (stdout);

  printf ("W3MT-BRIDGE: round %d: vms->processor_count = %d, attaching at aligned_pstate slot %d (___MAX_PROCESSORS=%d)\n",
          round_no, n, slot, (int) ___MAX_PROCESSORS);
  fflush (stdout);

  if (slot >= (int) ___MAX_PROCESSORS)
    {
      printf ("W3MT-BRIDGE: round %d: slot beyond ___MAX_PROCESSORS — cannot attach\n",
              round_no);
      fflush (stdout);
      return 1;
    }

  ps = ___PSTATE_FROM_PROCESSOR_ID (slot, vms);

  err = ___setup_pstate (ps, vms);   /* exported (gambit.h:14782) but undocumented lifecycle */
  printf ("W3MT-BRIDGE: round %d: ___setup_pstate(slot %d) = %ld (0 = no error)\n",
          round_no, slot, (long) err);
  fflush (stdout);
  if (err != ___FIX(___NO_ERR))
    return 1;

  w3mt_bind_tls (ps);
  printf ("W3MT-BRIDGE: round %d: TLS bound to attached pstate = %p (membership NOT established: vms->processor_count still %d)\n",
          round_no, ___CAST (void *, ___GET_REAL_PSTATE ()), vms->processor_count);
  fflush (stdout);

  if (___GET_REAL_PSTATE () != ps)
    {
      printf ("W3MT-BRIDGE: round %d: TLS binding FAILED\n", round_no);
      fflush (stdout);
      failures++;
    }

  /* first foreign Scheme entry through the attached pstate */
  pid = scheme_w3mt_pid ();
  printf ("W3MT-BRIDGE: round %d: first entry scheme_w3mt_pid() = %ld\n",
          round_no, pid);
  fflush (stdout);

  r = scheme_w3mt_add (20, 22);
  printf ("W3MT-BRIDGE: round %d: scheme_w3mt_add(20,22) = %d (expected %d) %s\n",
          round_no, r, W3MT_MAX_CSCORE,
          r == W3MT_MAX_CSCORE ? "OK" : "WRONG");
  fflush (stdout);
  if (r != W3MT_MAX_CSCORE)
    failures++;

  r = scheme_w3mt_add_alloc (50, 22);
  printf ("W3MT-BRIDGE: round %d: scheme_w3mt_add_alloc(50,22) = %d (expected %d) %s\n",
          round_no, r, W3MT_MAX_ALLOCCSCORE,
          r == W3MT_MAX_ALLOCCSCORE ? "OK" : "WRONG");
  fflush (stdout);
  if (r != W3MT_MAX_ALLOCCSCORE)
    failures++;

  if (do_gc)
    {
      printf ("W3MT-BRIDGE: round %d: requesting REAL collections from the attached pstate (membership stress: barrier over processor_count=%d)\n",
              round_no, n);
      fflush (stdout);
      g = scheme_w3mt_gc_rounds (2);
      printf ("W3MT-BRIDGE: round %d: scheme_w3mt_gc_rounds(2) returned %d (expected 2)\n",
              round_no, g);
      fflush (stdout);
      if (g != 2)
        failures++;
    }

  /* teardown attempt */
  w3mt_unbind_tls ();
  printf ("W3MT-BRIDGE: round %d: TLS unbound (TLS pstate now = %p)\n",
          round_no, ___CAST (void *, ___GET_REAL_PSTATE ()));
  fflush (stdout);

  ___cleanup_pstate (ps);   /* exported (gambit.h:14786) but undocumented teardown */
  printf ("W3MT-BRIDGE: round %d: ___cleanup_pstate(slot %d) returned\n",
          round_no, slot);
  fflush (stdout);

  return failures;
}

static void *w3mt_worker_bridge (void *arg)
{
  int f1, f2;
  (void) arg;
  f1 = w3mt_bridge_round (1, 1, 0);
  printf ("W3MT-BRIDGE: attach round 1 failures = %d\n", f1);
  fflush (stdout);
  f2 = w3mt_bridge_round (2, 1, 0);   /* repeated attachment, same process */
  printf ("W3MT-BRIDGE: attach round 2 (repeated attachment) failures = %d\n", f2);
  fflush (stdout);
  printf ("W3MT-BRIDGE-RESULT: %s\n",
          (f1 == 0 && f2 == 0)
            ? "BOTH ROUNDS RETURNED WITH EXPECTED VALUES (entry survived; membership still not established — see ___processor_count notes; NOT a documented protocol)"
            : "FAILURES OBSERVED");
  fflush (stdout);
  return (void *) (long) ((f1 == 0 && f2 == 0) ? 0 : 1);
}

/* one attach/call/teardown cycle per worker; used by the reattach phase for
   its third and fourth cycles (NEVER on the owner thread: unbinding the
   owner's TLS would leave processor 0's OS thread without a pstate) */
static void *w3mt_worker_bridge_once (void *arg)
{
  long round_no = (long) (arg);
  int f = w3mt_bridge_round ((int) round_no, 1, 0);
  printf ("W3MT-REATTACH: cycle %ld failures = %d\n", round_no, f);
  fflush (stdout);
  return (void *) (long) (f == 0 ? 0 : 1);
}

static void *w3mt_worker_bridge_concurrent (void *arg)
{
  int f;
  long bad = 0;
  int i, r;
  (void) arg;
  usleep (200000);   /* owner is inside scheme_w3mt_spin allocating by now */
  /* attach + entries, NO gc from attached side, STAY ATTACHED for the
     concurrent mutating loop */
  f = w3mt_bridge_round (1, 0, 1);
  for (i = 0; i < 3000; i++)      /* keep mutating while owner allocates + GCs */
    {
      r = scheme_w3mt_add (1, 1);
      if (r != 2)
        bad++;
    }
  printf ("W3MT-BRIDGE-CONCURRENT: attach failures=%d, concurrent entries while attached bad=%ld/3000\n",
          f, bad);
  fflush (stdout);
  /* teardown only after the concurrent phase */
  w3mt_unbind_tls ();
  printf ("W3MT-BRIDGE-CONCURRENT: TLS unbound after concurrent phase\n");
  fflush (stdout);
  ___cleanup_pstate (___PSTATE_FROM_PROCESSOR_ID (___GSTATE->vmstate0.processor_count,
                                                 &___GSTATE->vmstate0));
  printf ("W3MT-BRIDGE-CONCURRENT: ___cleanup_pstate(slot %d) returned\n",
          ___GSTATE->vmstate0.processor_count);
  fflush (stdout);
  return (void *) (long) ((f == 0 && bad == 0) ? 0 : 1);
}

/* spawn mode for scheme_w3mt_spin (the owner's spinner calls this from C) */
static int w3mt_spawn_mode = 0;   /* 0 = naive concurrent, 1 = bridge-concurrent */

void w3mt_spawn_worker_concurrent (void)
{
  pthread_create (&w3mt_tid, NULL,
                  w3mt_spawn_mode ? w3mt_worker_bridge_concurrent
                                  : w3mt_worker_concurrent,
                  NULL);
}

/* ------------------------------------------------------------------ */
/* phases                                                              */
/* ------------------------------------------------------------------ */

static int w3mt_phase_owner (void)
{
  int failures = 0;
  int r, g;
  long pid;

  w3mt_log ("W3MT-OWNER: control — C->Scheme entry from the OS thread that ran ___setup");
  pid = scheme_w3mt_pid ();
  printf ("W3MT-OWNER: scheme_w3mt_pid() = %ld (owner processor id)\n", pid);
  fflush (stdout);
  r = scheme_w3mt_add (20, 22);
  printf ("W3MT-OWNER: scheme_w3mt_add(20,22) = %d (expected %d) %s\n",
          r, W3MT_MAX_CSCORE, r == W3MT_MAX_CSCORE ? "OK" : "WRONG");
  fflush (stdout);
  if (r != W3MT_MAX_CSCORE)
    failures++;
  r = scheme_w3mt_add_alloc (50, 22);
  printf ("W3MT-OWNER: scheme_w3mt_add_alloc(50,22) = %d (expected %d) %s\n",
          r, W3MT_MAX_ALLOCCSCORE, r == W3MT_MAX_ALLOCCSCORE ? "OK" : "WRONG");
  fflush (stdout);
  if (r != W3MT_MAX_ALLOCCSCORE)
    failures++;
  g = scheme_w3mt_gc_rounds (2);
  printf ("W3MT-OWNER: scheme_w3mt_gc_rounds(2) = %d (expected 2) %s\n",
          g, g == 2 ? "OK" : "WRONG");
  fflush (stdout);
  if (g != 2)
    failures++;
  printf ("W3MT-OWNER-VERDICT: %s (owner-thread control; two-formal (int int) entries verified at runtime)\n",
          failures == 0 ? "PASS" : "FAIL");
  fflush (stdout);
  return failures;
}

static int w3mt_phase_p1 (void)
{
  void *ret = 0;
  int rc;
  w3mt_log ("W3MT-P1: owner parks in pthread_join; raw pthread enters Scheme (serialized naive entry)");
  rc = pthread_create (&w3mt_tid, NULL, w3mt_worker_naive, NULL);
  if (rc != 0)
    {
      w3mt_log ("W3MT-P1: pthread_create failed");
      return 1;
    }
  pthread_join (w3mt_tid, &ret);
  printf ("W3MT-P1: worker joined, exit=%ld\n", (long) ret);
  fflush (stdout);
  printf ("W3MT-P1-VERDICT: %s (serialized naive foreign entry)\n",
          (long) ret == 0 ? "PASS" : "FAIL");
  fflush (stdout);
  return (int) (long) ret;
}

static int w3mt_phase_p2 (void)
{
  void *ret = 0;
  int spin;
  w3mt_log ("W3MT-P2: owner runs scheme_w3mt_spin (allocates in Scheme ~3s) while a raw pthread enters Scheme concurrently");
  spin = scheme_w3mt_spin (3000);
  pthread_join (w3mt_tid, &ret);
  printf ("W3MT-P2: owner survived scheme_w3mt_spin (allocs=%d), worker joined exit=%ld\n",
          spin, (long) ret);
  fflush (stdout);
  printf ("W3MT-P2-VERDICT: PASS treated with suspicion (two OS threads, one VM — the worker's entry is unregistered; any survival is UB)\n");
  fflush (stdout);
  return 0;
}

static int w3mt_phase_bridge (void)
{
  void *ret = 0;
  w3mt_log ("W3MT-BRIDGE: best-effort attach bridge (undocumented; every ingredient cited in w3mt-main.c header)");
  w3mt_log ("W3MT-BRIDGE: owner parks in pthread_join during attach rounds");
  pthread_create (&w3mt_tid, NULL, w3mt_worker_bridge, NULL);
  pthread_join (w3mt_tid, &ret);
  printf ("W3MT-BRIDGE: worker joined, exit=%ld\n", (long) ret);
  fflush (stdout);
  printf ("W3MT-BRIDGE-VERDICT: %s (bridge attach + calls + real GC from attached pstate + teardown + repeated attachment)\n",
          (long) ret == 0 ? "SURVIVED" : "FAILED");
  fflush (stdout);
  return (int) (long) ret;
}

static int w3mt_phase_bridge_concurrent (void)
{
  void *ret = 0;
  int spin;
  w3mt_log ("W3MT-BRIDGE-CONCURRENT: bridge worker attaches WHILE owner allocates in Scheme (membership hole under concurrent GC pressure)");
  w3mt_spawn_mode = 1;
  spin = scheme_w3mt_spin (4000);
  pthread_join (w3mt_tid, &ret);
  printf ("W3MT-BRIDGE-CONCURRENT: owner survived scheme_w3mt_spin (allocs=%d), worker joined exit=%ld\n",
          spin, (long) ret);
  fflush (stdout);
  printf ("W3MT-BRIDGE-CONCURRENT-VERDICT: %s (attached mutator concurrent with legit processors' collections)\n",
          (long) ret == 0 ? "SURVIVED (suspicion: attached pstate invisible to GC — see setup.c:95-104, mem.c:6678-6702)" : "FAILED");
  fflush (stdout);
  return (int) (long) ret;
}

static int w3mt_phase_reattach (void)
{
  void *ret = 0;
  int total = 0;
  w3mt_log ("W3MT-REATTACH: four attach/teardown cycles, each in its own worker pthread, same slot, same process");
  pthread_create (&w3mt_tid, NULL, w3mt_worker_bridge_once, (void *) 1L);
  pthread_join (w3mt_tid, &ret);
  total += (int) (long) ret;
  pthread_create (&w3mt_tid, NULL, w3mt_worker_bridge_once, (void *) 2L);
  pthread_join (w3mt_tid, &ret);
  total += (int) (long) ret;
  pthread_create (&w3mt_tid, NULL, w3mt_worker_bridge_once, (void *) 3L);
  pthread_join (w3mt_tid, &ret);
  total += (int) (long) ret;
  pthread_create (&w3mt_tid, NULL, w3mt_worker_bridge_once, (void *) 4L);
  pthread_join (w3mt_tid, &ret);
  total += (int) (long) ret;
  printf ("W3MT-REATTACH: total failed cycles = %d of 4\n", total);
  fflush (stdout);
  printf ("W3MT-REATTACH-VERDICT: %s (repeated attachment cycles)\n",
          total == 0 ? "SURVIVED" : "FAILED");
  fflush (stdout);
  return total;
}

/* ------------------------------------------------------------------ */

static int w3mt_setup_runtime (void)
{
  ___setup_params_struct setup_params;

  ___setup_params_reset (&setup_params);
  setup_params.version = ___VERSION;
  setup_params.linker  = SCHEME_LIBRARY_LINKER;
  /* EXPLICIT parallelism for the server pattern — the library-program
     equivalent of the gsi/gsc driver's -:p2 (main.c:46-49 parses -:p into
     this same field; review step 2 requirement). NEVER the W0 resize thunk. */
  setup_params.parallelism_level = 2;
  /* explicit heap bounds: on this MT build the stock heap-growth path is
     fragile (see BUILD-CONFIG.md); a large initial heap avoids growth */
  setup_params.min_heap = 64 * 1024 * 1024;
  setup_params.max_heap = 512 * 1024 * 1024;
  /* -:d5-equivalent verbosity for verbatim *** GC: reports, plus
     uncaught-all + error-quit so no REPL can block the server process */
  setup_params.debug_settings = 5 | (1 << 4) | (2 << 5);

  printf ("W3MT: calling ___setup from the primordial thread (parallelism_level=2, debug_settings=%d)\n",
          setup_params.debug_settings);
  fflush (stdout);
  ___setup (&setup_params);
  printf ("W3MT: ___setup returned; runtime live (___VERSION=%ld, processor_count=%d, max=%d)\n",
          (long) ___VERSION,
          ___GSTATE->vmstate0.processor_count,
          (int) ___MAX_PROCESSORS);
  fflush (stdout);
  return 0;
}

int main (int argc, char **argv)
{
  const char *phase = (argc > 1) ? argv[1] : "owner";

  w3mt_setup_runtime ();

  if (strcmp (phase, "owner") == 0)
    w3mt_phase_owner ();
  else if (strcmp (phase, "p1") == 0)
    w3mt_phase_p1 ();
  else if (strcmp (phase, "p2") == 0)
    w3mt_phase_p2 ();
  else if (strcmp (phase, "bridge") == 0)
    w3mt_phase_bridge ();
  else if (strcmp (phase, "bridge-concurrent") == 0)
    w3mt_phase_bridge_concurrent ();
  else if (strcmp (phase, "reattach") == 0)
    w3mt_phase_reattach ();
  else
    w3mt_log ("W3MT-usage: ./w3mt.exe owner|p1|p2|bridge|bridge-concurrent|reattach");

  printf ("W3MT: calling ___cleanup\n");
  fflush (stdout);
  ___cleanup ();
  printf ("W3MT: ___cleanup returned\n");
  fflush (stdout);
  return 0;
}
