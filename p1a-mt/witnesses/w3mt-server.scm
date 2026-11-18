;; W3MT server module — Scheme procedures called from C (c-define), plus the
;; owner-thread allocation spinner.
;;
;; The codex review's F1 correction is applied: every c-define whose C callee
;; passes two arguments declares TWO formals with (int int). Per the manual
;; (doc/gambit.txi:19399-19412) the C argument types determine the arguments
;; converted and passed to the Scheme procedure; the P1a W3 witnesses declared
;; (int) while the C fixture called two-argument functions, which made their
;; crashes reproduce a malformed entry fixture instead of isolating
;; foreign-thread entry.
;;
;; The owner control (review step 4): BEFORE any foreign-pthread entry, the
;; thread that ran ___setup must successfully round-trip C -> Scheme -> C
;; through these same entry points (phase "owner" in w3mt-main.c).

(c-define (scheme-w3mt-add x y) (int int) int "scheme_w3mt_add" "extern"
  (+ x y))

;; discriminator: same (int int) signature but the body ALLOCATES (same shape
;; as W4-M4's callback) — isolates allocation-related failures from entry
;; failures.
(c-define (scheme-w3mt-add-alloc x y) (int int) int "scheme_w3mt_add_alloc" "extern"
  (+ x y (vector-length (make-vector 1000 x))))

;; real collections driven from whoever enters this procedure: allocate
;; garbage, then force a REAL collection via the runtime primitive (##gc)
;; (lib/_kernel.scm:2051-2069).
(c-define (scheme-w3mt-gc-rounds n) (int) int "scheme_w3mt_gc_rounds" "extern"
  (let loop ((i 1) (acc 0))
    (if (<= i n)
        (begin
          (let ((v (make-vector 200000 0)))
            (vector-set! v 0 i)
            (##gc))
          (loop (+ i 1) (+ acc 1)))
        acc)))

;; current processor id (SMP scheduler primitive, lib/_thread.scm:667) —
;; lets the C driver record WHICH processor executed each entry.
(c-define (scheme-w3mt-pid) () int "scheme_w3mt_pid" "extern"
  (##current-processor-id))

(c-declare "void w3mt_spawn_worker_concurrent (void);")

(define w3mt-spawn-worker
  (c-lambda () void "w3mt_spawn_worker_concurrent (); ___return;"))

;; owner keeps the primordial processor INSIDE Scheme, allocating, for ~ms
;; milliseconds after spawning the racing worker pthread (phase p2).
(c-define (scheme-w3mt-spin ms) (int) int "scheme_w3mt_spin" "extern"
  (begin
    (w3mt-spawn-worker)
    (let ((deadline (+ (time->seconds (current-time)) (/ ms 1000.0))))
      (let loop ((allocs 0))
        (if (< (time->seconds (current-time)) deadline)
            (loop (+ allocs 1 (vector-length (make-vector 50000 0))))
            allocs)))))
