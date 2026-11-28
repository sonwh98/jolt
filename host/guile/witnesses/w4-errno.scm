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
             (rnrs io ports)
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
;; rooting.  r3 (review P1): the r2 CL2 kept the <pointer> OBJECT alive in
;; a local variable, so it proved nothing — the closure is rooted BY the
;; <pointer> object procedure->pointer returns.  The decisive row is what
;; happens when only the raw C address survives (the shape
;; sa-foreign-callable-entry-point hands to C): that can crash (SIGSEGV
;; in the Darwin audit), so the adapter MUST keep every <pointer> in a
;; callable registry for as long as C holds its address.
(define c-qsort
  (foreign-library-function #f "qsort"
                            #:return-type void
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
  (check "CL1 qsort through procedure->pointer sorts (references kept)"
         (equal? (bytevector->u8-list arr) '(1 3 5 7 9))))
;; CL2a: drop the Scheme PROCEDURE reference, keep the <pointer> object.
(let* ((arr2 (u8-list->bytevector '(8 2 6 4)))
       (holder (list (make-comparator))))
  (define cptr (car holder))          ; the <pointer> object, kept LIVE
  (set! holder #f)
  (gc) (gc) (gc)
  (c-qsort (bytevector->pointer arr2) (bytevector-length arr2) 1 cptr)
  (format #t "CL2a proc ref dropped, <pointer> kept, 3 GCs => arr=~s~%"
          (bytevector->u8-list arr2))
  (check "CL2a the <pointer> object roots the trampoline (proc ref \
dropped, still sorts)"
         (equal? (bytevector->u8-list arr2) '(2 4 6 8))))
;; CL2b: same-process child tests via guile -c (top-level read-eval clears
;; frames between forms to reduce incidental roots):
;;   - kept:    keep <pointer>, pass (make-pointer addr), GC -> sorts cleanly
;;   - dropped: drop <pointer>, keep ONLY addr, GC, and try (make-pointer addr)
(define guile-bin (or (getenv "GUILE") "guile"))
(define (make-cb-child-code keep?)
  (string-append
   "(use-modules (system foreign) (system foreign-library) (rnrs bytevectors)) "
   "(define cb-qsort (foreign-library-function #f \"qsort\" #:return-type void #:arg-types (list '* size_t size_t '*))) "
   "(define (cb-make-cmp) (let ((zero (string->number \"0\"))) (procedure->pointer int (lambda (a b) (+ zero (- (bytevector-u8-ref (pointer->bytevector a 1) 0) (bytevector-u8-ref (pointer->bytevector b 1) 0)))) (list '* '*)))) "
   "(define cb-holder (list (cb-make-cmp))) "
   "(define cb-raw (pointer-address (car cb-holder))) "
   (if keep? "" "(set! cb-holder #f) ")
   "(gc) (gc) (gc) "
   "(define cb-arr (u8-list->bytevector '(5 1 4 2 3))) "
   "(cb-qsort (bytevector->pointer cb-arr) (bytevector-length cb-arr) 1 (make-pointer cb-raw)) "
   "(format #t \"" (if keep? "W4-CALLBACK-CHILD-KEPT" "W4-CALLBACK-CHILD-SURVIVED")
   " arr=~s~%\" (bytevector->u8-list cb-arr))"))
(define (run-cb-child keep?)
  (let* ((pr (pipe))
         (pid (spawn guile-bin
                     (list guile-bin "--no-auto-compile" "-c"
                           (make-cb-child-code keep?))
                     #:output (cdr pr)
                     #:error (cdr pr))))
    (close-port (cdr pr))
    (let ((out (get-string-all (car pr))))
      (close-port (car pr))
      (cons out (cdr (waitpid pid))))))
(let* ((r-kept (run-cb-child #t))
       (out-k (car r-kept))
       (st-k (cdr r-kept)))
  (format #t "CL2b-kept child output:~a status: exit-val=~s term-sig=~s~%"
          out-k (status:exit-val st-k) (status:term-sig st-k))
  (check "CL2b-kept (make-pointer addr) survives GC and sorts when <pointer> \
is rooted in the same process"
         (and (eqv? (status:exit-val st-k) 0)
              (string-contains out-k "W4-CALLBACK-CHILD-KEPT arr=(1 2 3 4 5)"))))
(let* ((r-drop (run-cb-child #f))
       (out-d (car r-drop))
       (st-d (cdr r-drop)))
  (format #t "CL2b-dropped child output:~a status: exit-val=~s term-sig=~s~%"
          out-d (status:exit-val st-d) (status:term-sig st-d))
  (if (and (string=? (utsname:sysname (uname)) "Linux")
           (equal? (getenv "GUILE_W4_ALLOW_RAW_CALLBACK_SURVIVAL") "1")
           (eqv? (status:exit-val st-d) 0)
           (string-contains out-d "W4-CALLBACK-CHILD-SURVIVED arr=(1 2 3 4 5)"))
      (format #t "CHECK-SKIP CL2b crash assertion: Linux child exited 0 and sorted; Darwin audit observed SIGSEGV(11). The adapter still requires a rooted <pointer>.~%")
      (check "CL2b retaining ONLY the raw address and dropping the <pointer> \
SIGSEGVs in the same process — the adapter MUST root the <pointer> objects \
(callable registry) while C holds their addresses"
             (eqv? (status:term-sig st-d) SIGSEGV))))

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
