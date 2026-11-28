;; W12 — performance witness (audit area 9): boot and eval wall times,
;; interpreted and compiled, on the provisioned Guile 3.0.11.
;;
;; Measures (wall-clock via get-internal-real-time unless noted):
;;   B1 child-process boot: `guile --no-auto-compile -c 0` x3 (median);
;;   E1 interpreted eval: N=20000 (eval '(+ a b) (interaction-environment));
;;   E2 interpreted loop: a plain Scheme loop (baseline VM speed);
;;   C1 compiled procedure: (compile '(lambda (n) ...)) called the same N;
;;       ratio vs interpreted closure (compile-exp '(...) eval'd).
;;
;; Records the numbers; the PASS criterion is only that measurements
;; completed and are nonzero (this witness measures, it does not gate on
;; speed).  The AUDIT's performance ruling cites the recorded medians.

(use-modules (system base compile)
             (srfi srfi-1))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(define (now-ms)
  (/ (get-internal-real-time) (/ internal-time-units-per-second 1000.0)))

(format #t "=== W12 performance witness (Guile ~a, ~a) ===~%"
        (version) %host-type)

;; ---- B1 child boot ------------------------------------------------------------
(define guile-bin (or (getenv "GUILE") "guile"))
(define boot-runs
  (map (lambda (_)
         (let* ((t0 (now-ms))
                (st (system* guile-bin "--no-auto-compile" "-c" "0"))
                (t1 (now-ms)))
           (cons st (- t1 t0))))
       '(1 2 3)))
(define boot-statuses (map car boot-runs))
(define boots (map cdr boot-runs))
(define all-boots-ok
  (every (lambda (st)
           (and (eqv? (status:exit-val st) 0)
                (not (status:term-sig st))))
         boot-statuses))
(define boot-median
  (and all-boots-ok (second (sort boots <))))
(format #t "B1 child boot times (ms): ~a statuses=~s median=~a~%"
        boots (map status:exit-val boot-statuses) (or boot-median 'invalid))
(check "B1 boot measurements completed with exit=0 for all 3 children \
(nonzero median)"
       (and all-boots-ok boot-median (> boot-median 0)))

;; ---- E1 interpreted eval -------------------------------------------------------
(define n-eval 20000)
(define t0 (now-ms))
(do ((i 0 (+ i 1)))
    ((= i n-eval))
  (eval '(+ 1 2) (interaction-environment)))
(define e1-ms (- (now-ms) t0))
(format #t "E1 ~a interpreter evals of (+ 1 2): ~a ms (~a us/eval)~%"
        n-eval e1-ms (/ e1-ms n-eval 0.001))
(check "E1 interpreted eval measured" (> e1-ms 0))

;; ---- E2 plain loop baseline ------------------------------------------------------
(define (loop-add n acc) (if (zero? n) acc (loop-add (- n 1) (+ acc 1))))
(set! t0 (now-ms))
(loop-add 1000000 0)
(define e2-ms (- (now-ms) t0))
(format #t "E2 1M-iteration tail loop: ~a ms~%" e2-ms)
(check "E2 loop baseline measured" (> e2-ms 0))

;; ---- C1 compiled vs interpreted closure -------------------------------------------
(define interp-fn (eval '(lambda (n) (loop-add n 0))
                        (interaction-environment)))
(define comp-fn (compile '(lambda (n) (let loop ((i 0) (acc 0))
                                         (if (= i n) acc
                                             (loop (+ i 1) (+ acc 1)))))
                         #:env (current-module)))
(set! t0 (now-ms))
(interp-fn 1000000)
(define i-ms (- (now-ms) t0))
(set! t0 (now-ms))
(comp-fn 1000000)
(define c-ms (- (now-ms) t0))
(format #t "C1 1M-iteration closure: interpreted-eval'd ~a ms vs compiled \
~a ms (speedup ~a x)~%" i-ms c-ms (if (> c-ms 0) (/ i-ms c-ms) 'inf))
(check "C1 compiled-vs-interpreted measured (both nonzero)" (and (> i-ms 0)
                                                                 (> c-ms 0)))

;; ---- NC1 negative/sanity control ------------------------------------------------
;; Verify the timing harness actually measures work (1 iteration << 1M
;; iterations; not a constant or broken clock).
(set! t0 (now-ms))
(interp-fn 1)
(define one-ms (- (now-ms) t0))
(format #t "NC1 1-iteration interp-fn: ~a ms vs 1M-iteration: ~a ms~%"
        one-ms i-ms)
(check "NC1 control: 1M-iteration timing strictly exceeds 1-iteration timing \
(timer distinguishes work)"
       (> i-ms one-ms))

;; ---- record for AUDIT ---------------------------------------------------------------
(when all-boots-ok
  (format #t "PERF-SUMMARY: boot-median-ms=~a eval-us=~a loop-ms=~a \
compiled-ms=~a~%"
          boot-median (/ e1-ms n-eval 0.001) e2-ms c-ms))

(if (zero? fails)
    (format #t "W12-VERDICT: PASS (measurements recorded)~%")
    (format #t "W12-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
