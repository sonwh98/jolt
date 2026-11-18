;; W3 — foreign-thread entry witness (C-driven "server" program, the manual's
;; documented pattern: c-define procedures + ___setup from C, cf. manual §
;; "The c-define special form": "Before it can be used, the Scheme part must
;; be initialized with a call to ___setup", and tests/server.scm).
;;
;; p1a-r2 REPAIR of review finding F1: BOTH exported entries now declare
;; (int int), matching their two Scheme formals (x y) — the P1a fixtures
;; declared (int), so the generated C converted ONE argument for procedures
;; requiring TWO and the 3/3 SIGSEGVs reproduced a malformed entry fixture.
;; scheme_w3_phase3 is likewise fixed to (), matching the C fixture's
;; scheme_w3_phase3(void) call (it was (int) against zero formals).
;; The Makefile regenerates with gsc -keep-temp and VERIFIES the generated C
;; shows ___NARGS 2 for both add entries BEFORE any run.
;;
;; An OWNER-THREAD CONTROL runs inside every mode BEFORE any foreign-thread
;; phase: the Gambit thread that ran ___setup drives the SAME c-define
;; entries (scheme_w3_add, scheme_w3_add_alloc, scheme_w3_gc_rounds) with
;; exact expected values; a wrong value aborts the run before any
;; foreign-thread phase.
;;
;; A RAW pthread (not created by Gambit, never registered with the runtime)
;; then calls the same c-define'd Scheme procedures. Two foreign-entry
;; phases:
;;
;;   phase 1 (serialized): the primordial thread (which ran ___setup) stays
;;     parked inside a C pthread_join while the worker pthread enters Scheme.
;;     On a ___SINGLE_THREADED_VMS build there is exactly one processor state
;;     (gambit.h ~8625: "Use direct access to the only pstate"; ___SET_REAL_PSTATE
;;     is a no-op there), so the worker is reusing the primordial's pstate
;;     behind its back.
;;
;;   phase 2 (concurrent): the worker pthread enters Scheme WHILE the
;;     primordial thread is running Scheme (scheme_w3_spin allocates in a loop
;;     for ~3s after spawning the worker). Two threads, one processor state,
;;     one Scheme stack chain, one allocator: undefined behavior.
;;
;; VERDICT SEMANTICS (nondeterminism caveat, per the review): fatal exits
;; (70 = Gambit fatal, 134/138/139 = SIGABRT/SIGBUS/SIGSEGV) ALL mean unsafe
;; entry — any of them is the DOCUMENTED REFUSAL-FAILURE of this witness and
;; none is ever a success. If a run SURVIVES (the worker completes with
;; correct values — observed on the serialized owner-parked shapes with the
;; repaired two-arg entries, matching W4-M4), that is recorded as
;; REFUSAL-NOT-REPRODUCED — an undocumented serialized-reuse artifact, NEVER
;; qualification of foreign-thread entry. This witness does NOT prove
;; "unrelated entry cannot be made safe" (that claim is withdrawn per the
;; review); it documents that concurrent entry while the owner thread runs
;; Scheme is unsafe on the provisioned build, that serialized owner-parked
;; reuse is an un-protocolized artifact, and that no entry protocol exists
;; (Q4 of AUDIT.md).
;;
;; There is NO documented entry protocol for a foreign pthread in 4.9.8 — the
;; C-interface chapter documents none, gambit.h declares none, and
;; ___vm_resize_pstate (the only processor-creation path) is compiled out
;; under ___SINGLE_THREADED_VMS (setup.c:883).

(c-define (scheme-w3-add x y) (int int) int "scheme_w3_add" "extern"
  (+ x y))

;; discriminator probe: same (int int) signature as scheme-w3-add but the
;; body ALLOCATES (same shape as W4-M4's callback) — isolates whether
;; allocation changes the foreign-entry outcome.
(c-define (scheme-w3-add-alloc x y) (int int) int "scheme_w3_add_alloc" "extern"
  (+ x y (vector-length (make-vector 1000 x))))

(c-declare "void w3_spawn_worker_nojoin (void); int w3_park_and_join (int unused);")

(c-define (scheme-w3-gc-rounds n) (int) int "scheme_w3_gc_rounds" "extern"
  ;; real collections driven from a foreign pthread: allocate + ##gc, n rounds
  (let loop ((i 1) (acc 0))
    (if (<= i n)
        (begin
          (let ((v (make-vector 200000 0)))
            (vector-set! v 0 i)
            (##gc)
            (loop (+ i 1) (+ acc 1))))
        acc)))

(c-define (scheme-w3-spin ms) (int) int "scheme_w3_spin" "extern"
  ;; spawns the racing worker pthread (from C) then keeps the primordial
  ;; thread INSIDE Scheme, allocating, for about ms milliseconds
  (begin
    (w3-spawn-worker)
    (let ((deadline (+ (time->seconds (current-time)) (/ ms 1000.0))))
      (let loop ((allocs 0))
        (if (< (time->seconds (current-time)) deadline)
            (loop (+ allocs 1 (vector-length (make-vector 50000 0))))
            allocs)))))

(define w3-spawn-worker
  (c-lambda () void "w3_spawn_worker_nojoin (); ___return;"))

;; phase3 driver: the OWNER Gambit thread parks inside this cfun while the
;; worker pthread (spawned inside it) enters Scheme.
(define w3-park-and-join (c-lambda (int) int "w3_park_and_join"))

(c-define (scheme-w3-phase3) () int "scheme_w3_phase3" "extern"
  (w3-park-and-join 0))
