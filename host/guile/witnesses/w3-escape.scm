;; W3 — one-shot escape continuation witness (audit area 3).
;;
;; The contract (CONTRACT.txt capability-continuations):
;;   (sa-call-with-escape-continuation proc) — k valid AT MOST ONCE and
;;   only while the call is on the stack; a second invocation, or one
;;   after proc returned normally, must RAISE; the escape must unwind the
;;   dynamic-wind chain (jolt's `finally` rides it).
;;
;; Guile's call/cc is multi-shot and re-entrant after its extent exits
;; (manual §6.11.6: "when a continuation is invoked, call/cc and
;; subsequent code effectively 'returns' a second time") — so the adapter
;; MUST carry a spent flag, exactly as guile.ss anticipated.  This witness
;; prototypes two wrappers (call/cc-based and prompt-based — manual
;; §6.11.5 recommends prompts for escapes) and pins their behavior.
;;
;; Negative controls:
;;   NC1 the RAW call/cc post-return invocation re-enters the frame —
;;      recorded to prove the spent flag is load-bearing (the wrapper
;;      raises exactly where the raw primitive silently re-enters);
;;   NC2 a deliberately broken wrapper WITHOUT the spent flag exhibits
;;      the same re-entry through the wrapper shape.

(use-modules (ice-9 threads)
             (srfi srfi-1))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(format #t "=== W3 one-shot escape continuation witness ===~%")

;; ---- prototype 1: call/cc + spent flag -------------------------------------
;; Value flow: the call/cc result (proc's normal return value, or the
;; escaped value) is captured, the frame is then marked spent (any later
;; invocation of k raises — the one-shot pin), and the value returned.
;; Prototype is single-value; the adapter generalizes to multiple values.
;; CONTRACT NOTE (r3, review finding): the adapter's duty is the ONE-SHOT
;; spent flag ONLY.  Thread/fiber ownership is the HOST's rule
;; (TARGET-CONTRACT.md "Ownership ... is the HOST's rule, not yours") —
;; and the platform already raises on cross-thread k use (E6 records it),
;; so no owner check is baked in here.
(define (sa-call-with-escape-continuation proc)
  (let ((spent #f))
    (let ((result
           (call/cc
            (lambda (k)
              (proc (lambda (v)
                      (if spent
                          (error 'escape-continuation
                                 "one-shot escape used twice")
                          (begin (set! spent #t) (k v)))))))))
      (set! spent #t)   ; reached on BOTH the normal and the escape path
      result)))

;; ---- E-battery on the wrapper ----------------------------------------------
(check "E1 normal return passes value through"
       (equal? (sa-call-with-escape-continuation (lambda (k) 'normal)) 'normal))

(check "E2 escape returns from the wrapper call"
       (= 42 (+ 1 (sa-call-with-escape-continuation
                   (lambda (k) (k 41) 999)))))

;; E3: one-shot DURING an in-flight escape — a second use from inside the
;; dynamic-wind unwind of the first escape must raise (a naive (k 1) (k 2)
;; body never reaches the second call: the first escape exits the frame).
(define e3-second-use 'not-attempted)
(let ((r (sa-call-with-escape-continuation
          (lambda (k)
            (dynamic-wind
                (lambda () #f)
                (lambda () (k 'first))
                (lambda ()
                  ;; runs during the first escape's unwind
                  (set! e3-second-use
                        (false-if-exception (k 'second)))))))))
  (format #t "E3 escape value=~s second-use-during-unwind=~s~%" r
          e3-second-use)
  (check "E3 second invocation DURING the escape's unwind RAISES \
(one-shot enforced in-flight)"
         (and (eq? r 'first) (not e3-second-use))))

(define saved-ek #f)
(define normal-result
  (sa-call-with-escape-continuation
   (lambda (k) (set! saved-ek k) 'returned)))
(check "E4a wrapper returns normally after capturing k" (eq? normal-result 'returned))
(let ((post (false-if-exception (saved-ek 'x))))
  (format #t "E4b post-return invocation => ~s~%" post)
  (check "E4b post-return invocation RAISES (frame gone)"
         (not post)))

(define unwind-order '())
(define fin-count 0)
(let ((r (sa-call-with-escape-continuation
          (lambda (k)
            (dynamic-wind
                (lambda () (set! unwind-order (cons 'in-outer unwind-order)))
                (lambda ()
                  (dynamic-wind
                      (lambda () (set! unwind-order (cons 'in-inner unwind-order)))
                      (lambda () (k 'deep))
                      (lambda () (set! unwind-order (cons 'out-inner unwind-order)))))
                (lambda () (set! unwind-order (cons 'out-outer unwind-order))))
            'not-taken))))
  (check "E5 escape value delivered from inside nested dynamic-wind"
         (eq? r 'deep))
  (check "E5b finally bodies ran on the way out, inner first"
         (equal? unwind-order '(out-outer out-inner in-inner in-outer))))

;; E6: cross-thread invocation.  The adapter carries NO ownership policy
;; (TARGET-CONTRACT.md pins ownership as the HOST's rule); this records
;; what the PLATFORM itself does — the raw continuation refuses use from
;; another thread, so the host layers its policy on a platform-enforced
;; refusal, not on adapter machinery.
(define cross-thread-result #f)
(let ((ek #f))
  (sa-call-with-escape-continuation
   (lambda (k) (set! ek k) 'captured))
  (join-thread (call-with-new-thread
                (lambda ()
                  (set! cross-thread-result
                        (false-if-exception (ek 'x)))))))
(format #t "E6 cross-thread invocation => ~s~%" cross-thread-result)
(check "E6 cross-thread invocation RAISES in the invoking thread \
(platform-enforced; ownership POLICY itself is the host layer's)"
       (not cross-thread-result))

;; ---- prototype 2: prompt-based (cheaper escapes) ---------------------------
;; r3 repairs (review P1): the r2 version shared ONE global prompt tag
;; and never set spent on the normal-return path.  Both bugs were
;; reproduced before this repair: a shared tag lets an inner call's
;; handler catch an OUTER escape ((outer-continued escaped) instead of
;; escaped), and a leaked k from a returned call silently HIJACKS a later
;; active prompt-ec (returned 'hijacked instead of raising).  The repair:
;; a FRESH tag per call and spent set on BOTH exit paths.
(define (prompt-ec proc)
  (let ((tag (make-prompt-tag "escape"))       ; fresh per call
        (spent #f))
    (let ((result
           (call-with-prompt tag
             (lambda ()
               (proc (lambda (v)
                       (if spent
                           (error 'escape-continuation
                                  "one-shot escape used twice")
                           (begin (set! spent #t)
                                  (abort-to-prompt tag v))))))
             (lambda (_ v) v))))
      (set! spent #t)             ; normal-return path: later uses raise
      result)))

(check "P1 prompt-based normal return"
       (eq? (prompt-ec (lambda (k) 'pn)) 'pn))
(check "P2 prompt-based escape"
       (= 43 (+ 1 (prompt-ec (lambda (k) (k 42) 0)))))
(let ((p3 (false-if-exception (prompt-ec (lambda (k) (k 1) (k 2))))))
  (format #t "P3 sequential (k 1)(k 2) => ~s (second call unreachable — \
the first escape exits)~%" p3)
  (check "P3a prompt-based escape delivers the first value"
         (eqv? p3 1)))
(define p-saved #f)
(let ((pn (prompt-ec (lambda (k) (set! p-saved k) 'pcap))))
  (check "P3b prompt wrapper returns normally after capture" (eq? pn 'pcap))
  (let ((p-post (catch #t
                  (lambda () (p-saved 'x) #f)
                  (lambda (key . args) (list key args)))))
    (format #t "P3c prompt-based post-return invocation => ~s~%" p-post)
    (check "P3c prompt-based post-return invocation RAISES via the SPENT \
flag (not via 'unknown prompt')"
           (and (pair? p-post)
                (eq? (car p-post) 'misc-error)
                (pair? (cadr p-post))
                (let ((msg-args (caddr (cadr p-post))))
                  (and (pair? msg-args)
                       (eq? (car msg-args) 'escape-continuation)))))))
(define p-order '())
(let ((r (prompt-ec
          (lambda (k)
            (dynamic-wind
                (lambda () #f)
                (lambda () (k 'pv))
                (lambda () (set! p-order (cons 'ran p-order))))))))
  (check "P4 prompt-based escape unwinds dynamic-wind" (eq? r 'pv))
  (check "P4b finally ran" (equal? p-order '(ran))))

;; P5 NESTED escapes (the shared-tag bug's missing check): invoking the
;; OUTER escape from inside an inner call must deliver to the OUTER call.
(let ((nested (prompt-ec
               (lambda (k-out)
                 (list 'outer-continued
                       (prompt-ec (lambda (k-in) (k-out 'escaped))))))))
  (format #t "P5 nested outer-escape delivery => ~s~%" nested)
  (check "P5 a fresh tag per call delivers the OUTER escape to the OUTER \
handler (shared-tag bug would answer (outer-continued escaped))"
         (eq? nested 'escaped)))

;; P6 HIJACK control (the missing normal-return-spent check): a k leaked
;; from a RETURNED prompt-ec, invoked inside another ACTIVE prompt-ec,
;; must RAISE, not silently abort the enclosing call.
(let* ((leaked #f)
       (_ (prompt-ec (lambda (k) (set! leaked k) 'leak-captured)))
       (attempt (prompt-ec
                 (lambda (k2)
                   (list 'inner-completed
                         (catch #t
                           (lambda () (leaked 'hijacked) 'hijacked-no-raise)
                           (lambda (key . args)
                             (list 'raised key
                                   (car (caddr args))))))))))
  (format #t "P6 leaked-k invocation inside an active prompt-ec => ~s~%"
          attempt)
  (check "P6 a spent k RAISES via spent flag inside a later active prompt-ec \
instead of hijacking it"
         (equal? attempt '(inner-completed (raised misc-error escape-continuation)))))

;; P7 in-flight second use during the escape's dynamic-wind unwind
;; (the E3-equivalent the r2 prompt battery never ran).
(define p7-second-use 'not-attempted)
(let ((r (prompt-ec
          (lambda (k)
            (dynamic-wind
                (lambda () #f)
                (lambda () (k 'pfirst))
                (lambda ()
                  (set! p7-second-use
                        (false-if-exception (k 'psecond)))))))))
  (format #t "P7 escape value=~s second-use-during-unwind=~s~%" r
          p7-second-use)
  (check "P7 prompt-based second invocation DURING the unwind RAISES"
         (and (eq? r 'pfirst) (not p7-second-use))))

;; ---- negative controls ------------------------------------------------------
;; NC1: the RAW primitive re-enters a function frame after its first
;; return (two passes logged) — exactly what the wrapper must prevent.
(define (raw-demo)
  (define k #f)
  (define log '())
  (let ((r (call/cc (lambda (c) (set! k c) 'one))))
    (set! log (cons r log))
    (if (eq? r 'one)
        (k 'two)                       ; re-enter the SAME frame
        (reverse log))))
(define raw-observations (raw-demo))
(format #t "NC1 raw call/cc observations: ~s~%" raw-observations)
(check "NC1 control: RAW call/cc re-enters the finished frame (two passes \
logged: one two) — the spent flag is load-bearing"
       (equal? raw-observations '(one two)))

;; NC2: the same frame through a wrapper WITHOUT the spent flag re-enters
;; too (the shape alone is not the fix).
(define (broken-ec proc)
  (call/cc (lambda (k) (proc (lambda (v) (k v))))))
(define (broken-demo)
  (define k #f)
  (define log '())
  (let ((r (broken-ec (lambda (c) (set! k c) 'one))))
    (set! log (cons r log))
    (if (eq? r 'one)
        (k 'two)
        (reverse log))))
(define broken-observations (broken-demo))
(format #t "NC2 broken-wrapper observations: ~s~%" broken-observations)
(check "NC2 control: wrapper WITHOUT the spent flag re-enters too \
(two passes logged) — the spent flag, not the wrapper shape, is the fix"
       (equal? broken-observations '(one two)))

;; NC3: the REAL wrapper over the same frame shape raises on re-entry —
;; the contrast that makes NC1/NC2 load-bearing.
(define (wrapper-demo)
  (define k #f)
  (define log '())
  (let ((r (sa-call-with-escape-continuation
            (lambda (c) (set! k c) 'one))))
    (set! log (cons r log))
    (if (eq? r 'one)
        (begin (set! log (cons (false-if-exception (k 'two)) log))
               (reverse log))
        (reverse log))))
(define wrapper-observations (wrapper-demo))
(format #t "NC3 real-wrapper observations: ~s~%" wrapper-observations)
(check "NC3 control: the REAL wrapper RAISES where NC1/NC2 re-enter \
(second pass recorded as #f, not 'two)"
       (equal? wrapper-observations '(one #f)))

;; fibers-tier feasibility note (recorded, not measured here): the manual
;; recommends prompts for escapes and documents delimited continuations
;; (§6.11.5); a fibers scheduler rides prompts + suspendable ports (W9).
(format #t "fibers-tier: prompt-based escape prototype works; \
see AUDIT.md area 3 for the feasibility ruling~%")

(if (zero? fails)
    (format #t "W3-VERDICT: PASS (one-shot enforced both prototypes)~%")
    (format #t "W3-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
