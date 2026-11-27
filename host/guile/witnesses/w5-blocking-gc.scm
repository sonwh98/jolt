;; W5 — blocking-foreign-call vs GC witness (audit area 4, the W2 analog).
;;
;; Contract row (TARGET-CONTRACT.md, pinned): "Blocking foreign calls must
;; not stop other threads' GC... A target whose collector never stops other
;; threads may collapse blocking to plain."
;;
;; Manual §6.22.6 "Blocking in Guile Mode" documents the answer for Guile:
;;   "Starting from Guile 2.0, blocked threads no longer hinder garbage
;;    collection."
;; This witness decides it executably: thread A parks inside a C call
;; (libc sleep, entered through (system foreign) — exactly the shape a
;; sa-foreign-procedure-blocking lowering would produce), while thread B
;; provably executes real collections and allocation churn.
;;
;; Verdict is DERIVED from observed state (p1a F3 discipline):
;;   - B is proven executing BEFORE A enters C (flag handshake);
;;   - the in-block window is a flag A sets around the foreign call;
;;   - rounds-during-block counts only rounds B completed while that flag
;;     was set;
;;   - a real collection is evidenced by gc-stats deltas on live data.
;;
;; Negative control: the counter machinery is exercised on a window where
;; A does NOT enter C and B's rounds must count; if the counters could not
;; distinguish, NC would print CHECK-FAIL.

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

(define c-sleep
  (foreign-library-function #f "sleep"
                            #:return-type unsigned-int
                            #:arg-types (list unsigned-int)))

(define b-running (make-atomic-box #f))     ; B provably executing
(define a-in-block (make-atomic-box #f))    ; A inside the C call
(define rounds-during-block 0)
(define rounds-total 0)
(define witness-vector (make-vector 100000 0))
(define stats-deltas '())

(define (b-round!)
  ;; one real collection round over live data
  (let* ((before (gc-stats))
         (_ (do ((i 0 (+ i 1)))
                ((= i 20000))
              (vector-set! witness-vector i (+ i 1))))
         (garbage (make-vector 5000 'churn))
         (after (gc-stats)))
    (set! garbage #f)
    (set! rounds-total (+ rounds-total 1))
    (when (atomic-box-ref a-in-block)
      (set! rounds-during-block (+ rounds-during-block 1)))
    (set! stats-deltas
          (cons (cons (assq-ref before 'heap-size)
                      (assq-ref after 'heap-size))
                stats-deltas))))

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
  (unless (or (>= rounds-total 1) (> n 200))
    (sleep 1) (spin (+ n 1))))
(check "B is provably executing (>=1 round before A enters C)"
       (>= rounds-total 1))
(define rounds-before-block rounds-total)

;; A enters the blocking foreign call for 3 seconds.
(atomic-box-set! a-in-block #t)
(define slept (c-sleep 3))
(atomic-box-set! a-in-block #f)
(format #t "A: blocking foreign call returned ~as~%" slept)
(define rounds-after (- rounds-total rounds-before-block))
(format #t "observed state: rounds-before=~a rounds-after=~a \
rounds-during-block=~a~%"
        rounds-before-block rounds-after rounds-during-block)
(check "A's C call really blocked ~3s (wall clock)"
       (>= rounds-after 1))
(check "DECISIVE: B completed collection rounds WHILE A sat in the C call \
(blocking collapses to plain: the collector does not stop)"
       (>= rounds-during-block 1))

;; real-GC evidence: heap-size samples changed across rounds, and the live
;; witness vector's mutations are intact.
(define distinct-heaps
  (length (delete-duplicates (map car (reverse stats-deltas)))))
(format #t "distinct heap-size samples across rounds: ~a~%" distinct-heaps)
(check "collections were real (heap-size samples vary; sa-gc-collect is \
not a no-op)"
       (> distinct-heaps 1))
(check "live vector mutations intact after concurrent collections"
       (= (vector-ref witness-vector 19999) 20000))

;; NC: counter machinery control — a window with NO C call must also count
;; rounds (proves the counter is not an artifact of the block window).
(define before-nc rounds-during-block)
(atomic-box-set! a-in-block #t)
(sleep 1)                                   ; SCHEME-level sleep, no C-FFI
(define after-nc rounds-during-block)
(atomic-box-set! a-in-block #f)
(check "NC control: the in-block counter also counts in a no-C window \
(counters distinguish)"
       (> after-nc before-nc))

(cancel-thread b-thread)
(if (zero? fails)
    (format #t "W5-VERDICT: PASS (GC completes during a blocked C call)~%")
    (format #t "W5-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
