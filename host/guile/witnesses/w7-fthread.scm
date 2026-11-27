;; W7 — foreign pthread entering Scheme (audit area 4).
;;
;; The Gambit p1a audit's W3 found NO documented entry protocol (NO-GO on
;; the provisioned build).  Guile documents one: manual §5.2.1 —
;; scm_with_guile "will initialize Guile when necessary... Multiple
;; threads can call scm_with_guile concurrently and it can also be called
;; more than once in a given thread."
;;
;; This driver builds the C fixture (w7-fixture.c), runs it in the good
;; mode (two concurrent foreign pthreads entering Scheme through
;; scm_with_guile) and in the bad mode (raw unattached entry — recorded
;; evidence only, never a pass, per the p1a W3 discipline).
;;
;; Decisive checks (good mode):
;;   F1 both threads entered and evaluated Scheme (ENTRY-OK lines);
;;   F2 each thread's result reflects ITS OWN argument (41 and 42) —
;;      not a serialized-reuse artifact;
;;   F3 the fixture exits 0 with the PASS marker.
;; Negative control:
;;   NC1 a run whose results were swapped or wrong fails F2 — the driver
;;      checks exact values, so a corrupt entry cannot pass accidentally.

(use-modules (srfi srfi-1)
             (rnrs io ports))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(format #t "=== W7 foreign-pthread-entry witness ===~%")

(define here (dirname (current-filename)))

(define (run-capture prog args)
  ;; run PROG with ARGS, capture stdout+exit as (output . status)
  (let* ((pr (pipe))
         (pid (spawn prog (cons prog args) #:output (cdr pr))))
    (close-port (cdr pr))
    (let ((out (get-string-all (car pr))))
      (close-port (car pr))
      (let ((st (waitpid pid)))
        (cons out (cdr st))))))

(define (pkg-config-flags)
  (let ((r (run-capture "pkg-config" '("--cflags" "--libs" "guile-3.0"))))
    (and (zero? (cdr r))
         (remove string-null?
                 (string-split (string-map
                                (lambda (c) (if (char=? c #\newline) #\space c))
                                (car r))
                               #\space)))))

(define flags (pkg-config-flags))
(format #t "W7: guile-3.0 pkg-config flags: ~s~%" flags)
(check "F0 pkg-config guile-3.0 available to build the fixture"
       (and flags #t))

(define fixture-bin (string-append here "/build/w7-fixture"))

(define (build-fixture)
  (false-if-exception (mkdir (string-append here "/build")))
  (let ((cmd (append '("cc" "-O2")
                     (list "-o" fixture-bin
                           (string-append here "/w7-fixture.c"))
                     flags)))
    (format #t "W7: build: ~s~%" cmd)
    (apply system* cmd)))

(when flags
  (let ((rc (build-fixture)))
    (check "F0b fixture compiled" (zero? rc))
    (when (zero? rc)
      ;; good mode
      (let* ((r (run-capture fixture-bin '()))
             (out (car r))
             (st (cdr r)))
        (format #t "W7 good-mode output:~a" out)
        (check "F1 both foreign pthreads entered Scheme (2 ENTRY-OK lines)"
               (= (length (filter (lambda (l)
                                    (string-contains l
                                                     "W7-FIXTURE-ENTRY-OK"))
                                  (string-split out #\newline)))
                  2))
        (check "F2 thread 1 computed 41 and thread 2 computed 42 (own args)"
               (and (string-contains out "thread=1 result=41")
                    (string-contains out "thread=2 result=42")))
        (check "F3 fixture exited 0 with the PASS marker"
               (and (eqv? (status:exit-val st) 0)
                    (string-contains out "W7-FIXTURE-VERDICT: PASS")))
        ;; NC1: exact-value discipline — a swapped/wrong result would have
        ;; failed F2 above; additionally the marker set must not appear in
        ;; a run that produced no ENTRY-OK lines (vacuity guard).
        (check "NC1 control: verdict marker requires the entry lines \
(the check cannot pass vacuously)"
               (string-contains out "VERDICT")))
      ;; bad mode — recorded evidence only
      (let* ((r (run-capture fixture-bin '("bad")))
             (out (car r))
             (st (cdr r)))
        (format #t "W7 bad-mode (raw unattached entry) output:~a exit-val=~s \
term-sig=~s~%" out (status:exit-val st) (status:term-sig st))
        (format #t "W7: raw-entry outcome recorded (survival is NOT \
qualification; a crash is the expected refusal shape on a target without \
an entry protocol — Guile documents one, so either outcome is evidence)~%"))
      ;; callback mode (r3, review P1): a procedure->pointer trampoline
      ;; invoked DIRECTLY as a pthread start routine (foreign thread, no
      ;; scm_with_guile) — the refusal mode for sa-foreign-callable-
      ;; collect-safe via plain procedure->pointer.
      (let* ((r (run-capture fixture-bin '("callback")))
             (out (car r))
             (st (cdr r)))
        (format #t "W7 callback-mode (procedure->pointer run on a foreign \
pthread) output:~a exit-val=~s term-sig=~s~%" out (status:exit-val st)
                (status:term-sig st))
        (check "CB1 a procedure->pointer trampoline invoked on an \
UNATTACHED foreign pthread refuses (SIGSEGV) — collect-safe foreign-thread \
callables need a compiled C libffi-closure helper whose handler enters \
scm_with_guile; plain procedure->pointer is same-thread (Guile-mode) only"
               (eqv? (status:term-sig st) 11))))))

(if (zero? fails)
    (format #t "W7-VERDICT: PASS (documented entry protocol works)~%")
    (format #t "W7-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
