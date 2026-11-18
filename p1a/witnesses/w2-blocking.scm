;; W2 — blocking-GC witness (the gambitffi-blocking-gc gate evidence).
;;
;; p1a-r2 REPAIR of review finding F3. Three modes (first command-line
;; argument); every run is under the external watchdog (watchdog.sh), whose
;; exit 124 is an INDEPENDENT timeout detection and is always a recorded
;; failure. All verdicts are DERIVED from observed state — wrong values,
;; absent handshakes and inconsistencies are FAILURES, never unconditional
;; prints.
;;
;;   ./w2.exe -:d5 control
;;     CONTROL for the machinery. Thread A makes three NON-blocking foreign
;;     calls with sleeps between; thread B performs REAL collections ((##gc)
;;     — the runtime primitive whose c-code calls the documented C API
;;     ___garbage_collect, lib/_kernel.scm:2051-2069 — plus the documented C
;;     API itself via w2-real-gc) while mutating a LIVE ROOTED witness object
;;     between rounds. PASS requires the OBSERVED state: B executed, >=1 B
;;     round started while A had completed <3 calls (real overlap), and all
;;     witness-object mutations intact after the real collections. With -:d5
;;     the runtime's "*** GC:" report lines are the verbatim proof that REAL
;;     collection completed (the adapter's sa-gc-collect no-op cannot
;;     produce these).
;;
;;   ./w2.exe -:d5 qualify
;;     THE QUALIFICATION WITNESS for sa-foreign-procedure-blocking. Both
;;     participants are STARTED AND SYNCHRONIZED BEFORE the foreign call
;;     blocks: thread B is proven EXECUTING on the runtime (an observed flag
;;     set by B's first action, plus its timestamped log line) before A
;;     enters C; B then waits for A's entry signal. A enters the blocking
;;     foreign call (w2-block, 6s C-side deadline). B runs real GC rounds
;;     that MUTATE A LIVE ROOTED OBJECT and calls the C release handshake
;;     FROM SCHEME (w2-release-handshake via c-lambda) ONLY AFTER its first
;;     REAL collection completed. PASS requires the OBSERVED state: C
;;     returned via the handshake (cause=handshake), >=1 B round STARTED
;;     while the C fixture's in-block flag was set, the handshake arrived
;;     during the block, and the witness-object mutations survived real
;;     collections. On the provisioned single-processor build B cannot
;;     execute while C is blocked, so the OBSERVED verdict is FAIL with the
;;     facts recorded (release-cause=deadline, rounds-during-block=0,
;;     handshake-during-block=no) — the documented refusal evidence. The
;;     internal-consistency guards (round counts, handshake counts, witness
;;     slots) turn any incoherent observation into FAIL-INCONSISTENT with a
;;     nonzero exit.
;;
;;   ./w2.exe -:d5 blocked
;;     STARVATION DEMONSTRATION — the P1a variant, kept as a documented
;;     diagnostic: B is started only AFTER A has entered the blocking call,
;;     so on this build every B round can only run after C returns. The
;;     verdict is derived from the same observed-state counters
;;     (rounds-during-block, in-block flag, blocked duration); an
;;     unexpected B progression during the block is flagged UNEXPECTED.

(c-declare #<<c-declare-end

int w2_block (int deadline_seconds);
void w2_release_handshake (void);
int w2_noblock (void);
int w2_handshake_calls_total (void);
int w2_handshake_during_block_total (void);
int w2_in_block_p (void);
int w2_block_blocked_ms (void);

c-declare-end
)

(define w2-block   (c-lambda (int) int "w2_block"))
(define w2-noblock (c-lambda () int "w2_noblock"))
(define w2-release-handshake (c-lambda () void "w2_release_handshake"))
(define w2-handshake-calls (c-lambda () int "w2_handshake_calls_total"))
(define w2-handshake-during-block (c-lambda () int "w2_handshake_during_block_total"))
(define w2-in-block-p (c-lambda () int "w2_in_block_p"))
(define w2-blocked-ms (c-lambda () int "w2_block_blocked_ms"))
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

;; ---- observed-state variables (reset per mode) --------------------------

(define w2-witness-obj (make-vector 4 0)) ; LIVE ROOTED object mutated by B
(define w2-b-executing #f)                ; set by B's FIRST action
(define w2-a-entering #f)                 ; set by A before entering C
(define w2-c-returned #f)                 ; set by A after the C call returned
(define w2-rounds-during-block 0)         ; B rounds STARTED while C was blocked
(define w2-rounds-after 0)                ; B rounds started after C returned
(define w2-rounds-overlapping 0)          ; control: B rounds started while A
                                          ; had completed <3 calls
(define w2-handshake-called #f)           ; did SCHEME call the handshake?
(define w2-a-calls-done 0)                ; control: A's completed call count

(define (w2-reset-state!)
  (set! w2-witness-obj (make-vector 4 0))
  (set! w2-b-executing #f)
  (set! w2-a-entering #f)
  (set! w2-c-returned #f)
  (set! w2-rounds-during-block 0)
  (set! w2-rounds-after 0)
  (set! w2-rounds-overlapping 0)
  (set! w2-handshake-called #f)
  (set! w2-a-calls-done 0))

(define (w2-mutate-witness! i)
  ;; mutate the LIVE ROOTED witness object; the slots must hold the correct
  ;; values AFTER B's real collections, proving the mutations survived GC.
  (vector-set! w2-witness-obj 0 i)
  (vector-set! w2-witness-obj 1 (+ (vector-ref w2-witness-obj 1) 1)))

(define (w2-b-rounds n #!optional (handshake-after-first? #f))
  ;; n real GC rounds: allocate, mutate the rooted witness object, (##gc),
  ;; then the documented C API; optionally call the C release handshake
  ;; FROM SCHEME after the first completed round.
  (let loop ((i 1))
    (if (<= i n)
        (begin
          ;; the round's observation: did it START while C was blocked?
          (if (= (w2-in-block-p) 1)
              (set! w2-rounds-during-block (+ w2-rounds-during-block 1))
              (set! w2-rounds-after (+ w2-rounds-after 1)))
          (if (< w2-a-calls-done 3)
              (set! w2-rounds-overlapping (+ w2-rounds-overlapping 1)))
          (w2-log "W2-B: round " i " t=" (w2-now)
                  " start (c-in-block=" (w2-in-block-p)
                  " a-calls-done=" w2-a-calls-done ")")
          (w2-mutate-witness! i)
          (let ((v (make-vector 200000 0)))
            (vector-set! v 0 i))
          (##gc)
          (let ((r (w2-real-gc)))
            (w2-log "W2-B: round " i " t=" (w2-now)
                    " done (capi-gc-return=" r ")"))
          (if (and handshake-after-first? (= i 1))
              (begin
                (w2-log "W2-B: calling the C release handshake FROM SCHEME after round " i
                        " (real collection completed) t=" (w2-now))
                (w2-release-handshake)
                (set! w2-handshake-called #t)))
          (loop (+ i 1))))))

(define (w2-witness-intact? n)
  (and (= (vector-ref w2-witness-obj 0) n)
       (= (vector-ref w2-witness-obj 1) n)))

;; ---- control -------------------------------------------------------------

(define (w2-control)
  ;; A: non-blocking foreign calls; B: real GC rounds must overlap them.
  (define (a-work)
    (let loop ((i 1))
      (if (<= i 3)
          (begin
            (w2-log "W2-A: non-blocking foreign call " i " t=" (w2-now))
            (w2-noblock)
            (set! w2-a-calls-done (+ w2-a-calls-done 1))
            (thread-sleep! 0.3)
            (loop (+ i 1)))
          (w2-log "W2-A: all non-blocking calls returned"))))
  (w2-reset-state!)
  (let* ((t-b (make-thread (lambda ()
                             (set! w2-b-executing #t)
                             (w2-log "W2-B: executing t=" (w2-now))
                             (w2-b-rounds 3))
                           'w2-b))
         (t-a (make-thread a-work 'w2-a)))
    (thread-start! t-b)
    (thread-start! t-a)
    (thread-join! t-b)
    (thread-join! t-a)
    ;; derive the verdict from the observed state
    (w2-log "W2: observed state: b-executed=" w2-b-executing
            " rounds-overlapping-a-calls=" w2-rounds-overlapping
            " witness-object=(last-round=" (vector-ref w2-witness-obj 0)
            " round-count=" (vector-ref w2-witness-obj 1) ")")
    (if (and w2-b-executing
             (> w2-rounds-overlapping 0)
             (w2-witness-intact? 3))
        (w2-log "W2-CONTROL-VERDICT: PASS (derived from observed state: B executed, "
                w2-rounds-overlapping " of 3 real-GC rounds started while A had completed <3 foreign calls, witness-object mutations intact after real collections; the *** GC: report lines above are the runtime's own collection evidence)")
        (w2-log "W2-CONTROL-VERDICT: FAIL (observed state: b-executed=" w2-b-executing
                " rounds-overlapping=" w2-rounds-overlapping
                " witness-slots=(" (vector-ref w2-witness-obj 0)
                "," (vector-ref w2-witness-obj 1) ") expected=(3,3)"))))

;; ---- qualify (the qualification witness) ----------------------------------

(define (w2-qualify)
  ;; Both participants synchronized BEFORE the foreign call blocks:
  ;;   A (the primordial thread) waits until B is OBSERVED executing;
  ;;   B waits until A signals entry; then A enters C and blocks.
  (w2-reset-state!)
  (let* ((t-b (make-thread
               (lambda ()
                 ;; FIRST action: prove B is executing on the runtime
                 (set! w2-b-executing #t)
                 (w2-log "W2-B: EXECUTING on the runtime t=" (w2-now))
                 ;; synchronized start: wait for A's entry signal
                 (let wait () (if (not w2-a-entering)
                                  (begin (thread-sleep! 0.01) (wait))))
                 (w2-log "W2-B: observed A's entry signal; starting real GC rounds t=" (w2-now))
                 (w2-b-rounds 3 #t))
               'w2-b)))
    (thread-start! t-b)
    ;; A: wait until B is provably executing BEFORE entering C
    (let wait () (if (not w2-b-executing)
                     (begin (thread-sleep! 0.01) (wait))))
    (w2-log "W2-A: OBSERVED B executing on the runtime (synchronized) t=" (w2-now))
    (set! w2-a-entering #t)
    (w2-log "W2-A: entering blocking foreign call (B synchronized and executing) t=" (w2-now))
    (let ((cause (w2-block 6)))
      (set! w2-c-returned #t)
      (w2-log "W2-A: foreign call returned t=" (w2-now)
              " release-cause=" (if (= cause 0) "handshake" "deadline"))
      (thread-join! t-b)
      ;; derive the verdict from the OBSERVED state
      (let* ((hc (w2-handshake-calls))
           (hd (w2-handshake-during-block))
           (bms (w2-blocked-ms))
           (rounds-total (+ w2-rounds-during-block w2-rounds-after))
           (consistent (and (= rounds-total 3)
                            (= (vector-ref w2-witness-obj 0) 3)
                            (= (vector-ref w2-witness-obj 1) 3)
                            w2-b-executing
                            w2-handshake-called
                            (= hc 1)
                            ;; a handshake release must have arrived during
                            ;; the block, and vice versa (one handshake call)
                            (eq? (= cause 0) (= hd 1))))
           (qualified (and (= cause 0)
                           (> w2-rounds-during-block 0)
                           (= hd 1)
                           (w2-witness-intact? 3))))
      (w2-log "W2: observed state: release-cause=" (if (= cause 0) "handshake" "deadline")
              " rounds-during-block=" w2-rounds-during-block
              " rounds-after=" w2-rounds-after
              " handshake-called-from-scheme=" w2-handshake-called
              " capi-handshake-calls=" hc
              " handshake-during-block=" hd
              " blocked-ms=" bms
              " witness-object=(last-round=" (vector-ref w2-witness-obj 0)
              " round-count=" (vector-ref w2-witness-obj 1) ")")
      (cond ((not consistent)
             (w2-log "W2-QUALIFY-VERDICT: FAIL-INCONSISTENT (observation machinery disagreed with itself: rounds-total=" rounds-total
                     " handshake-calls=" hc
                     " handshake-during-block=" hd
                     " cause-0=" (= cause 0) ")")
             (exit 3))
            (qualified
             (w2-log "W2-QUALIFY-VERDICT: PASS (blocking qualified: C returned via the Scheme-called handshake after B completed real collections DURING the block; rounds-during-block=" w2-rounds-during-block
                     "; witness-object mutations intact)"))
            (else
             (w2-log "W2-QUALIFY-VERDICT: FAIL (blocking unqualified on this build: release-cause="
                     (if (= cause 0) "handshake" "deadline")
                     ", rounds-during-block=" w2-rounds-during-block
                     ", handshake-during-block=" hd
                     "; B was synchronized and provably executing BEFORE A entered C, but completed all rounds only AFTER the foreign call returned — the handshake was called from Scheme only after B's real collections, which on this build can only happen after C returned; astra §2 'actual collection and another Scheme thread's progress while C remains blocked' is not satisfied)")))))))

;; ---- starvation demonstration (P1a diagnostic variant, kept) --------------

(define (w2-blocked)
  ;; A: blocking foreign call with 6s C-side deadline.
  ;; B: started only AFTER A enters (the P1a design) — the starvation demo.
  (w2-reset-state!)
  (let* ((t-a (make-thread (lambda ()
                             (w2-log "W2-A: entering blocking foreign call t=" (w2-now))
                             (let ((cause (w2-block 6)))
                               (set! w2-c-returned #t)
                               (w2-log "W2-A: foreign call returned t=" (w2-now)
                                       " release-cause=" (if (= cause 0) "handshake" "deadline"))))
                           'w2-a))
         (t-b (make-thread (lambda ()
                             (set! w2-b-executing #t)
                             (w2-log "W2-B: executing (started AFTER A entered — starvation demo) t=" (w2-now))
                             (w2-b-rounds 3))
                           'w2-b)))
    (thread-start! t-a)
    (let ((t-block-start (w2-now)))
      ;; give A a moment to enter the foreign call, then make B runnable
      (thread-sleep! 0.3)
      (thread-start! t-b)
      (thread-join! t-b)
      (thread-join! t-a)
      (w2-log "W2: blocked window from t=" t-block-start " to t=" (w2-now))
      (let ((bms (w2-blocked-ms)))
        (w2-log "W2: observed state: rounds-during-block=" w2-rounds-during-block
                " rounds-after=" w2-rounds-after
                " blocked-ms=" bms
                " witness-object=(last-round=" (vector-ref w2-witness-obj 0)
                " round-count=" (vector-ref w2-witness-obj 1) ")")
        (if (and (= w2-rounds-during-block 0)
                 (>= bms 5500)
                 (w2-witness-intact? 3))
            (w2-log "W2-STARVATION-DEMO-VERDICT: STARVATION-DEMONSTRATED (derived: " w2-rounds-during-block " rounds started while the C fixture's in-block flag was set; blocked " bms "ms — the whole deadline; every W2-B line above appears after 'W2C: foreign call RETURNING'; the qualification witness is the w2-qualify mode, not this diagnostic)")
            (begin
              (w2-log "W2-STARVATION-DEMO-VERDICT: UNEXPECTED (observed state contradicts the documented starvation: rounds-during-block=" w2-rounds-during-block
                      " blocked-ms=" bms
                      " — B progressed during the block; investigate before reusing this variant)")
              (exit 2)))))))

(define (w2-run mode)
  (w2-log "=== W2 blocking-GC witness (p1a-r2): mode=" mode " ===")
  (w2-log "W2: t=" (w2-now) " start")
  (case mode
    ((control) (w2-control))
    ((qualify) (w2-qualify))
    ((blocked) (w2-blocked))
    (else
     (w2-log "W2-usage: ./w2.exe -:d5 control|qualify|blocked")
     (exit 2))))

;; compiled exe: the mode is the first non-(-:) command-line argument
(let ((args (command-line)))
  (w2-run (cond
           ((and (pair? args)
                 (member (car args) '("control" "qualify" "blocked")))
            (string->symbol (car args)))
           ((and (pair? args) (pair? (cdr args))
                 (member (cadr args) '("control" "qualify" "blocked")))
            (string->symbol (cadr args)))
           (else 'usage))))
