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
;; (parameterize ((*param* 'inner)) (fork ...)) — reads the inherited
;; parameter, fluid, and thread-local fluid at fork time.
(define child
  (parameterize ((*param* 'outer))
    (with-fluids ((*fluid* 'fouter))
      (parameterize ((*param* 'inner))
        (call-with-new-thread
         (lambda ()
           (report! (list 'at-fork
                          (*param*)
                          (fluid-ref *fluid*)
                          (fluid-ref *tlf*)))
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
(let ((at-fork (assq 'at-fork mailbox)))
  (check "T1a child inherits the CREATING thread's CURRENT parameter value \
(nested parameterize: 'inner)"
         (and at-fork (eq? (second at-fork) 'inner)))
  (check "T1b child inherits the creator's current FLUID value ('fouter)"
         (and at-fork (eq? (third at-fork) 'fouter)))
  (check "T2 thread-local fluid NOT propagated (default 'tdefault)"
         (and at-fork (eq? (fourth at-fork) 'tdefault))))

;; N1a: synchronize via an atomic flag so the child is GUARANTEED to read
;; (*param*) ONLY AFTER the parent executes (*param* 'rebound-after-fork).
(define late-seen
  (parameterize ((*param* 'before))
    (let* ((rebound-ready (make-atomic-box #f))
           (cell (make-atomic-box 'unforked))
           (t (call-with-new-thread
               (lambda ()
                 (let spin ()
                   (unless (atomic-box-ref rebound-ready)
                     (yield)
                     (spin)))
                 (atomic-box-set! cell (*param*))))))
      (*param* 'rebound-after-fork)     ; rebind AFTER creating the thread
      (atomic-box-set! rebound-ready #t)
      (join-thread t)
      (atomic-box-ref cell))))
(format #t "N1a child saw ~s under synchronized post-fork parent rebinding \
to 'rebound-after-fork~%" late-seen)
(check "N1a control: child reads the fork-time value ('before), not the \
post-fork parent rebinding"
       (eq? late-seen 'before))

;; N1b: reverse isolation (*txn* clear pattern in CONTRACT.txt): a child
;; mutating (*param* #f) does NOT mutate the parent's binding.
(define parent-after-child-clear
  (parameterize ((*param* 'parent-val))
    (let ((t (call-with-new-thread (lambda () (*param* #f)))))
      (join-thread t)
      (*param*))))
(format #t "N1b parent *param* after child (*param* #f) => ~s~%"
        parent-after-child-clear)
(check "N1b control: child mutating (*param* #f) leaves parent's binding \
untouched ('parent-val)"
       (eq? parent-after-child-clear 'parent-val))

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
(define unowned-rejected (not (try-unowned 'unowned)))
(define allow-ext-kind (try-unowned 'allow-external-unlock))
(format #t "T3b unowned rejected=~a; allow-external-unlock accepted=~a~%"
        unowned-rejected (and allow-ext-kind #t))
(check "T3b0 'unowned raises on 3.0.11 while 'allow-external-unlock is accepted"
       (and unowned-rejected
            allow-ext-kind
            (eq? (cdr allow-ext-kind) 'allow-external-unlock)))
(let ((m-un (and allow-ext-kind (car allow-ext-kind))))
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
;; Guile threads are real OS pthreads sharing memory, so fences may NOT be
;; no-ops.  CONTRACT.txt:113-118 defines standalone zero-arg fences
;; (memory-order-release) / (memory-order-acquire) around ordinary record/
;; vector publication (seq.ss, cow-publish!).  Because (ice-9 atomic)
;; provides C11 sequential consistency (§6.22.4), we model the standalone
;; fences over a shared atomic word (%fence-word) and test:
;;   T6a: the standalone fence publication pattern on plain Scheme vectors
;;        across two concurrent threads (1000 rounds);
;;   T6b: direct atomic-box release/acquire message passing (1000 rounds).
(define %fence-word (make-atomic-box 0))
(define (memory-order-release) (atomic-box-set! %fence-word 0))
(define (memory-order-acquire) (atomic-box-ref %fence-word))

(define pub-cell (vector 0))
(define pub-ack (vector 0))
(define pub-payload (vector 0 0))
(define pub-mismatches 0)
(define fence-rounds 1000)
(define pub-consumer
  (call-with-new-thread
   (lambda ()
     (let loop ((i 1))
       (when (<= i fence-rounds)
         (let spin ()
           (let ((v (vector-ref pub-cell 0)))
             (memory-order-acquire)
             (unless (= v i)
               (yield)
               (spin))))
         (unless (and (= (vector-ref pub-payload 0) i)
                      (= (vector-ref pub-payload 1) (* i 7)))
           (set! pub-mismatches (+ pub-mismatches 1)))
         (memory-order-release)
         (vector-set! pub-ack 0 i)
         (loop (+ i 1)))))))
(define pub-producer
  (call-with-new-thread
   (lambda ()
     (let loop ((i 1))
       (when (<= i fence-rounds)
         (let spin ()
           (let ((a (vector-ref pub-ack 0)))
             (memory-order-acquire)
             (unless (= a (- i 1))
               (yield)
               (spin))))
         (vector-set! pub-payload 0 i)
         (vector-set! pub-payload 1 (* i 7))
         (memory-order-release)
         (vector-set! pub-cell 0 i)
         (loop (+ i 1)))))))
(join-thread pub-producer)
(join-thread pub-consumer)
(format #t "T6a standalone fence publication: pub=~a ack=~a mismatches=~a~%"
        (vector-ref pub-cell 0) (vector-ref pub-ack 0) pub-mismatches)
(check "T6a standalone memory-order-release/acquire around plain vector \
publication: 1000 rounds with zero payload mismatches"
       (and (= (vector-ref pub-cell 0) fence-rounds)
            (= (vector-ref pub-ack 0) fence-rounds)
            (zero? pub-mismatches)))

(define fence-seq (make-atomic-box 0))
(define fence-ack (make-atomic-box 0))
(define fence-payload (vector 0 0))
(define fence-mismatches 0)
(define fence-consumer
  (call-with-new-thread
   (lambda ()
     (let loop ((i 1))
       (when (<= i fence-rounds)
         (let spin ()
           (unless (= (atomic-box-ref fence-seq) i)
             (yield)
             (spin)))
         (unless (and (= (vector-ref fence-payload 0) i)
                      (= (vector-ref fence-payload 1) (* i 7)))
           (set! fence-mismatches (+ fence-mismatches 1)))
         (atomic-box-set! fence-ack i)
         (loop (+ i 1)))))))
(define fence-producer
  (call-with-new-thread
   (lambda ()
     (let loop ((i 1))
       (when (<= i fence-rounds)
         (let spin ()
           (unless (= (atomic-box-ref fence-ack) (- i 1))
             (yield)
             (spin)))
         (vector-set! fence-payload 0 i)
         (vector-set! fence-payload 1 (* i 7))
         (atomic-box-set! fence-seq i)
         (loop (+ i 1)))))))
(join-thread fence-producer)
(join-thread fence-consumer)
(format #t "T6b atomic-box message passing: seq=~a ack=~a mismatches=~a~%"
        (atomic-box-ref fence-seq) (atomic-box-ref fence-ack) fence-mismatches)
(check "T6b atomic-box release/acquire message passing: 1000 rounds with \
zero payload visibility mismatches"
       (and (= (atomic-box-ref fence-seq) fence-rounds)
            (= (atomic-box-ref fence-ack) fence-rounds)
            (zero? fence-mismatches)))

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
