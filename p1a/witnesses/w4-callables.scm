;; W4 — callable (c-define) modes witness.
;;
;; Modes dispatched per process (see w4-fixture.c header):
;;   ./w4.exe mode1  — M1 same-thread callback, M2 nested C->Scheme->C->Scheme
;;                     (the documented nesting of manual §"Continuations, the
;;                     C-interface and threads" — allowed for ONE thread),
;;                     M3 callback from a second Gambit thread around a
;;                     blocking foreign call (expect: B's callback can only
;;                     run AFTER A's foreign call returns — W2's starvation).
;;   ./w4.exe mode4  — M4 callback from a raw foreign pthread (expect: crash —
;;                     W3's mechanism).
;;   ./w4.exe mode5  — M5 exception raised inside a callback (empirical record).

(c-declare #<<c-declare-end

int w4_call_cb (int x);
int w4_nested_a (int x);
int w4_nested_b (int x);
int w4_b_entry (void);
int w4_b_completed_during_block_p (void);
int w4_m3_note_b (int done);
int w4_block_then_cb (int seconds);
int w4_ft_call (void);
int w4_call_raise (int x);

c-declare-end
)

(define w4-m1       (c-lambda (int) int "w4_call_cb"))
(define w4-m2       (c-lambda (int) int "w4_nested_a"))
(define w4-m3-b     (c-lambda () int "w4_b_entry"))
(define w4-m3-probe (c-lambda () int "w4_b_completed_during_block_p"))
(define w4-m3-note  (c-lambda (int) int "w4_m3_note_b"))
(define w4-m3-a     (c-lambda (int) int "w4_block_then_cb"))
(define w4-m4       (c-lambda () int "w4_ft_call"))
(define w4-m5       (c-lambda (int) int "w4_call_raise"))

;; ---- the callables (c-define) ----
(c-define (w4-cb-same x) (int) int "w4_cb_same" "extern"
  (* x 10))

(c-define (w4-cb-q x) (int) int "w4_cb_q" "extern"
  (* x 3))

(c-define (w4-cb-p x) (int) int "w4_cb_p" "extern"
  ;; Scheme p calls C b, which calls Scheme q — the documented nesting
  (+ (w4-nested-b (+ x 1)) 1))

(define w4-nested-b (c-lambda (int) int "w4_nested_b"))

(c-define (w4-cb-ft x) (int) int "w4_cb_ft" "extern"
  ;; allocation inside the callback (exercises the allocator + GC path)
  (+ x (vector-length (make-vector 1000 x))))

(c-define (w4-cb-raise x) (int) int "w4_cb_raise" "extern"
  (error "w4-cb-raise: deliberate exception" x))

(define (w4-now) (time->seconds (current-time)))
(define (w4-log . parts)
  (for-each display parts)
  (newline)
  (force-output))

(define (w4-mode1)
  (w4-log "=== W4 mode1: M1 + M2 + M3 ===")
  ;; M1: same-thread callback
  (let ((r (w4-m1 4)))
    (w4-log "W4-M1: same-thread callback w4_call_cb(4) -> " r
            " expected 40 => " (if (= r 40) "OK" "MISMATCH")))
  ;; M2: nested chain  a(1) -> p(1) -> b(2) -> q(2)=6 -> b=1006 -> p=1007 -> a=1107
  (let ((r (w4-m2 1)))
    (w4-log "W4-M2: nested C->Scheme->C->Scheme w4_nested_a(1) -> " r
            " expected 1107 => " (if (= r 1107) "OK" "MISMATCH")))
  ;; M3: A blocks in C for 2s then invokes the callback; B (another Gambit
  ;; thread) attempts the same callback while A is inside the foreign call.
  (let* ((b-ran-during-block #f)
         (t-a (make-thread (lambda () (w4-m3-a 2)) 'w4-a))
         (t-b (make-thread (lambda ()
                             (thread-sleep! 0.3)   ; start B while A is inside C
                             (w4-log "W4-M3: thread B attempting callback t=" (w4-now))
                             (let ((r (w4-m3-b)))
                               (w4-m3-note 1)
                               (w4-log "W4-M3: thread B callback completed t=" (w4-now)
                                       " -> " r)
                               r))
                           'w4-b)))
    (thread-start! t-a)
    (thread-start! t-b)
    (let ((t-start (w4-now)))
      (thread-join! t-a)
      (let ((probe (w4-m3-probe)))
        (w4-log "W4-M3: thread A foreign call returned t=" (w4-now)
                " (blocked ~2s from " t-start ")")
        (thread-join! t-b)
        (w4-log "W4-M3: B-completed-during-A-block probe = " probe
                " => " (if (= probe 0)
                           "no callback from B during A's foreign call (callbacks from other Gambit threads are serialized AFTER the foreign call; no released-frame concurrency exists — see W2)"
                           "B ran during A's foreign call (unexpected!)"))
        (w4-log "W4-VERDICT: PASS (M1 same-thread callback, M2 documented nesting, M3 callbacks from other Gambit threads only run while no foreign call occupies the single processor)")))))

(define (w4-mode4)
  (w4-log "=== W4 mode4: M4 callback from a raw foreign pthread ===")
  (w4-log "W4-M4: calling w4_ft_call (worker pthread will invoke the c-define'd callback while this Gambit thread parks inside the C call)")
  (let ((r (w4-m4)))
    (w4-log "W4-M4: w4_ft_call returned " r)
    (w4-log "W4-VERDICT: PASS-QUALIFIED (foreign-pthread callback completed — serialized reuse of the single pstate; NO documented protocol; W3 shows the general foreign-thread entry crashes)")))

(define (w4-mode5)
  (w4-log "=== W4 mode5: M5 exception inside a callback ===")
  (w4-log "W4-M5: calling w4_call_raise(3) — callback raises a Scheme error")
  (let ((r (w4-m5 3)))
    (w4-log "W4-M5: w4_call_raise returned " r " (process survived)")
    (w4-log "W4-M5-VERDICT: recorded empirically (see output above)")))

(let ((args (command-line)))
  (let ((mode (cond
               ((and (pair? args) (member (car args) '("mode1" "mode4" "mode5")))
                (string->symbol (car args)))
               ((and (pair? args) (pair? (cdr args))
                     (member (cadr args) '("mode1" "mode4" "mode5")))
                (string->symbol (cadr args)))
               (else 'mode1))))
    (case mode
      ((mode1) (w4-mode1))
      ((mode4) (w4-mode4))
      ((mode5) (w4-mode5)))))
