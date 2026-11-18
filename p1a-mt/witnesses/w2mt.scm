;; W2MT — blocking-GC witness on the MULTITHREADED-VM 4.9.8 build.
;;
;; This is the codex review's step 2 experiment: W2's synchronization repaired
;; for a build configured with --enable-multiple-threaded-vms --enable-smp
;; --enable-max-processors=8 and started with EXPLICIT -:p2 parallelism.
;;
;; Protocol (the review's F3 correction, implemented exactly):
;;
;;   1. The runtime is started with explicit parallelism -:p2 (main.c:46-49);
;;      W0's (##current-vm-resize #f 4) trick is NOT used (new processors
;;      execute a supplied thunk — setup.c:810-835,992-994).
;;   2. Thread A and thread B are synchronized BEFORE A enters C: A waits for
;;      B's ready flag before making its call.
;;   3. A enters the blocking foreign call w2mt_block (ordinary c-lambda; the
;;      C fixture sets an atomic flag and logs ENTER before blocking).
;;   4. B polls the atomic flag via a NON-blocking foreign call, and only
;;      starts its real-GC rounds once A is provably inside C. B logs its
;;      (##current-processor-id) on every round: with A's processor blocked in
;;      C, any B progress must come from a DIFFERENT processor.
;;   5. Each B round: updates LIVE ROOTED objects (a global vector whose cells
;;      are replaced with fresh populated vectors + a global counter), then
;;      performs a REAL collection ((##gc) runtime primitive AND the
;;      documented C API ___garbage_collect). The runtime's own "-:d5" *** GC:
;;      report lines are the verbatim collection evidence.
;;   6. Only AFTER all rounds complete does B call w2mt_release_handshake.
;;   7. The C fixture returns HOW the block ended (0 = handshake-released,
;;      1 = C-side deadline fired) — independent timeout detection. The
;;      verdict is computed from this OBSERVED state plus the live-root
;;      verification, not printed unconditionally.
;;
;; PASS requires: collection COMPLETING while C stays blocked (reason=0),
;; B's rounds executed on a different processor than A's, and the live rooted
;; objects intact after the collections. "A changed crash signature or extra
;; Scheme progress alone is not a pass" (review's standard of proof).
;;
;; Release/claim bridge: NONE is implemented here. This witness exercises the
;; ORDINARY c-lambda foreign call only. See findings: no release/claim
;; mechanism exists in the stock 4.9.8 source or headers (the FFI macros
;; neither mark the processor absent from GC participation nor transfer
;; execution ownership; OP_GARBAGE_COLLECT requires every processor with
;; id < ___vms->processor_count to enter the barrier — setup.c:1132-1149,
;; 1182-1196, 500-580). Absence of a mechanism is itself the finding.
;;
;; A Scheme-internal watchdog cannot fire if the whole VM freezes, so every
;; run is additionally under the external watchdog.sh (90s).

(c-declare #<<c-declare-end

int w2mt_block (int deadline_seconds);
void w2mt_release_handshake (void);
int w2mt_a_inside_p (void);
int w2mt_noblock (void);

/* probe of THIS build's configured maximum (include/gambit.h, substituted
   by configure: ___MAX_PROCESSORS 8 with --enable-multiple-threaded-vms
   --enable-max-processors=8, vs 1 in the single-threaded provisioned build) */
int w2mt_max_processors (void)
{
  return ___MAX_PROCESSORS;
}

c-declare-end
)

(define w2mt-block    (c-lambda (int) int "w2mt_block"))
(define w2mt-release  (c-lambda () void "w2mt_release_handshake (); ___return;"))
(define w2mt-a-inside? (c-lambda () int "w2mt_a_inside_p"))
(define w2mt-noblock  (c-lambda () int "w2mt_noblock"))
(define w2mt-max-procs (c-lambda () int "w2mt_max_processors"))
;; REAL collection through the documented C API (gambit.h):
;;   ___IMP_FUNC(___BOOL,___garbage_collect)
;;      ___P((___PSD ___SIZE_TS requested_words_still),());
(define w2mt-real-gc
  (c-lambda () int
    "___return (___EXT(___garbage_collect) (___PSP 0) ? 1 : 0);"))

(define (w2mt-now) (time->seconds (current-time)))
(define (w2mt-log . parts)
  ;; one forced-flush line, so ordering with the C fixture's flushed prints
  ;; is exact in the recorded output.
  (for-each display parts)
  (newline)
  (force-output))

;; ---- live rooted objects (mutated by B, verified by the main thread) ----

(define w2mt-live-roots (make-vector 8 #f))
(define w2mt-live-count 0)
(define w2mt-rounds-planned 3)

(define (w2mt-update-live-roots! i)
  ;; replace cell i with a fresh populated vector and bump the counter:
  ;; mutations to LIVE objects that must survive every real collection.
  (let ((v (make-vector 1000 i)))
    (let loop ((j 0))
      (if (< j 1000)
          (begin (vector-set! v j (+ i j)) (loop (+ j 1)))))
    (vector-set! w2mt-live-roots i v)
    (set! w2mt-live-count (+ w2mt-live-count 1))))

(define (w2mt-verify-live-roots!)
  ;; returns #f (ok) or a failure description; checks every mutated live
  ;; object survived the collections intact.
  (if (not (= w2mt-live-count w2mt-rounds-planned))
      (list "live-count" w2mt-live-count "expected" w2mt-rounds-planned)
      (let loop ((i 0))
        (if (>= i w2mt-rounds-planned)
            #f
            (let ((v (vector-ref w2mt-live-roots i)))
              (if (or (not (vector? v))
                      (not (= (vector-length v) 1000))
                      (not (= (vector-ref v 999) (+ i 999))))
                  (list "corrupt-root" i)
                  (loop (+ i 1))))))))

(define (w2mt-gc-rounds who n)
  ;; per round: update live rooted objects, allocate garbage, then force a
  ;; REAL collection via the runtime primitive AND the documented C API.
  (let loop ((i 1))
    (if (<= i n)
        (begin
          (w2mt-log who ": round " i " t=" (w2mt-now)
                    " pid=" (##current-processor-id)
                    " updating live roots + allocating")
          (w2mt-update-live-roots! (- i 1))
          (let ((v (make-vector 200000 0)))   ;; fresh garbage for the collector
            (vector-set! v 0 i))
          (w2mt-log who ": round " i " t=" (w2mt-now)
                    " calling (##gc) — REAL collection requested")
          (##gc)
          (let ((r (w2mt-real-gc)))
            (w2mt-log who ": round " i " t=" (w2mt-now)
                      " done (capi-gc-return=" r ") pid="
                      (##current-processor-id))
            (loop (+ i 1)))))))

;; ---- control mode: GC machinery works on this MT build ----

(define (w2mt-control)
  (define (a-work)
    (let loop ((i 1))
      (if (<= i 3)
          (begin
            (w2mt-log "W2MT-A: non-blocking foreign call " i
                      " t=" (w2mt-now) " pid=" (##current-processor-id))
            (w2mt-noblock)
            (thread-sleep! 0.3)
            (loop (+ i 1)))
          (w2mt-log "W2MT-A: all non-blocking calls returned"))))
  (let* ((t-b (make-thread (lambda () (w2mt-gc-rounds "W2MT-B" w2mt-rounds-planned)) 'w2mt-b))
         (t-a (make-thread a-work 'w2mt-a)))
    ;; A starts first so its foreign calls overlap B's GC rounds (the p1a W2
    ;; control was criticized — review F3 — for never actually overlapping).
    (thread-start! t-a)
    (thread-start! t-b)
    (thread-join! t-b)
    (thread-join! t-a)
    (let ((bad (w2mt-verify-live-roots!)))
      (if bad
          (w2mt-log "W2MT-VERDICT: FAIL (control: live roots corrupt after collections: " bad ")")
          (w2mt-log "W2MT-VERDICT: PASS (control: " w2mt-live-count
                    " real collections completed with another thread making foreign calls; live rooted objects intact; the *** GC: report lines above are the runtime's own collection evidence)")))))

;; ---- blocked mode: the actual qualification run ----

(define w2mt-a-reason #f)      ;; observed end-of-block state (0 handshake / 1 deadline)
(define w2mt-b-ready #f)       ;; A waits for this BEFORE entering C
(define w2mt-b-finished #f)    ;; set by B after all rounds + release
(define w2mt-a-pid #f)         ;; A's processor id at entry (A cannot migrate while in C)
(define w2mt-b-pids '())       ;; processor ids of B's post-observation execution

(define (w2mt-blocked)
  (let ((t-a (make-thread
              (lambda ()
                ;; synchronized BEFORE entering C: wait until B is running
                (let loop ()
                  (if (not w2mt-b-ready)
                      (begin (thread-sleep! 0.001) (loop))))
                (set! w2mt-a-pid (##current-processor-id))
                (w2mt-log "W2MT-A: synchronized with B, entering blocking foreign call t="
                          (w2mt-now) " pid=" w2mt-a-pid)
                (set! w2mt-a-reason (w2mt-block 6))
                (w2mt-log "W2MT-A: blocking call returned reason=" w2mt-a-reason
                          " t=" (w2mt-now))
                (w2mt-log "W2MT-A: pid after return=" (##current-processor-id))
                )
              'w2mt-a))
         (t-b (make-thread
               (lambda ()
                 (w2mt-log "W2MT-B: running t=" (w2mt-now)
                           " pid=" (##current-processor-id))
                 (set! w2mt-b-ready #t)
                 ;; BUSY spin (NO thread-sleep!: a sleeping thread's timeout is
                 ;; serviced by the device loop of the processor it slept on —
                 ;; if that processor is the one blocked in C, the sleep never
                 ;; fires and B never runs — observed in the first blocked run,
                 ;; see results-nonsmp/ and the first w2mt-blocked.out). A pure
                 ;; spin keeps B RUNNABLE so the scheduler must place it on the
                 ;; other processor while A blocks. The review's protocol
                 ;; requires B provably EXECUTING during the block.
                 (let loop ((i 0))
                   (if (not (= 1 (w2mt-a-inside?)))
                       (begin
                         (if (= 0 (##fxmodulo i 20000))
                             (w2mt-log "W2MT-B: spinning t=" (w2mt-now)
                                       " pid=" (##current-processor-id)))
                         (loop (+ i 1)))))
                 (set! w2mt-b-pids (cons (##current-processor-id) w2mt-b-pids))
                 (w2mt-log "W2MT-B: observed A inside C t=" (w2mt-now)
                           " pid=" (##current-processor-id))
                 (w2mt-gc-rounds "W2MT-B" w2mt-rounds-planned)
                 (set! w2mt-b-pids (cons (##current-processor-id) w2mt-b-pids))
                 ;; only NOW may C be released
                 (w2mt-log "W2MT-B: all rounds done, releasing C t=" (w2mt-now))
                 (w2mt-release)
                 (set! w2mt-b-finished #t)
                 (w2mt-log "W2MT-B: handshake released t=" (w2mt-now)))
               'w2mt-b)))
    (let ((t-block-start (w2mt-now)))
      (thread-start! t-b)
      (thread-start! t-a)
      (thread-join! t-a)   ;; bounded by C's 6s deadline
      (thread-join! t-b)
      (w2mt-log "W2MT: blocked window from t=" t-block-start " to t=" (w2mt-now))
      ;; ---- verdict from OBSERVED state ----
      (let ((bad (w2mt-verify-live-roots!))
            (b-on-other-processor?
             (not (memq w2mt-a-pid w2mt-b-pids))))
        (cond
         ((and (= w2mt-a-reason 0)
               w2mt-b-finished
               b-on-other-processor?
               (not bad))
          (w2mt-log "W2MT-VERDICT: PASS (B completed " w2mt-rounds-planned
                    " real GC rounds and updated live rooted objects WHILE C was blocked — C returned via B's handshake, not its deadline; B executed on processor(s) " w2mt-b-pids
                    " != A's " w2mt-a-pid "; live roots intact; B's round lines above are timestamped before 'W2MTC: ... RETURNING')"))
         ((= w2mt-a-reason 1)
          (w2mt-log "W2MT-VERDICT: FAIL (collection did NOT complete while C was blocked: the C-side deadline fired after 6s and the RETURNING line precedes B's round-done lines — the GC barrier (setup.c:1132-1196) waits for EVERY processor of the VM, including the one parked inside the foreign call; B's allocation progress alone is not a pass; B's pids=" w2mt-b-pids " A's pid=" w2mt-a-pid ")"))
         (else
          (w2mt-log "W2MT-VERDICT: FAIL (incomplete qualification: reason=" w2mt-a-reason
                    " b-finished=" w2mt-b-finished
                    " b-on-other-processor=" b-on-other-processor?
                    " b-pids=" w2mt-b-pids
                    " a-pid=" w2mt-a-pid
                    " live-roots=" bad ")")))))))

(define (w2mt-run mode)
  (w2mt-log "=== W2MT blocking-GC witness (MT build): mode=" mode " ===")
  (w2mt-log "W2MT: t=" (w2mt-now) " start")
  (w2mt-log "W2MT: vm-processor-count=" (##current-vm-processor-count)
            " max-processors=" (w2mt-max-procs)
            " cpu-count=" (##cpu-count)
            " (scheduler behavior is evidenced by the per-line pid= logs below)")
  (if (< (##current-vm-processor-count) 2)
      (w2mt-log "W2MT-VERDICT: FAIL (runtime has <2 processors — must be started with -:p2)")
      (case mode
        ((control) (w2mt-control))
        ((blocked) (w2mt-blocked))
        (else
         (w2mt-log "W2MT-usage: ./w2mt.exe -:p2,d5 control|blocked")))))

;; compiled exe: the mode is the first non-(-:) command-line argument
(let ((args (command-line)))
  (w2mt-run (cond
             ((and (pair? args)
                   (member (car args) '("control" "blocked")))
              (string->symbol (car args)))
             ((and (pair? args) (pair? (cdr args))
                   (member (cadr args) '("control" "blocked")))
              (string->symbol (cadr args)))
             (else 'usage))))
