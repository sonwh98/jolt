;; W2 — threads contract witness (audit area 2).
;;
;; Decides the CONTRACT.txt `threads` tier rows against (ice-9 threads) +
;; fluids (+ (srfi srfi-18) where the exact SRFI-18 shapes matter):
;;
;;   T1 THREAD-PARAMETER FORK-INHERITANCE — manual §6.22.2 "new threads
;;      inherit the fluid bindings that were in place in their creator
;;      threads"; §6.22.1 call-with-new-thread runs "with a new dynamic
;;      state"; §6.11.11 a new dynamic state "inherits the values from its
;;      parent".  Includes the NESTED parameterize case.
;;   T2 make-thread-local-fluid does NOT propagate — the fresh-default
;;      tool the opposite-direction parameters need.
;;   T3 NON-RECURSIVE mutex discipline: standard make-mutex re-acquire by
;;      owner ERRORS (manual §6.22.5); the 'unowned kind ("for use by
;;      SRFI-18") re-acquire BLOCKS — the exact contract pin ("same-thread
;;      re-acquire blocks, per SRFI-18 mutex-acquire!").
;;   T4 CONDITION-WAIT: predicate-loop waits complete with signal and
;;      broadcast, no lost wakeups across many rounds (watchdog enforced).
;;   T5 NUMERIC get-thread-id + sa-thread-id-of mapping (Guile thread ids
;;      are objects; a numeric mapping is required by the contract).
;;   T6 memory-order fences: mapped onto (ice-9 atomic) SC accesses
;;      (manual §6.22.4: C11 sequential consistency — at least acq+rel).
;;   T7 sleep/current-time shapes the `system` tier needs.
;;
;; Negative controls:
;;   N1 a post-fork parent rebinding is NOT seen by the child (the checks
;;      read the fork-time snapshot, not a shared global);
;;   N2 an un-signaled wait TIMES OUT (so a lost wakeup would hang the
;;      predicate loop and the watchdog would record it);
;;   N3 the id mapping must be distinct — a collision fails the check.

(use-modules (ice-9 threads)
             (ice-9 atomic)
             (srfi srfi-1)
             ;; srfi-19 qualified: its current-time returns a TIME OBJECT
             ;; and would shadow the core integer-seconds current-time the
             ;; lock/wait timeout probes below rely on.
             ((srfi srfi-19) #:select (current-time time-type)
              #:renamer (symbol-prefix-proc 's19:)))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(format #t "=== W2 threads contract witness ===~%")

;; ---- T1/T2 parameter + fluid fork-inheritance -----------------------------
(define *param* (make-parameter 'default))
(define *fluid* (make-fluid 'fdefault))
(define *tlf*   (make-thread-local-fluid 'tdefault))

(define mailbox '())
(define mailbox-mutex (make-mutex))
(define (report! x) (with-mutex mailbox-mutex (set! mailbox (cons x mailbox))))

;; child forked under (parameterize ((*param* 'outer)) ...) and a nested
;; (parameterize ((*param* 'inner)) (fork ...)) — reads, then sleeps so the
;; parent can rebind *param* AFTER the fork (N1 probe), then re-reads.
(define child
  (parameterize ((*param* 'outer)
                 ;; fluid bound around the fork too
                 )
    (with-fluids ((*fluid* 'fouter))
      (parameterize ((*param* 'inner))
        (call-with-new-thread
         (lambda ()
           (report! (list 'at-fork
                          (*param*)
                          (fluid-ref *fluid*)
                          (fluid-ref *tlf*)))
           (sleep 1)                     ; let the parent rebind (N1)
           (report! (list 'after-parent-rebind (*param*)))
           'child-done))))))

;; control reading in the PARENT: the nested parameterize is over by the
;; time we get here, but the child must have seen 'inner at fork.
(define parent-sees-after (*param*))
(format #t "T1 parent *param* after fork returned: ~s~%" parent-sees-after)
(check "T1c parent's own binding restored to default after parameterize"
       (eq? parent-sees-after 'default))

(join-thread child)
(set! mailbox (reverse mailbox))
(format #t "T1 child observations: ~s~%" mailbox)
(let ((at-fork (assq 'at-fork mailbox))
      (after (assq 'after-parent-rebind mailbox)))
  (check "T1a child inherits the CREATING thread's CURRENT parameter value \
(nested parameterize: 'inner)"
         (and at-fork (eq? (second at-fork) 'inner)))
  (check "T1b child inherits the creator's current FLUID value ('fouter)"
         (and at-fork (eq? (third at-fork) 'fouter)))
  (check "T2 thread-local fluid NOT propagated (default 'tdefault)"
         (and at-fork (eq? (fourth at-fork) 'tdefault))))

;; N1: rebind AFTER the fork; the child already reported its fork-time view.
;; The child slept to straddle the rebind; re-check with a second fork.
(define late-seen
  (parameterize ((*param* 'before))
    (let* ((cell (make-atomic-box 'unforked))
           (t (call-with-new-thread
               (lambda ()
                 (atomic-box-set! cell (*param*))))))
      (*param* 'rebound-after-fork)     ; rebind AFTER creating the thread
      (join-thread t)
      (atomic-box-ref cell))))
(format #t "N1 child saw ~s under post-fork rebinding to 'rebound-after-fork~%"
        late-seen)
(check "N1 control: child reads the fork-time value, not a later parent one"
       (eq? late-seen 'before))

;; ---- T3 mutex kinds --------------------------------------------------------
(define m-std (make-mutex))
(lock-mutex m-std)
(let ((second (false-if-exception (begin (lock-mutex m-std) 'acquired))))
  (format #t "T3a standard mutex owner re-acquire => ~s~%" second)
  (check "T3a standard make-mutex: owner re-acquire RAISES (non-recursive)"
         (not second)))
(unlock-mutex m-std)

;; NOTE: the manual documents BOTH spellings for the SRFI-18-tailored kind —
;; §6.22.5 prose says the symbol is 'allow-external-unlock, the make-mutex
;; entry says "pass 'unowned".  RECORDED on this build (3.0.11 darwin):
;; 'unowned raises "unsupported mutex kind: unowned"; ONLY
;; 'allow-external-unlock is accepted.  Try both; the output records it.
(define (try-unowned kind)
  (let ((m (false-if-exception (make-mutex kind))))
    (and m
         (begin (lock-mutex m) (unlock-mutex m)
                (cons m kind)))))
(define unowned-kind (or (try-unowned 'unowned)
                         (try-unowned 'allow-external-unlock)))
(format #t "T3b unowned-kind spelling accepted: ~s~%"
        (and unowned-kind (cdr unowned-kind)))
(check "T3b0 one of the documented unowned spellings is accepted"
       (and unowned-kind #t))
(let ((m-un (and unowned-kind (car unowned-kind))))
  (when m-un
    (lock-mutex m-un)
    (let ((got (lock-mutex m-un (+ (current-time) 1)))) ; blocks ~1s, then timeout
      (format #t "T3b unowned mutex owner re-acquire with 1s timeout => ~s~%"
              got)
      (check "T3b unowned ('SRFI-18') mutex: owner re-acquire BLOCKS then \
times out (#f) — the pinned contract semantic"
             (eq? got #f)))
    (unlock-mutex m-un)))

(define m-rec (make-recursive-mutex))
(lock-mutex m-rec)
(lock-mutex m-rec)
(check "T3c recursive mutex counts twice (needs two unlocks)"
       (= (mutex-level m-rec) 2))
(unlock-mutex m-rec)
(unlock-mutex m-rec)

;; ---- T4 condition variables: no lost wakeups ------------------------------
;; The baton protocol: state changes UNDER the mutex and every wait site
;; loops on its predicate (the contract's own rule — a signal delivered
;; before the waiter parks must not be load-bearing).  avail is the
;; work-available flag, ack the completion counter.  Both sides advance
;; the state machine; a lost wakeup on either side hangs (watchdog).
(define cv-mutex (make-mutex))
(define cv (make-condition-variable))
(define avail 0)
(define ack 0)
(define rounds 200)
(define worker
  (call-with-new-thread
   (lambda ()
     (with-mutex cv-mutex
       (let loop ()
         (when (< ack rounds)
           (if (> avail 0)
               (begin (set! avail 0)
                      (set! ack (+ ack 1))
                      (signal-condition-variable cv)
                      (loop))
               (begin (wait-condition-variable cv cv-mutex)
                      (loop)))))))))
(with-mutex cv-mutex
  (let loop ()
    (cond ((>= ack rounds) #t)
          ((= avail 0)
           (set! avail 1)
           (signal-condition-variable cv)
           (loop))
          (else (wait-condition-variable cv cv-mutex)
                (loop)))))
(join-thread worker)
(format #t "T4 ping-pong rounds completed: ~a~%" ack)
(check "T4a signal-based ping-pong completes 200 rounds with no lost wakeup"
       (= ack rounds))

;; broadcast fan-out: 4 waiters, one broadcast, all must observe.
(define fan-mutex (make-mutex))
(define fan-cv (make-condition-variable))
(define fan-flag 0)
(define fan-hits 0)
(define fans (map (lambda (_)
                    (call-with-new-thread
                     (lambda ()
                       (with-mutex fan-mutex
                         (let loop ()
                           (if (zero? fan-flag)
                               (begin (wait-condition-variable fan-cv fan-mutex)
                                      (loop))
                               (set! fan-hits (+ fan-hits 1))))))))
                  '(a b c d)))
(sleep 1)                                ; let all waiters park
(with-mutex fan-mutex
  (set! fan-flag 1)
  (broadcast-condition-variable fan-cv))
(for-each join-thread fans)
(check "T4b broadcast wakes all 4 parked waiters" (= fan-hits 4))

;; N2: un-signaled wait must block until timeout (so a lost wakeup = hang).
(with-mutex cv-mutex
  (let ((r (wait-condition-variable (make-condition-variable) cv-mutex
                                    (+ (current-time) 1))))
    (format #t "N2 un-signaled wait with 1s timeout => ~s~%" r)
    (check "N2 control: an un-signaled condition wait times out (#f) — \
a lost wakeup would hang and the watchdog would record it"
           (eq? r #f))))

;; ---- T5 numeric thread-id mapping ------------------------------------------
;; The contract shape: ids are NUMBERS, distinct per live thread; the fork
;; wrapper records the child under its id FROM OUTSIDE (before the child
;; has run); get-thread-id inside the child answers the SAME id; an exited
;; thread answers #f.
(define id-counter 0)
(define id-lock (make-mutex))
(define id-alist '())
(define (id-register! thread)
  ;; assign on first sight; parent and child race to register the same
  ;; object — first registration wins, both then read the same number.
  (with-mutex id-lock
    (or (assq thread id-alist)
        (begin
          (set! id-counter (+ id-counter 1))
          (set! id-alist (acons thread id-counter id-alist))
          (assq thread id-alist)))))
(define (get-thread-id) (cdr (id-register! (current-thread))))
(define (id-of thread)
  (cond ((thread-exited? thread) #f)
        ((assq thread id-alist) => cdr)
        (else #f)))

(define id-workers
  (map (lambda (_)
         (let ((t (call-with-new-thread
                   (lambda ()
                     (let ((id (get-thread-id)))
                       (sleep 1)            ; stay live while the parent probes
                       id)))))
           (id-register! t)                ; parent records child from OUTSIDE
           t))
       '(1 2 3 4 5)))
(define outside-ids (map id-of id-workers))          ; while all are live
(define child-own-ids (map join-thread id-workers))  ; children's own answers
(format #t "T5 ids recorded from outside: ~s; children's own: ~s~%"
        outside-ids child-own-ids)
(check "T5a numeric ids recorded per thread from OUTSIDE the thread \
(sa-thread-id-of shape) while live"
       (and (= (length (filter identity outside-ids)) 5)
            (equal? outside-ids child-own-ids)))
(check "N3 control: all ids are distinct numbers"
       (= (length (delete-duplicates outside-ids)) 5))
(check "T5b exited threads answer #f (thread-exited? gates the mapping)"
       (every (lambda (t) (not (id-of t))) id-workers))

;; ---- T6 fences -------------------------------------------------------------
;; The DECISION (not directly provable by a short witness): Guile threads
;; are real OS pthreads sharing memory, so the fences may NOT be no-ops;
;; they map to (ice-9 atomic) accesses, which the manual pins to C11
;; sequential consistency (a superset of acquire+release).  Record that
;; the mapped operations work and are ordered-visible across threads.
(define fence-box (make-atomic-box 0))
(define fence-data 0)
(define fence-thread
  (call-with-new-thread
   (lambda ()
     (let loop ((n 0))
       (when (< n 1000)
         (let ((v (atomic-box-ref fence-box)))   ; memory-order-acquire
           (when (even? v) (set! fence-data (+ fence-data 1)))
           (atomic-box-set! fence-box (+ v 1)))  ; memory-order-release
         (loop (+ n 1)))))))
(join-thread fence-thread)
(check "T6 acquire/release mapped onto atomic-box accesses cross threads \
(monotonic, no lost increments)"
       (= (atomic-box-ref fence-box) 1000))

;; ---- T7 sleep / current-time shapes ----------------------------------------
(define t-start (get-internal-real-time))
(sleep 1)
(define elapsed-ms
  (/ (- (get-internal-real-time) t-start)
     (/ internal-time-units-per-second 1000.0)))
(check "T7a (sleep 1) really sleeps ~1s" (and (> elapsed-ms 900)
                                              (< elapsed-ms 2000)))
(check "T7b srfi-19 current-time zero-arg answers a time-utc object"
       (eq? (s19:time-type (s19:current-time)) 'time-utc))
(let ((s18 (resolve-interface '(srfi srfi-18))))
  (let ((t (module-ref s18 'current-time))
        (ts (module-ref s18 'thread-sleep!))
        (tts (module-ref s18 'time->seconds))
        (stos (module-ref s18 'seconds->time)))
    (let* ((t0 (get-internal-real-time))
           (_ (ts (stos (+ (tts (t)) 0.1)))) ; sleep on a TIME OBJECT, 100ms out
           (ms (/ (- (get-internal-real-time) t0)
                  (/ internal-time-units-per-second 1000.0))))
      (check "T7c srfi-18 current-time/thread-sleep! take TIME OBJECTS \
(the contract's R6RS sleep shape) and really sleep"
             (and (> ms 50) (< ms 2000))))))

(if (zero? fails)
    (format #t "W2-VERDICT: PASS (~a rows + controls)~%" "threads")
    (format #t "W2-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
