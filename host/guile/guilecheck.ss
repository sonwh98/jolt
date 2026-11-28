#!no-fold-case
;; host/guile/guilecheck.ss — Comprehensive Phase 3a verification gate for Guile 3.0.11.
;; Runs under an internal SIGALRM watchdog so concurrency tests fail promptly on deadlock.

(sigaction SIGALRM
  (lambda (_sig)
    (format (current-error-port) "guilecheck: WATCHDOG TIMEOUT exceeded\n")
    (primitive-_exit 2)))
(alarm 90)

(let ((existing (resolve-module '(jolt runtime) #f #f #:ensure #f)))
  (unless (and existing (module-variable existing '%jolt-boot-module))
    (let* ((here (let ((cf (current-filename))) (and cf (dirname cf))))
           (cwd-boot (string-append (getcwd) "/host/guile/boot.ss"))
           (boot-path
             (cond
               ((and here (file-exists? (string-append here "/boot.ss")))
                (canonicalize-path (string-append here "/boot.ss")))
               ((file-exists? cwd-boot) cwd-boot)
               (else (error 'guilecheck "cannot locate host/guile/boot.ss")))))
      (primitive-load boot-path))))

(define %jolt-adaptercheck-library-only? #t)
(let* ((here (let ((cf (current-filename))) (and cf (dirname cf))))
       (adapter-path
         (cond
           ((and here (file-exists? (string-append here "/../scheme-adapter/guile.ss")))
            (canonicalize-path (string-append here "/../scheme-adapter/guile.ss")))
           (else (canonicalize-path (string-append (getcwd) "/host/scheme-adapter/guile.ss"))))))
  (primitive-load adapter-path))

(eval
 '(begin
    (use-modules (system base compile) (system vm disassembler))

    (define %gc-passed 0)
    (define %gc-failed 0)
    (define %gc-mu (make-mutex))

    (define (gc-pass! label)
      (jolt-with-mutex %gc-mu
        (set! %gc-passed (+ %gc-passed 1))))

    (define (gc-fail! label detail)
      (jolt-with-mutex %gc-mu
        (set! %gc-failed (+ %gc-failed 1))
        (format (current-error-port) "  FAIL  ~a: ~a\n" label detail)))

    (define (check label actual expected)
      (if (equal? actual expected)
          (gc-pass! label)
          (gc-fail! label (format #f "expected ~s, got ~s" expected actual))))

    (define (check-true label cond-val)
      (if cond-val
          (gc-pass! label)
          (gc-fail! label (format #f "expected true, got ~s" cond-val))))

    (define (check-raise-message label thunk expected-sub)
      (guard (e ((message-condition? e)
                 (let ((msg (condition-message e)))
                   (if (and (string? msg) (positive? (string-length msg))
                            (or (not expected-sub) (string-contains msg expected-sub)))
                       (gc-pass! label)
                       (gc-fail! label (format #f "message ~s missing ~s" msg expected-sub)))))
                (#t (gc-fail! label (format #f "raised non-message condition ~s" e))))
        (thunk)
        (gc-fail! label "did not raise")))

    (define (run-parallel! nthreads worker-fn)
      (let* ((errs (make-atomic-box '()))
             (threads
               (let loop ((i 0) (acc '()))
                 (if (fx=? i nthreads)
                     (reverse acc)
                     (loop (fx+ i 1)
                           (cons
                             (fork-thread
                               (lambda ()
                                 (catch #t
                                   (lambda () (worker-fn i))
                                   (lambda (k . a)
                                     (let retry ()
                                       (let* ((cur (atomic-box-ref errs))
                                              (nxt (cons (list i k a) cur)))
                                         (unless (sa-box-cas! errs cur nxt) (retry))))))))
                             acc))))))
        (for-each join-thread threads)
        (let ((es (atomic-box-ref errs)))
          (unless (null? es)
            (error 'run-parallel! "worker thread failed" es)))))

    (format #t "== 1. Shared adaptercheck driver ==\n")
    (check-true "CONTRACT.txt satisfied via host/scheme-adapter/guile.ss"
                (jolt-guile-adapter-check!))

    (format #t "== 2. Syntax forms, reader escapes, case sensitivity, eval ==\n")
    (check "sa-ufx+" (sa-ufx+ 17 25) 42)
    (check "sa-ufx-" (sa-ufx- 50 8) 42)
    (check "sa-ufx<?" (list (sa-ufx<? 1 2) (sa-ufx<? 2 1)) '(#t #f))
    (check "sa-ufx>=?" (list (sa-ufx>=? 2 2) (sa-ufx>=? 1 2)) '(#t #f))
    (check "sa-ufx=?" (list (sa-ufx=? 5 5) (sa-ufx=? 5 6)) '(#t #f))
    (let ((v (vector 10 20 30)))
      (sa-uvector-set! v 1 99)
      (check "sa-uvector-ref/set!" (sa-uvector-ref v 1) 99))
    (check "sa-ustring-ref" (sa-ustring-ref "jolt" 2) #\l)
    (let ((fv (make-flvector 2 1.25)))
      (sa-uflvector-set! fv 1 3.5)
      (check "sa-uflvector-ref/set!" (sa-uflvector-ref fv 1) 3.5))
    (let ((bv (make-bytevector 8 0)))
      (sa-ubytevector-ieee-double-native-set! bv 0 6.25)
      (check "sa-ubytevector-ieee-double" (sa-ubytevector-ieee-double-native-ref bv 0) 6.25)
      (sa-ubytevector-ieee-single-native-set! bv 0 1.5)
      (check "sa-ubytevector-ieee-single" (sa-ubytevector-ieee-single-native-ref bv 0) 1.5))

    ;; Reader probes in eval + string ports + child thread
    (check "r6rs hex escape string"
           (eval '(string=? "\x41;\x20;\x3bb;" (string #\A #\space (integer->char #x3bb))))
           #t)
    (check "vu8 bytevector literal"
           (eval '(bytevector->u8-list #vu8(1 2 255)))
           '(1 2 255))
    (check "r7rs quoted symbol"
           (symbol->string (read (open-input-string "|hello world|")))
           "hello world")
    (check "case sensitivity default + post-boot eval"
           (let ((s1 (read (open-input-string "Foo")))
                 (s2 (read (open-input-string "foo")))
                 (s3 (eval '(quote Bar)))
                 (s4 (eval '(quote bar))))
             (and (not (eq? s1 s2)) (not (eq? s3 s4))))
           #t)
    (check-true "interaction-environment is jolt boot module"
                (eq? (interaction-environment) (jolt-boot-module)))

    ;; eval isolation across module switches and threads
    (let ((saved-mod (current-module))
          (saved-eval eval)
          (saved-env interaction-environment))
      (dynamic-wind
        void
        (lambda ()
          (let ((other (make-module)))
            (set-current-module other)
            (check "eval 1-arg resolves in jolt module even when caller switched modules"
                   (number? (saved-eval '(sa-real-time-ms)))
                   #t)
            (check "interaction-environment stays jolt boot module"
                   (eq? (saved-env) (saved-eval '(interaction-environment)))
                   #t)))
        (lambda () (set-current-module saved-mod))))
    (let ((child-eval-ok #f))
      (join-thread
        (fork-thread
          (lambda ()
            (set! child-eval-ok
              (and (eq? (interaction-environment) (jolt-boot-module))
                   (equal? (eval '(jolt-str (keyword #f "x") "=" 7)) ":x=7")
                   (not (eq? (read (open-input-string "AbC"))
                             (read (open-input-string "abc")))))))))
      (check-true "worker thread eval + reader options" child-eval-ok))

    (format #t "== 3. Records, record? trap, atomic-box CAS ==\n")
    (check "record? #f on eq hashtable" (record? (make-eq-hashtable)) #f)
    (check "record? #f on weak-eq hashtable" (record? (make-weak-eq-hashtable)) #f)
    (check "record? #f on weak-eqv hashtable" (record? (make-weak-eqv-hashtable)) #f)
    (check "record? #f on vector/string/procedure"
           (list (record? #(1)) (record? "x") (record? (lambda () 1)))
           '(#f #f #f))

    (define-record-type %chk-base
      (fields (immutable tag) (mutable slot %chk-base-slot %chk-base-slot-set!)))
    (define-record-type %chk-child
      (parent %chk-base)
      (fields (mutable val))
      (protocol (lambda (n) (lambda (t s v) ((n t s) v)))))
    (let ((c (make-%chk-child 't0 's0 'v0))
          (parent-acc (record-accessor (record-type-descriptor %chk-base) 1))
          (parent-mut (record-mutator (record-type-descriptor %chk-base) 1))
          (child-acc (record-accessor (record-type-descriptor %chk-child) 0)))
      (check "child record? #t" (record? c) #t)
      (check "parent-inclusive predicate" (list (%chk-base? c) (%chk-child? c)) '(#t #t))
      (check "record-field-mutable?" (list (record-field-mutable? (record-type-descriptor %chk-base) 0)
                                           (record-field-mutable? (record-type-descriptor %chk-base) 1)
                                           (record-field-mutable? (record-type-descriptor %chk-child) 0))
             '(#f #t #t))
      (check "parent-first record CAS on inherited slot"
             (list (sa-record-cas! c 1 's0 's1) (%chk-base-slot c) (parent-acc c))
             '(#t s1 s1))
      (parent-mut c 's2)
      (check "record-mutator updates same atomic box" (%chk-base-slot c) 's2)
      (check "child slot CAS + accessor parity"
             (list (sa-record-cas! c 2 'v0 'v1) (%chk-child-val c) (child-acc c))
             '(#t v1 v1))
      (check "record CAS fails cleanly on stale expected value"
             (list (sa-record-cas! c 2 'wrong 'v2) (%chk-child-val c))
             '(#f v1)))
    (check "internal define-record-type in lambda"
           ((lambda (x)
              (define-record-type inner-box (fields (mutable v)))
              (let ((b (make-inner-box x)))
                (sa-record-cas! b 0 x (* x 2))
                (inner-box-v b)))
            21)
           42)

    (format #t "== 4. hasheq JVM/Chez goldens ==\n")
    (for-each
      (lambda (pair)
        (check (format #f "hasheq ~s" (car pair))
               (jolt-hasheq (cadr pair))
               (caddr pair)))
      `((nil ,jolt-nil 0)
        (true #t 1231)
        (false #f 1237)
        (zero 0 0)
        (one 1 1392991556)
        (neg1 -1 1651860712)
        (ft 42 1871679806)
        (d0 0.0 0)
        (dn0 -0.0 0)
        (d15 1.5 1073217536)
        (ch #\a 97)
        (str "hello" 1715862179)
        (astral ,(string (integer->char #x1F600)) -1934073014)
        (kw-bare ,(keyword #f "foo") 1268894036)
        (kw-ns ,(keyword "ns" "bar") -1386250109)
        (sym-bare ,(jolt-symbol #f "sym") 195671222)
        (sym-ns ,(jolt-symbol "ns" "sym") 195658483)
        (vec ,(jolt-vector 1 2 3) 736442005)
        (map ,(jolt-hash-map (keyword #f "a") 1 (keyword #f "b") 2) 161871944)
        (set ,(jolt-hash-set (keyword #f "a") (keyword #f "b")) 551401264)
        (ratio 1/3 2)
        (big ,(expt 2 80) 62980096)))

    (check "sa-flonum->bits/bits->flonum roundtrip"
           (list (sa-flonum->bits -2.5) (sa-bits->flonum (sa-flonum->bits -2.5)))
           (list #xc004000000000000 -2.5))
    (check "sa-flonum-hi32/hi32->flonum roundtrip"
           (list (sa-flonum-hi32 2.5) (sa-hi32->flonum (sa-flonum-hi32 2.5)))
           (list #x40040000 2.5))

    (format #t "== 5. Threads, system, IO, continuations, refusals ==\n")
    (let ((tp (make-thread-parameter 'root)))
      (tp 'parent-set)
      (let* ((seen #f)
             (t (fork-thread (lambda () (set! seen (tp)) (tp 'child-set) (tp))))
             (child-val (join-thread t)))
        (check "thread parameter inherits and isolates mutation"
               (list seen child-val (tp))
               '(parent-set child-set parent-set))))
    (let* ((main-id (get-thread-id))
           (child-id #f)
           (t (fork-thread (lambda () (set! child-id (get-thread-id)) (sa-thread-id-of (current-thread)))))
           (child-id-of (join-thread t)))
      (check-true "thread IDs are distinct exact integers"
                  (and (exact-integer? main-id)
                       (exact-integer? child-id)
                       (not (= main-id child-id))
                       (= child-id child-id-of))))
    (let ((mu (make-mutex)))
      (check-true "mutex-acquire #f succeeds when free" (mutex-acquire mu #f))
      (check "non-recursive mutex-acquire #f fails when held" (mutex-acquire mu #f) #f)
      (mutex-release mu))
    (let ((cv (make-condition))
          (mu (make-mutex)))
      (jolt-with-mutex mu
        (check "condition-wait times out on SRFI-19 duration"
               (condition-wait cv mu (srfi19:make-time 'time-duration 2000000 0))
               #f)))
    (sleep (srfi19:make-time 'time-duration 2000000 0))
    (gc-pass! "subsecond SRFI-19 sleep")
    (check-true "current-time 0-arg and 1-arg"
                (and (srfi19:time? (current-time))
                     (srfi19:time? (current-time 'time-utc))
                     (srfi19:time? (current-time 'time-monotonic))))
    (check "system returns exit code" (list (system "true") (system "exit 3")) '(0 3))
    (call-with-values
      (lambda () (sa-run-process "printf out; printf err >&2; exit 7" (native-transcoder)))
      (lambda (p-in p-out p-err pid)
        (close-port p-in)
        (let ((so (get-string-all p-out))
              (se (get-string-all p-err)))
          (close-port p-out)
          (close-port p-err)
          (check "sa-run-process stdout/stderr/exit"
                 (list so se (status:exit-val (cdr (waitpid pid))))
                 '("out" "err" 7)))))
    (check-true "sa-environment-pairs alist" (and (list? (sa-environment-pairs))
                                                  (pair? (car (sa-environment-pairs)))))
    (check-true "sa-stats 7-slot vector"
                (let ((st (sa-stats)))
                  (and (vector? st) (= (vector-length st) 7)
                       (for-all exact-integer? (vector->list st)))))

    ;; Misc + vector/string/bv copy ranges (overlap safe)
    (check "sort takes pred list" (sort < '(3 1 2)) '(1 2 3))
    (let ((ht (make-eq-hashtable)))
      (hashtable-set! ht 'a 1)
      (check "hashtable-cells returns vector of pairs" (hashtable-cells ht) '#((a . 1)))
      (check "hashtable-values returns vector" (hashtable-values ht) '#(1)))
    (let ((v (vector 0 1 2 3 4)))
      (sa-vector-copy-range! v 1 v 0 3)
      (check "sa-vector-copy-range! overlapping forward shift" v '#(0 0 1 2 4)))
    (let ((s (string-copy "abcde")))
      (sa-string-copy-range! s 1 s 0 3)
      (check "sa-string-copy-range! overlapping forward shift" s "aabce"))
    (let ((bv (u8-list->bytevector '(0 1 2 3 4))))
      (sa-bytevector-copy-range! bv 1 bv 0 3)
      (check "sa-bytevector-copy-range! overlapping forward shift"
             (bytevector->u8-list bv) '(0 0 1 2 4)))

    ;; Continuations + negative controls
    (check "escape normal multi-value return"
           (call-with-values
             (lambda () (sa-call-with-escape-continuation (lambda (_k) (values 'a 'b))))
             list)
           '(a b))
    (check "escape aborted multi-value return"
           (call-with-values
             (lambda () (sa-call-with-escape-continuation (lambda (k) (k 10 20 30) 'unreachable)))
             list)
           '(10 20 30))
    (let ((saved-k #f))
      (sa-call-with-escape-continuation (lambda (k) (set! saved-k k) 'normal))
      (check-raise-message "calling saved escape continuation after normal return refuses"
                           (lambda () (saved-k 1))
                           "expired"))
    (let ((saved-k #f))
      (sa-call-with-escape-continuation (lambda (k) (set! saved-k k) (k 'ok)))
      (check-raise-message "calling escape continuation twice refuses"
                           (lambda () (saved-k 2))
                           "expired"))
    (let ((outer-k #f) (attempted? #f) (reenter-msg #f))
      (guard (e ((message-condition? e) (set! reenter-msg (condition-message e))))
        (sa-call-with-escape-continuation
          (lambda (_ek)
            (call/cc (lambda (ik) (set! outer-k ik)))
            'done)))
      (unless attempted?
        (set! attempted? #t)
        (outer-k #f))
      (check-true "re-entering spent escape continuation raises"
                  (and (string? reenter-msg)
                       (string-contains reenter-msg "spent"))))

    ;; Honest refusals on degraded capabilities
    (check-raise-message "sa-compile-file refusal" (lambda () (sa-compile-file "a" "b" #f)) "unsupported")
    (check-raise-message "sa-make-boot-file refusal" (lambda () (sa-make-boot-file "a" '())) "unsupported")
    (check-raise-message "sa-fasl-write refusal" (lambda () (sa-fasl-write 1 (current-output-port))) "unsupported")
    (check-raise-message "sa-fasl-read refusal" (lambda () (sa-fasl-read (current-input-port))) "unsupported")
    (check-raise-message "sa-foreign-alloc refusal" (lambda () (sa-foreign-alloc 8)) "unsupported")
    (check-raise-message "sa-foreign-procedure expanded call refusal"
                         (lambda () ((sa-foreign-procedure "abs" (int) int) -1))
                         "unsupported")
    (check-raise-message "sa-foreign-callable syntax refusal"
                         (lambda () (sa-foreign-callable (lambda (x) x) (int) int))
                         "unsupported")
    (check-raise-message "sa-fiber-spawn refusal" (lambda () (sa-fiber-spawn (lambda () 1))) "unsupported")
    (check "sa-term-open degraded false" (sa-term-open) #f)
    (check-raise-message "sa-term-raw! refusal" (lambda () (sa-term-raw!)) "unsupported")
    (sa-lock-object (make-bytevector 4))
    (sa-unlock-object (make-bytevector 4))
    (gc-pass! "sa-lock-object / sa-unlock-object no-op")

    (format #t "== 6. GC hook, sa-file-mtime-ms, and fence bytecode lowering ==\n")
    (let ((obs-count 0))
      (check "sa-gc-install-after-collect! returns #t"
             (sa-gc-install-after-collect!
               (lambda (collect-full!) (when (= obs-count 0) (collect-full!)))
               (lambda (pause interval)
                 (when (and (exact-integer? pause) (>= pause 0)
                            (exact-integer? interval) (>= interval 0))
                   (set! obs-count (+ obs-count 1)))))
             #t)
      (sa-gc-collect)
      (check-true "after-gc-hook observed real collection cleanly" (>= obs-count 1)))

    (let ((f "build/guile/mtime-test.tmp"))
      (call-with-output-file f (lambda (p) (display "mtime" p)))
      (check "set subsecond positive mtime"
             (system (string-append "python3 -c 'import os; os.utime(\"" f "\", ns=(1700000000456789000, 1700000000456789000))'"))
             0)
      (check "sa-file-mtime-ms subsecond positive 1700000000456" (sa-file-mtime-ms f) 1700000000456)
      (check "set negative pre-1970 mtime"
             (system (string-append "python3 -c 'import os; os.utime(\"" f "\", ns=(-9750000000, -9750000000))'"))
             0)
      (check "sa-file-mtime-ms negative pre-1970 -9750" (sa-file-mtime-ms f) -9750)
      (delete-file f))
    (check-raise-message "sa-file-mtime-ms missing file raises"
                         (lambda () (sa-file-mtime-ms "build/guile/definitely-missing-file-12345"))
                         "stat failed")

    (let* ((p (open-output-string))
           (c-rel (compile '(lambda () (memory-order-release)) #:env (interaction-environment)))
           (c-acq (compile '(lambda () (memory-order-acquire)) #:env (interaction-environment))))
      (parameterize ((current-output-port p))
        (disassemble-program c-rel)
        (disassemble-program c-acq))
      (let ((dasm (get-output-string p)))
        (check-true "memory-order-release compiles to call (not eliminated)"
                    (and (string-contains dasm "memory-order-release")
                         (string-contains dasm "tail-call")))
        (check-true "memory-order-acquire compiles to call (not eliminated)"
                    (and (string-contains dasm "memory-order-acquire")
                         (string-contains dasm "tail-call")))))

    (format #t "== 7. arm64 multi-thread concurrency races ==\n")
    ;; 7a: cseq tail forcing, claiming, exception rollback, fast reader
    (let ((seq-n 250))
      (let ((mk-seq
              (lambda ()
                (let ((attempts (make-atomic-box 0)))
                  (letrec ((build
                             (lambda (i)
                               (if (= i seq-n)
                                   jolt-nil
                                   (cseq-lazy
                                     i
                                     (lambda ()
                                       (let retry ()
                                         (let ((a (atomic-box-ref attempts)))
                                           (unless (sa-box-cas! attempts a (+ a 1)) (retry))))
                                       (build (+ i 1))))))))
                    (build 0))))))
        (let ((s (mk-seq)))
          (run-parallel! 8
            (lambda (_tid)
              (let loop ((cur s) (expected 0))
                (unless (jolt-nil? cur)
                  (unless (= (seq-first cur) expected)
                    (error 'cseq-race "corrupt head element" expected (seq-first cur)))
                  (loop (seq-more cur) (+ expected 1))))))
          (gc-pass! "cseq concurrent tail publication across 8 threads"))
        ;; Exception rollback check: failing tail must release claim so another caller observes recovery too
        (let* ((toggle (make-atomic-box #t))
               (s (cseq-lazy 0
                    (lambda ()
                      (if (sa-box-cas! toggle #t #f)
                          (error 'cseq-tail "transient tail fault")
                          (cseq-realized 1 jolt-nil))))))
          (check-raise-message "cseq first tail fault raises" (lambda () (seq-more s)) "transient tail fault")
          (check "cseq rolled back claim retries cleanly" (seq-first (seq-more s)) 1))))

    ;; 7b: jolt-lazyseq multi-thread forcing race
    (let* ((forced (make-atomic-box 0))
           (make-ls
             (letrec ((mk (lambda (k)
                            (jolt-make-lazy-seq
                              (lambda ()
                                (let retry ()
                                  (let ((c (atomic-box-ref forced)))
                                    (unless (sa-box-cas! forced c (+ c 1)) (retry))))
                                (if (= k 0)
                                    jolt-nil
                                    (jolt-cons k (mk (- k 1)))))))))
               mk))
           (ls (make-ls 60)))
      (run-parallel! 8
        (lambda (_tid)
          (let loop ((cur (jolt-seq ls)) (expected 60))
            (if (= expected 0)
                (unless (jolt-nil? cur) (error 'lazyseq-race "expected nil tail"))
                (begin
                  (unless (= (seq-first cur) expected)
                    (error 'lazyseq-race "mismatch" expected (seq-first cur)))
                  (loop (jolt-seq (seq-more cur)) (- expected 1)))))))
      (check "jolt-lazyseq realized once per node under 8-thread race"
             (atomic-box-ref forced) 61))

    ;; 7c: PIC emitted call shape + jolt-pic-site-* + jolt-proto-epoch-ref race (>4 types + invalidations)
    (let* ((proto-name "guile.check/P")
           (method-name "pm")
           (_p (register-protocol-methods! proto-name (jolt-vector method-name)))
           (tags (list "guile.check.T0" "guile.check.T1" "guile.check.T2"
                       "guile.check.T3" "guile.check.T4" "guile.check.T5"))
           (descs (map (lambda (tag i)
                         (let ((d (make-jrdesc tag '())))
                           (hashtable-set! chez-tag-desc tag d)
                           (register-protocol-method tag proto-name method-name (lambda (_self) i))
                           d))
                       tags '(0 1 2 3 4 5)))
           (recs (list->vector (map (lambda (d) (make-jrec0 d jolt-nil 0)) descs)))
           (_picv$ (jolt-pic-site-make))
           (top (* jolt-pic-n 2))
           (call-pic
             (lambda (r)
               (let* ((_v (jolt-pic-site-ref _picv$))
                      (_d (jrec-pic-desc r))
                      (ep (jolt-proto-epoch-ref)))
                 (unless (vector? _v) (error 'pic-race "incomplete vector ref" _v))
                 (let ((impl
                         (if (and _d (fx=? (vector-ref _v top) ep))
                             (or (and (eq? (vector-ref _v 0) _d) (vector-ref _v 1))
                                 (and (eq? (vector-ref _v 2) _d) (vector-ref _v 3))
                                 (and (eq? (vector-ref _v 4) _d) (vector-ref _v 5))
                                 (and (eq? (vector-ref _v 6) _d) (vector-ref _v 7))
                                 (let ((_nv (jolt-pic-add _v _d proto-name method-name r)))
                                   (if (procedure? _nv)
                                       _nv
                                       (begin (jolt-pic-site-set! _picv$ _nv)
                                              (vector-ref _nv 1)))))
                             (if _d
                                 (let ((_nv (jolt-pic-add _v _d proto-name method-name r)))
                                   (if (procedure? _nv)
                                       _nv
                                       (begin (jolt-pic-site-set! _picv$ _nv)
                                              (vector-ref _nv 1))))
                                 (protocol-resolve proto-name method-name r)))))
                   (impl r)))))
           (stop (make-atomic-box #f)))
      (let ((writer
              (fork-thread
                (lambda ()
                  (let loop ((gen 1))
                    (when (<= gen 40)
                      (for-each
                        (lambda (tag i)
                          (register-protocol-method tag proto-name method-name
                            (lambda (_self) (+ (* gen 100) i))))
                        tags '(0 1 2 3 4 5))
                      (loop (+ gen 1))))
                  (atomic-box-set! stop #t)))))
        (run-parallel! 6
          (lambda (tid)
            (let loop ((n 0))
              (unless (and (atomic-box-ref stop) (>= n 400))
                (let* ((idx (modulo (+ n tid) 6))
                       (r (vector-ref recs idx))
                       (got (call-pic r))
                       (base (modulo got 100)))
                  (unless (= base idx)
                    (error 'pic-race "wrong type dispatch" idx got)))
                (loop (+ n 1))))))
        (join-thread writer))
      ;; Final agreement against uncached protocol-resolve
      (for-each
        (lambda (r)
          (unless (= (call-pic r) ((protocol-resolve proto-name method-name r) r))
            (error 'pic-race "post-update PIC disagrees with uncached resolve")))
        (vector->list recs))
      (gc-pass! "PIC hot-site race & uncached equivalence"))

    ;; 7d: jolt-instance-site race against class arm / protocol / hierarchy changes
    (let ((site (jolt-instance-site-make))
          (t-map (jolt-symbol #f "clojure.lang.IPersistentMap"))
          (samples (list (jolt-hash-map (keyword #f "a") 1)
                         (jolt-vector 1 2)
                         "str"
                         42
                         (jolt-hash-set (keyword #f "k"))))
          (stop (make-atomic-box #f)))
      (let ((writer
              (fork-thread
                (lambda ()
                  (let loop ((k 0))
                    (when (< k 30)
                      (jch-register-leaf! (format #f "guile.inst.Leaf~a" k)
                                          '("java.lang.Object"))
                      (register-class-arm! (lambda (_x) #f) (lambda (_x) #f))
                      (loop (+ k 1))))
                  (atomic-box-set! stop #t)))))
        (run-parallel! 6
          (lambda (tid)
            (let loop ((n 0))
              (unless (and (atomic-box-ref stop) (>= n 300))
                (let* ((v (list-ref samples (modulo (+ n tid) (length samples))))
                       (ans (jolt-instance-site site t-map v))
                       (uncached (if (instance-check t-map v) #t #f)))
                  (unless (eq? ans uncached)
                    (error 'instance-site-race "mismatch" v ans uncached)))
                (loop (+ n 1))))))
        (join-thread writer))
      (gc-pass! "jolt-instance-site race & uncached equivalence"))

    ;; 7e: keyword, symbol-string-pool, and weak meta-table growth / GC / deletion race
    (run-parallel! 8
      (lambda (tid)
        (let loop ((i 0))
          (when (< i 300)
            (let* ((k-shared (keyword "race" (format #f "k~a" (modulo i 25))))
                   (k-shared2 (keyword "race" (format #f "k~a" (modulo i 25))))
                   (s1 (jolt-symbol #f (format #f "sym~a" (modulo i 25))))
                   (s2 (jolt-symbol #f (format #f "sym~a" (modulo i 25)))))
              (unless (eq? k-shared k-shared2)
                (error 'intern-race "keyword lost intern identity"))
              (unless (eq? (symbol-t-ncell s1) (symbol-t-ncell s2))
                (error 'intern-race "symbol-string-pool cell mismatch"))
              ;; Retain one key in meta-table while churning ephemeral keys to force growth + weak GC
              (let ((ephem (vector 'ephem tid i)))
                (meta-table-set! ephem (jolt-hash-map (keyword #f "i") i))
                (when (= (modulo i 50) 0) (meta-table-del! ephem))))
            (loop (+ i 1))))))
    (let ((retained (vector 'retained 'keep))
          (kw-kept (keyword #f "kept")))
      (meta-table-set! retained (jolt-hash-map kw-kept 999))
      (run-parallel! 4
        (lambda (tid)
          (let loop ((i 0))
            (when (< i 200)
              (let ((ephem (vector 'ephem i)))
                (meta-table-set! ephem (jolt-hash-map (keyword #f "t") tid))
                (when (= (modulo i 40) 0) (gc))
                (meta-table-del! ephem))
              (unless (= (jolt-get (meta-table-get retained) kw-kept jolt-nil) 999)
                (error 'meta-race "retained key lost metadata"))
              (loop (+ i 1))))))
      (check "retained key meta survived growth/GC/deletion race"
             (jolt-get (meta-table-get retained) kw-kept jolt-nil)
             999))

    ;; 7f: multimethods callback-keyed re-entrancy & concurrent dispatch vs defmethod
    (let ((mf (make-jolt-multifn "race-mm" (lambda (x) x) (new-mm-table)
                                 (keyword #f "default") #f (new-mm-table)
                                 (sa-mm-cache-make key-hash jolt=) -1 #f))
          (mf-inner (make-jolt-multifn "inner-mm" (lambda (x) x) (new-mm-table)
                                       (keyword #f "default") #f (new-mm-table)
                                       (sa-mm-cache-make key-hash jolt=) -1 #f))
          (sym-race (jolt-symbol "user" "race-mm"))
          (sym-inner (jolt-symbol "user" "inner-mm")))
      (def-var! "user" "race-mm" mf)
      (def-var! "user" "inner-mm" mf-inner)
      (jolt-defmethod-setup sym-inner (keyword #f "default") (lambda (x) x) "user")
      (jolt-defmethod-setup sym-race (keyword #f "default") (lambda (x) (list 'def x)) "user")
      (jolt-defmethod-setup sym-race 'alpha (lambda (x) (list 'alpha x)) "user")
      (jolt-defmethod-setup sym-race 'beta (lambda (x) (list 'beta x)) "user")
      ;; Install custom eq/hasheq arm whose key-hash / jolt= re-enters BOTH multimethods
      ;; and updates defmethod inside the callback (proving mm-tbl-mu never wraps callbacks!)
      (letrec ((reentrant-tag (list 'reentrant))
               (reentrant? (lambda (x) (and (pair? x) (eq? (car x) reentrant-tag)))))
        (register-eq-arm!
          (lambda (a b) (or (reentrant? a) (reentrant? b)))
          (lambda (a b)
            (and (reentrant? a) (reentrant? b)
                 (begin
                   (jolt-defmethod-setup sym-inner (cadr a) (lambda (v) v) "user")
                   (multifn-dispatch1 mf-inner (cadr a))
                   (equal? (cdr a) (cdr b))))))
        (register-hash-arm!
          reentrant?
          (lambda (x)
            (multifn-dispatch1 mf-inner (cadr x))
            (murmur3-hash-int (cadr x))))
        (let ((rkey1 (list reentrant-tag 10))
              (rkey2 (list reentrant-tag 20))
              (stop (make-atomic-box #f)))
          (jolt-defmethod-setup sym-race rkey1 (lambda (x) (list 'rk1 (cadr x))) "user")
          (let ((writer
                  (fork-thread
                    (lambda ()
                      (let loop ((i 0))
                        (when (< i 40)
                          (jolt-defmethod-setup sym-race 'gamma (lambda (x) (list 'gamma i x)) "user")
                          (jolt-prefer-method-setup mf 'alpha 'beta)
                          (jolt-remove-method-setup mf 'gamma)
                          (loop (+ i 1))))
                      (atomic-box-set! stop #t)))))
            (run-parallel! 6
              (lambda (_tid)
                (let loop ((i 0))
                  (unless (and (atomic-box-ref stop) (>= i 200))
                    (let ((a (multifn-dispatch1 mf 'alpha))
                          (b (multifn-dispatch1 mf rkey1))
                          (c (multifn-dispatch1 mf rkey2)))
                      (unless (and (equal? a '(alpha alpha))
                                   (equal? b '(rk1 10))
                                   (equal? (car c) 'def))
                        (error 'mm-race "unexpected dispatch" a b c)))
                    (loop (+ i 1))))))
            (join-thread writer))
          (gc-pass! "multimethod callback re-entrancy & concurrent mutation/dispatch"))))

    (format #t "\nguilecheck summary: ~a passed, ~a failed\n" %gc-passed %gc-failed)
    (when (> %gc-failed 0)
      (exit 1)))
 (resolve-module '(jolt runtime)))

(alarm 0)
