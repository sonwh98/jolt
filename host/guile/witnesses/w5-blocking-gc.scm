;; W5 — blocking-foreign-call vs GC witness (audit area 4, the W2 analog).
;;
;; Contract row (TARGET-CONTRACT.md, pinned): "Blocking foreign calls must
;; not stop other threads' GC... A target whose collector never stops other
;; threads may collapse blocking to plain."
;;
;; Manual §6.22.6 "Blocking in Guile Mode" documents the answer for Guile:
;;   "Starting from Guile 2.0, blocked threads no longer hinder garbage
;;    collection."
;; This witness decides it executably: thread A parks inside a compiled C
;; shim (w5_blocking_sleep, calling libc sleep(3) and setting a C-side
;; atomic handshake flag w5_in_c=1 strictly while inside the C call), while
;; thread B checks w5_is_in_c(), allocates/GCs, and records gc-times.
;;
;; Verdict is DERIVED from observed state (p1a F3 discipline):
;;   - B is proven executing BEFORE A enters C (flag handshake);
;;   - the in-block interval is delimited by the C-side atomic handshake;
;;   - A asserts both the C return value (0) and real elapsed wall-clock
;;     time (>= 2500ms for sleep(3));
;;   - gc-times delta is recorded strictly from rounds where w5_is_in_c()==1;
;;   - any in-flight worker round is drained before sampling the negative
;;     control.

(use-modules (system foreign)
             (system foreign-library)
             (ice-9 threads)
             (ice-9 atomic)
             (srfi srfi-1))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(format #t "=== W5 blocking-C-call vs GC witness ===~%")

(define darwin?
  (and (string-contains (utsname:sysname (uname)) "Darwin") #t))
(define tmpdir (string-append "/tmp/w5-" (number->string (getpid))))
(mkdir tmpdir #o700)
(define shim-src (string-append tmpdir "/w5shim.c"))
(define shim-lib
  (string-append tmpdir "/libw5shim." (if darwin? "dylib" "so")))
(call-with-output-file shim-src
  (lambda (p)
    (display "#include <unistd.h>\n" p)
    (display "#include <stdatomic.h>\n" p)
    (display "static atomic_int w5_in_c = 0;\n" p)
    (display "int w5_blocking_sleep(unsigned int secs) {\n" p)
    (display "  atomic_store_explicit(&w5_in_c, 1, memory_order_release);\n" p)
    (display "  unsigned int rem = sleep(secs);\n" p)
    (display "  atomic_store_explicit(&w5_in_c, 0, memory_order_release);\n" p)
    (display "  return (int)rem;\n" p)
    (display "}\n" p)
    (display "int w5_is_in_c(void) {\n" p)
    (display "  return atomic_load_explicit(&w5_in_c, memory_order_acquire);\n" p)
    (display "}\n" p)))
(let ((rc (system* "cc" "-O2" "-shared" "-fPIC" "-o" shim-lib shim-src)))
  (check "compiled C-side handshake shim (w5_blocking_sleep / w5_is_in_c)"
         (zero? rc)))

(define shim-handle (load-foreign-library shim-lib))
(define w5-blocking-sleep
  (foreign-library-function shim-handle "w5_blocking_sleep"
                            #:return-type int
                            #:arg-types (list unsigned-int)))
(define w5-is-in-c
  (foreign-library-function shim-handle "w5_is_in_c"
                            #:return-type int
                            #:arg-types '()))

(define b-running (make-atomic-box #f))     ; B provably executing
(define rounds-during-block (make-atomic-box 0))
(define rounds-total (make-atomic-box 0))
(define gc-times-first-in-c #f)
(define gc-times-last-in-c #f)
(define witness-vector (make-vector 100000 0))
(define heaps-during-block '())

(define (b-round!)
  ;; one real collection round over live data (explicit (gc) + churn)
  (let* ((_ (do ((i 0 (+ i 1)))
                ((= i 20000))
              (vector-set! witness-vector i (+ i 1))))
         (garbage (make-vector 5000 'churn))
         (in-c? (= (w5-is-in-c) 1)))
    (set! garbage #f)
    (when (zero? (modulo (atomic-box-ref rounds-total) 10))
      (gc))
    (when in-c?
      (let ((gt (assq-ref (gc-stats) 'gc-times)))
        (unless gc-times-first-in-c
          (set! gc-times-first-in-c gt))
        (set! gc-times-last-in-c gt))
      (atomic-box-set! rounds-during-block
                       (+ (atomic-box-ref rounds-during-block) 1))
      (set! heaps-during-block
            (cons (assq-ref (gc-stats) 'heap-size) heaps-during-block)))
    (atomic-box-set! rounds-total (+ (atomic-box-ref rounds-total) 1))))

(define b-thread
  (call-with-new-thread
   (lambda ()
     (atomic-box-set! b-running #t)
     (let loop ()
       (b-round!)
       (loop)))))

;; wait until B is provably executing on the runtime
(let spin ((n 0))
  (unless (or (atomic-box-ref b-running) (> n 200))
    (sleep 1) (spin (+ n 1))))
(let spin ((n 0))
  (unless (or (>= (atomic-box-ref rounds-total) 1) (> n 200))
    (sleep 1) (spin (+ n 1))))
(check "B is provably executing (>=1 round before A enters C)"
       (>= (atomic-box-ref rounds-total) 1))
(define rounds-before-block (atomic-box-ref rounds-total))

;; A enters the blocking foreign call for 3 seconds (C-side handshake).
(define (now-ms)
  (/ (get-internal-real-time) (/ internal-time-units-per-second 1000.0)))
(define t0 (now-ms))
(define rem (w5-blocking-sleep 3))
(define elapsed-ms (- (now-ms) t0))
(define rounds-after (- (atomic-box-ref rounds-total) rounds-before-block))
(define in-c-rounds (atomic-box-ref rounds-during-block))
(define gc-times-during
  (if (and gc-times-first-in-c gc-times-last-in-c)
      (- gc-times-last-in-c gc-times-first-in-c)
      0))
(format #t "A: w5_blocking_sleep(3) returned rem=~a elapsed-ms=~a~%"
        rem elapsed-ms)
(format #t "observed state (C-handshake delimited): rounds-before=~a \
rounds-after=~a rounds-during-block=~a gc-times-first-in-c=~a \
gc-times-last-in-c=~a gc-times-during=~a~%"
        rounds-before-block rounds-after in-c-rounds
        gc-times-first-in-c gc-times-last-in-c gc-times-during)
(check "A's C call returned 0 and really blocked ~3s wall-clock (>=2500ms)"
       (and (= rem 0) (>= elapsed-ms 2500) (>= rounds-after 1)))
(check "DECISIVE: B completed rounds AND real GC collections \
(gc-times incremented strictly inside the C-side handshake) WHILE A sat in C \
(blocking collapses to plain: the collector does not stop)"
       (and (>= in-c-rounds 1) (> gc-times-during 0)))

;; real-GC evidence: gc-times incremented inside C block, and the live
;; witness vector's mutations are intact.
(format #t "heap-size samples during block: ~a~%"
        (length (delete-duplicates heaps-during-block)))
(check "collections were real during block (gc-times delta > 0)"
       (> gc-times-during 0))
(check "live vector mutations intact after concurrent collections"
       (= (vector-ref witness-vector 19999) 20000))

;; NC: drain any in-flight worker round that started before w5_in_c cleared,
;; then observe a 1s window outside C: rounds-during-block MUST NOT advance
;; while rounds-total continues advancing.
(let ((post-c-total (atomic-box-ref rounds-total)))
  (let drain ()
    (when (< (atomic-box-ref rounds-total) (+ post-c-total 2))
      (yield)
      (drain))))
(define during-nc0 (atomic-box-ref rounds-during-block))
(define total-nc0 (atomic-box-ref rounds-total))
(sleep 1)
(define during-nc1 (atomic-box-ref rounds-during-block))
(define total-nc1 (atomic-box-ref rounds-total))
(format #t "NC control (w5_in_c=0, post-drain 1s window): during ~a->~a, \
total ~a->~a~%" during-nc0 during-nc1 total-nc0 total-nc1)
(check "NC control: rounds-during-block stays unchanged when w5_in_c=0 \
while rounds-total advances"
       (and (= during-nc1 during-nc0) (> total-nc1 total-nc0)))

(cancel-thread b-thread)
(false-if-exception (join-thread b-thread))
(false-if-exception (delete-file shim-src))
(false-if-exception (delete-file shim-lib))
(false-if-exception (rmdir tmpdir))
(if (zero? fails)
    (format #t "W5-VERDICT: PASS (GC completes during a blocked C call)~%")
    (format #t "W5-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
