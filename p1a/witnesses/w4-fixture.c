/* W4 fixture — callable (c-define) modes.
 *
 * Modes are dispatched per process (Makefile) so a crash in one mode cannot
 * erase the others' evidence:
 *   mode1 : M1 same-thread callback + M2 nested C->Scheme->C->Scheme
 *           + M3 callback from a second Gambit thread around a foreign call
 *   mode4 : M4 callback invoked from a raw foreign pthread
 *   mode5 : M5 exception raised inside a callback
 */

#include <stdio.h>
#include <pthread.h>
#include <time.h>
#include <string.h>

/* c-define'd in w4-callables.scm */
extern int w4_cb_same (int x);
extern int w4_cb_q (int x);
extern int w4_cb_p (int x);
extern int w4_cb_ft (int x);
extern int w4_cb_raise (int x);

/* ---- M1: same-thread callback ---- */
int w4_call_cb (int x)
{
  return w4_cb_same (x);
}

/* ---- M2: nested chain C a -> Scheme p -> C b -> Scheme q (one thread) ---- */
int w4_nested_b (int y)
{
  return w4_cb_q (y) + 1000;
}
int w4_nested_a (int x)
{
  return w4_cb_p (x) + 100;
}

/* ---- M3: callback from a second Gambit thread around a foreign call ---- */
static int w4_b_completed_during_block = 0;

int w4_b_entry (void)                       /* called by Gambit thread B */
{
  int r = w4_cb_same (9);
  return r;
}

int w4_b_completed_during_block_p (void)    /* probe read after A's call returns */
{
  return w4_b_completed_during_block;
}

int w4_m3_note_b (int done)                 /* Scheme side reports B's completion */
{
  if (done)
    w4_b_completed_during_block = 1;
  return 0;
}

int w4_block_then_cb (int seconds)          /* called by Gambit thread A */
{
  struct timespec ts;
  ts.tv_sec = seconds;
  ts.tv_nsec = 0;
  nanosleep (&ts, 0);
  return w4_cb_same (7);                    /* callback from C, thread A */
}

/* ---- M4: callback from a raw foreign pthread ---- */
static void *w4_ft_worker (void *arg)
{
  int r;
  (void) arg;
  r = w4_cb_ft (5);
  printf ("W4-M4: foreign-pthread callback returned %d\n", r);
  fflush (stdout);
  return (void *) 0;
}

int w4_ft_call (void)   /* spawns + joins while the CALLING Gambit thread stays inside this C call */
{
  pthread_t t;
  if (pthread_create (&t, 0, w4_ft_worker, 0) != 0)
    return -1;
  pthread_join (t, 0);
  return 0;
}

/* ---- M5: exception inside a callback ---- */
int w4_call_raise (int x)
{
  return w4_cb_raise (x);
}
