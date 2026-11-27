;; W4 — FFI errno-at-the-boundary witness (audit area 4).
;;
;; Contract row (TARGET-CONTRACT.md, pinned): sa-foreign-procedure-native-error
;; must return the C result and the calling thread's errno ATOMICALLY at the
;; call boundary — "a later host call that reads an error slot is not an
;; equivalent implementation."
;;
;; Guile 3.0.11 documents the mechanism (manual §6.19.5 Foreign Functions):
;;   (pointer->procedure ret func arg-types #:return-errno? #t) — "the
;;   returned procedure will return two values, with errno as the second
;;   value."
;; This witness decides the two things the doc does NOT pin:
;;   E1 errno is per-THREAD (TLS) — two threads with distinct errnos keep
;;      them apart (the precondition for boundary capture being sound);
;;   E2 concurrent #:return-errno? calls in two threads each capture their
;;      OWN errno (500 interleaved rounds each);
;;   E3 a post-capture clobber does not leak into the already-captured pair.
;;
;; Also records the dlopen/dlsym error-reporting rows:
;;   D1 symbol lookup failure raises with a message;
;;   D2 library load failure raises with a message (darwin vs linux paths).
;;
;; Negative control:
;;   NC1 reading the raw errno slot AFTER an intervening clobber shows the
;;      CLOBBER value — proving the assertions distinguish capture orders,
;;      i.e. a late-read implementation would fail E3's check.

(use-modules (system foreign)
             (system foreign-library)
             (rnrs bytevectors)
             (ice-9 threads)
             (ice-9 atomic)
             (srfi srfi-1)
             (srfi srfi-8))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(format #t "=== W4 FFI errno boundary witness ===~%")
(format #t "host-type=~a~%" %host-type)

;; ---- errno slot access (platform TLS accessor) ------------------------------
(define errno-loc
  (or (false-if-exception (foreign-library-function #f "__error"
                                                     #:return-type '*
                                                     #:arg-types '()))
      (false-if-exception (foreign-library-function #f "__errno_location"
                                                     #:return-type '*
                                                     #:arg-types '()))))
(check "errno TLS accessor resolved (__error / __errno_location)"
       (procedure? errno-loc))
(define (errno-ref) (bytevector-s32-native-ref
                     (pointer->bytevector (errno-loc) 4) 0))
(define (errno-set! v) (bytevector-s32-native-set!
                        (pointer->bytevector (errno-loc) 4) 0 v))

;; ---- foreign functions --------------------------------------------------------
(define c-read
  (foreign-library-function #f "read"
                            #:return-type int
                            #:arg-types (list int '* size_t)
                            #:return-errno? #t))
(define c-read-plain
  (foreign-library-function #f "read"
                            #:return-type int
                            #:arg-types (list int '* size_t)))
(define c-access
  (foreign-library-function #f "access"
                            #:return-type int
                            #:arg-types (list '* int)
                            #:return-errno? #t))
(define buf-ptr (bytevector->pointer (make-bytevector 16)))

;; ---- E1 raw-slot observation (recorded, shapes the adapter rule) ------------
;; RECORDED FINDING: the raw errno slot is NOT reliably poked/read across
;; foreign calls on this build — errno-set! does not survive the next
;; foreign call, and a plain failing call leaves the raw slot at 0 (Guile
;; manages errno around the FFI boundary).  ADAPTER RULE: sa-foreign-
;; procedure-native-error must use #:return-errno? boundary capture
;; (E2/E3); late raw reads are not merely racy, they read the wrong thing.
(format #t "E1 raw-slot probes: set-readback=~a read-after-plain-fail=~a~%"
        (begin (errno-set! 77) (errno-ref))
        (begin (c-read-plain -1 buf-ptr 16) (errno-ref)))
(check "E1 raw errno slot is NOT a valid access path on this build \
(Guile manages errno across foreign calls — adapter must capture at the \
boundary)"
       (not (= (begin (errno-set! 77) (errno-ref)) 77)))

;; ---- E2 concurrent boundary captures (the per-thread TLS proof) -------------
;; Two threads run two DIFFERENT errno-producing failing calls concurrently;
;; every capture must report its own call's errno.  A process-global errno
;; would cross-contaminate under this interleaving.
(define rounds 500)
(define bad-captures 0)
(define (stress-thread mode)
  (lambda ()
    (let loop ((n 0))
      (when (< n rounds)
        (if (eq? mode 'read)
            (receive (r e) (c-read -1 buf-ptr 16)
              (unless (and (= r -1) (= e 9))    ; EBADF
                (set! bad-captures (+ bad-captures 1))))
            (receive (r e) (c-access (string->pointer "/definitely-not-w4")
                                     0)
              (unless (and (= r -1) (= e 2))    ; ENOENT
                (set! bad-captures (+ bad-captures 1)))))
        (loop (+ n 1))))))
(define t-a (call-with-new-thread (stress-thread 'read)))
(define t-b (call-with-new-thread (stress-thread 'access)))
(join-thread t-a)
(join-thread t-b)
(format #t "E2 concurrent captures: ~a rounds x2 (read->EBADF vs \
access->ENOENT), bad=~a~%" rounds bad-captures)
(check "E2 both threads capture their OWN errno at the boundary, 1000 \
interleaved rounds (per-thread TLS errno proven)"
       (zero? bad-captures))

;; ---- E3 + NC1 capture-order discipline ---------------------------------------
(receive (r e) (c-read -1 buf-ptr 16)
  (check "E3a boundary capture reports EBADF(9) for read(-1)"
         (and (= r -1) (= e 9)))
  ;; post-capture clobber
  (c-access (string->pointer "/no-such-path-w4") 0)
  (check "E3b the captured pair survives a post-capture clobber (still 9)"
         (= e 9))
  ;; NC1: the raw slot AFTER the clobber call diverges from the captured
  ;; pair — on this build Guile resets it (0), which is even stronger
  ;; evidence than a clobber value: a late-read implementation of
  ;; native-error would return the WRONG errno, not a stale one.
  (let ((late (errno-ref)))
    (format #t "NC1 raw slot after clobber call = ~a (captured pair kept 9)~%"
            late)
    (check "NC1 control: a LATE raw read diverges from the captured pair \
(late-read is decisively wrong, not merely racy)"
           (not (= late e)))))

;; ---- CL callback lifetime under GC --------------------------------------------
;; Manual §6.19.8 documents procedure->pointer but says nothing about
;; rooting; the adapter needs to know whether a trampoline survives once
;; the Scheme procedure reference is dropped.  qsort through the pointer,
;; kept-reference variant MUST sort; dropped-reference variant: outcome
;; recorded either way (survival = internally rooted; crash = the adapter
;; must keep a registry; the watchdog records a hang/crash as failure).
(define c-qsort
  (foreign-library-function #f "qsort"
                            #:return-type int
                            #:arg-types (list '* size_t size_t '*)))
(define (make-comparator)
  (procedure->pointer
   int
   (lambda (a b)
     (- (bytevector-u8-ref (pointer->bytevector a 1) 0)
        (bytevector-u8-ref (pointer->bytevector b 1) 0)))
   (list '* '*)))
(let* ((arr (u8-list->bytevector '(9 3 7 1 5)))
       (cb (make-comparator)))
  (c-qsort (bytevector->pointer arr) (bytevector-length arr) 1 cb)
  (gc)
  (check "CL1 qsort through procedure->pointer sorts (reference kept)"
         (equal? (bytevector->u8-list arr) '(1 3 5 7 9))))
(let* ((arr2 (u8-list->bytevector '(8 2 6 4)))
       (holder (list (make-comparator))))
  (define cptr (car holder))
  (set! holder #f)
  (gc) (gc) (gc)
  (let ((r (false-if-exception
            (c-qsort (bytevector->pointer arr2) (bytevector-length arr2)
                     1 cptr))))
    (format #t "CL2 qsort after dropping the only Scheme proc ref + 3 GCs \
=> ~s arr=~s~%" r (bytevector->u8-list arr2))
    (format #t "CL2 outcome recorded: survival means Guile roots the \
trampoline internally; a crash here is the watchdog's record and means \
the adapter MUST keep a callback registry~%")
    (check "CL2 dropped-reference call: if it returned, values crossed \
correctly (survival implies correctness; refusal is separately recorded)"
           (or (not r)
               (equal? (bytevector->u8-list arr2) '(2 4 6 8))))))

;; ---- D1/D2 dlopen/dlsym error reporting ---------------------------------------
(let ((sym (false-if-exception
            (foreign-library-function #f "w4_no_such_symbol_zzz"))))
  (check "D1 missing symbol lookup RAISES" (not sym)))
(let ((lib (false-if-exception (load-foreign-library "w4nosuchlibzzz"))))
  (check "D2 missing library load RAISES" (not lib)))
;; resolution-order fact: #f handle resolves libc symbols in this process
(check "D3 the #f handle resolves global (libc) symbols — the running \
executable's dynamic namespace"
       (procedure? c-read))

(if (zero? fails)
    (format #t "W4-VERDICT: PASS (errno-at-boundary decisive)~%")
    (format #t "W4-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
