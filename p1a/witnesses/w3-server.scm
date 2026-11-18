;; W3 — foreign-thread entry witness (C-driven "server" program, the manual's
;; documented pattern: c-define procedures + ___setup from C, cf. manual §
;; "The c-define special form": "Before it can be used, the Scheme part must
;; be initialized with a call to ___setup", and tests/server.scm).
;;
;; A RAW pthread (not created by Gambit, never registered with the runtime)
;; calls c-define'd Scheme procedures. Two phases:
;;
;;   phase 1 (serialized): the primordial thread (which ran ___setup) stays
;;     parked inside a C pthread_join while the worker pthread enters Scheme.
;;     On a ___SINGLE_THREADED_VMS build there is exactly one processor state
;;     (gambit.h ~8625: "Use direct access to the only pstate"; ___SET_REAL_PSTATE
;;     is a no-op there), so the worker is reusing the primordial's pstate
;;     behind its back. Works only because the primordial never runs Scheme
;;     concurrently. This documents the empirically observed serialized reuse.
;;
;;   phase 2 (concurrent): the worker pthread enters Scheme WHILE the
;;     primordial thread is running Scheme (scheme_w3_spin allocates in a loop
;;     for ~3s after spawning the worker). Two threads, one processor state,
;;     one Scheme stack chain, one allocator: undefined behavior. Expected:
;;     crash or corruption. Under the external watchdog, so a hang is also a
;;     recorded failure.
;;
;; There is NO documented entry protocol for a foreign pthread in 4.9.8 — the
;; C-interface chapter documents none, gambit.h declares none, and
;; ___vm_resize_pstate (the only processor-creation path) is compiled out
;; under ___SINGLE_THREADED_VMS (setup.c:883).

(c-define (scheme-w3-add x y) (int) int "scheme_w3_add" "extern"
  (+ x y))

;; discriminator probe: same signature as scheme-w3-add but the body ALLOCATES
;; (same shape as W4-M4's callback) — isolates why W4-M4 survives while
;; phase1/phase3 crash on the trivial add.
(c-define (scheme-w3-add-alloc x y) (int) int "scheme_w3_add_alloc" "extern"
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

(c-define (scheme-w3-phase3) (int) int "scheme_w3_phase3" "extern"
  (w3-park-and-join 0))
