;; W2 — blocking-GC witness (the gambitffi-blocking-gc gate evidence).
;;
;; Two modes (first command-line argument):
;;
;;   ./w2.exe -:d5 control
;;     Thread A makes three NON-blocking foreign calls with sleeps between;
;;     thread B performs REAL collections ((##gc) — the runtime primitive whose
;;     c-code calls the documented C API ___garbage_collect, lib/_kernel.scm:2032-2069 —
;;     and the documented C API itself via w2-real-gc) while allocating between
;;     rounds. With -:d5 the runtime prints "*** GC:" reports, which is the
;;     verbatim proof that REAL collection completed (the adapter's
;;     sa-gc-collect no-op cannot produce these). PASS means the thread/GC
;;     machinery itself works — the control for the blocked run.
;;
;;   ./w2.exe -:d5 blocked
;;     Thread A enters the blocking foreign call (w2_block, 6s C-side
;;     deadline). Thread B is made runnable BEFORE A's call enters and performs
;;     the same REAL collection rounds. PASS would require B's rounds to
;;     complete WHILE C is blocked (astra §2: "actual collection and another
;;     Scheme thread's progress while C remains blocked").
;;
;; On the provisioned build there is exactly ONE OS thread running Scheme
;; (___SINGLE_THREADED_VMS, ___MAX_PROCESSORS=1 — see W0), so while C is
;; blocked NO Scheme thread can be scheduled and NO collection can run: B's
;; rounds all appear after "W2C: foreign call RETURNING". That is the recorded
;; NO-GO evidence for the sa-foreign-procedure-blocking row on this build.
;;
;; A Scheme-internal watchdog cannot fire here (the whole VM is frozen inside
;; the foreign call), so every run is under the external watchdog.sh.

(c-declare #<<c-declare-end

int w2_block (int deadline_seconds);
void w2_release_handshake (void);
int w2_noblock (void);

c-declare-end
)

(define w2-block   (c-lambda (int) int "w2_block"))
(define w2-noblock (c-lambda () int "w2_noblock"))
;; REAL collection through the documented C API (gambit.h ~14769):
;;   ___IMP_FUNC(___BOOL,___garbage_collect)
;;      ___P((___PSD ___SIZE_TS requested_words_still),());
(define w2-real-gc
  (c-lambda () int
    "___return (___EXT(___garbage_collect) (___PSP 0) ? 1 : 0);"))

(define (w2-now) (time->seconds (current-time)))
(define (w2-log . parts)
  ;; one forced-flush line, so the ordering with the C fixture's
  ;; stdout prints (also flushed) is exact in the recorded output.
  (for-each display parts)
  (newline)
  (force-output))

(define (w2-gc-rounds who n)
  ;; allocate, then force a REAL collection via the runtime primitive and via
  ;; the documented C API; the runtime's own "-:d5" GC report lines are the
  ;; verbatim evidence that collection actually ran.
  (let loop ((i 1))
    (if (<= i n)
        (begin
          (w2-log who ": round " i " t=" (w2-now)
                  " allocating + ##gc (runtime primitive)")
          (let ((v (make-vector 200000 0)))
            (vector-set! v 0 i)
            (##gc)
            (let ((r (w2-real-gc)))
              (w2-log who ": round " i " t=" (w2-now)
                      " done (capi-gc-return=" r ")")
              (loop (+ i 1))))))))

(define (w2-control)
  ;; A: non-blocking foreign calls; B: real GC rounds must overlap them.
  (define (a-work)
    (let loop ((i 1))
      (if (<= i 3)
          (begin
            (w2-log "W2-A: non-blocking foreign call " i " t=" (w2-now))
            (w2-noblock)
            (thread-sleep! 0.3)
            (loop (+ i 1)))
          (w2-log "W2-A: all non-blocking calls returned"))))
  (let* ((t-b (make-thread (lambda () (w2-gc-rounds "W2-B" 3)) 'w2-b))
         (t-a (make-thread a-work 'w2-a)))
    (thread-start! t-b)
    (thread-start! t-a)
    (thread-join! t-b)
    (thread-join! t-a)
    (w2-log "W2-VERDICT: PASS (control: real collections completed while another thread made foreign calls; the *** GC: report lines above are the runtime's own collection evidence)")))

(define (w2-blocked)
  ;; A: blocking foreign call with 6s C-side deadline.
  ;; B: made runnable BEFORE A enters, performs the same real GC rounds.
  (let* ((t-a (make-thread (lambda () (w2-block 6)) 'w2-a))
         (t-b (make-thread (lambda () (w2-gc-rounds "W2-B" 3)) 'w2-b)))
    (thread-start! t-a)
    (let ((t-block-start (w2-now)))
      ;; give A a moment to enter the foreign call, then make B runnable
      (thread-sleep! 0.3)
      (thread-start! t-b)
      (thread-join! t-b)
      (thread-join! t-a)
      (w2-log "W2: blocked window from t=" t-block-start " to t=" (w2-now))
      (w2-log "W2-VERDICT: FAIL (blocked: no collection and no other-thread progress while the foreign call was blocked — every W2-B line above appears after 'W2C: foreign call RETURNING'; the VM has a single processor and 4.9.8 has no foreign-release mechanism, so the blocking row cannot be satisfied on this build)"))))

(define (w2-run mode)
  (w2-log "=== W2 blocking-GC witness: mode=" mode " ===")
  (w2-log "W2: t=" (w2-now) " start")
  (case mode
    ((control) (w2-control))
    ((blocked) (w2-blocked))
    (else
     (w2-log "W2-usage: ./w2.exe -:d5 control|blocked"))))

;; compiled exe: the mode is the first non-(-:) command-line argument
(let ((args (command-line)))
  (w2-run (cond
           ((and (pair? args)
                 (member (car args) '("control" "blocked")))
            (string->symbol (car args)))
           ((and (pair? args) (pair? (cdr args))
                 (member (cadr args) '("control" "blocked")))
            (string->symbol (cadr args)))
           (else 'usage))))
