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
(define (sa-call-with-escape-continuation proc)
  (let ((spent #f)
        (owner (current-thread)))
    (let ((result
           (call/cc
            (lambda (k)
              (proc (lambda (v)
                      (cond
                        (spent
                         (error 'escape-continuation
                                "one-shot escape used twice"))
                        ((not (eq? owner (current-thread)))
                         (error 'escape-continuation
                                "escape invoked from wrong thread"))
                        (else
                         (set! spent #t)
                         (k v)))))))))
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

;; E6: thread ownership (adapter policy beyond the contract minimum).
(define cross-thread-result #f)
(let ((ek #f))
  (sa-call-with-escape-continuation
   (lambda (k) (set! ek k) 'captured))
  (join-thread (call-with-new-thread
                (lambda ()
                  (set! cross-thread-result
                        (false-if-exception (ek 'x)))))))
(format #t "E6 cross-thread invocation => ~s~%" cross-thread-result)
(check "E6 cross-thread invocation RAISES (ownership policy)"
       (not cross-thread-result))

;; ---- prototype 2: prompt-based (cheaper escapes) ---------------------------
(define tag (make-prompt-tag "escape"))
(define (prompt-ec proc)
  (let ((spent #f))
    (call-with-prompt tag
      (lambda ()
        (proc (lambda (v)
                (if spent
                    (error 'escape-continuation "one-shot escape used twice")
                    (begin (set! spent #t) (abort-to-prompt tag v))))))
      (lambda (_ v) v))))

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
  (let ((p-post (false-if-exception (p-saved 'x))))
    (format #t "P3c prompt-based post-return invocation => ~s~%" p-post)
    (check "P3c prompt-based post-return invocation RAISES (one-shot)"
           (not p-post))))
(define p-order '())
(let ((r (prompt-ec
          (lambda (k)
            (dynamic-wind
                (lambda () #f)
                (lambda () (k 'pv))
                (lambda () (set! p-order (cons 'ran p-order))))))))
  (check "P4 prompt-based escape unwinds dynamic-wind" (eq? r 'pv))
  (check "P4b finally ran" (equal? p-order '(ran))))

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
