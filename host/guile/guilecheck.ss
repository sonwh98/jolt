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
                 (s3 (eval ''Bar))
                 (s4 (eval ''bar)))
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
    ;; Synchronized parent/child thread-id lifecycle check (live parent lookup + post-join #f)
    (let* ((main-id (get-thread-id))
           (mu (make-mutex))
           (cv (make-condition))
           (ready? #f)
           (go? #f)
           (child-id #f)
           (child (fork-thread
                    (lambda ()
                      (jolt-with-mutex mu
                        (set! ready? #t)
                        (condition-signal cv)
                        (let wait () (unless go? (condition-wait cv mu) (wait))))
                      (set! child-id (get-thread-id))
                      child-id)))
           (parent-live-id #f))
      (jolt-with-mutex mu
        (let wait () (unless ready? (condition-wait cv mu) (wait)))
        (set! parent-live-id (sa-thread-id-of child))
        (set! go? #t)
        (condition-signal cv))
      (let ((joined-id (join-thread child)))
        (check-true "parent sa-thread-id-of live child matches child get-thread-id"
                    (and (exact-integer? main-id)
                         (exact-integer? parent-live-id)
                         (not (= main-id parent-live-id))
                         (= parent-live-id child-id)
                         (= joined-id child-id)))
        (check "sa-thread-id-of joined thread returns #f"
               (sa-thread-id-of child)
               #f)))
    ;; The broadcaster can take mu after the last readiness signal only
    ;; after that waiter releases it inside condition-wait.
    (let ((mu (make-mutex))
          (cv (make-condition))
          (ready-cv (make-condition))
          (ready 0)
          (done 0)
          (go? #f))
      (let ((waiters
              (map (lambda (_)
                     (fork-thread
                       (lambda ()
                         (jolt-with-mutex mu
                           (set! ready (+ ready 1))
                           (condition-signal ready-cv)
                           (let loop () (unless go? (condition-wait cv mu) (loop)))
                           (set! done (+ done 1))))))
                   '(1 2 3 4))))
        (jolt-with-mutex mu
          (let wait () (unless (= ready 4) (condition-wait ready-cv mu) (wait)))
          (set! go? #t)
          (condition-broadcast cv))
        (for-each join-thread waiters)
        (check "condition-broadcast wakes all 4 parked waiters" done 4)))
    (let ((mu (make-mutex)))
      (check-true "mutex-acquire #f succeeds when free" (mutex-acquire mu #f))
      (check "non-recursive mutex-acquire #f fails when held" (mutex-acquire mu #f) #f)
      (let* ((start (get-internal-real-time))
             (deadline (%deadline-from-timeout
                         (srfi19:make-time 'time-duration 20000000 0)))
             (acquired? (lock-mutex mu deadline))
             (elapsed (- (get-internal-real-time) start)))
        (check "native timed self-acquire on adapter mutex returns #f" acquired? #f)
        (check-true "timed self-acquire waits for its deadline"
                    (>= elapsed (/ internal-time-units-per-second 100))))
      (mutex-release mu))
    (let ((cv (make-condition))
          (mu (make-mutex)))
      (jolt-with-mutex mu
        (check "condition-wait times out on SRFI-19 duration"
               (condition-wait cv mu (srfi19:make-time 'time-duration 2000000 0))
               #f)
        (check "timed condition-wait re-acquires mutex before returning"
               (mutex-acquire mu #f)
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
        (check "sa-run-process pipe fds have FD_CLOEXEC"
               (list (= (logand (fcntl p-in F_GETFD) FD_CLOEXEC) FD_CLOEXEC)
                     (= (logand (fcntl p-out F_GETFD) FD_CLOEXEC) FD_CLOEXEC)
                     (= (logand (fcntl p-err F_GETFD) FD_CLOEXEC) FD_CLOEXEC))
               '(#t #t #t))
        (close-port p-in)
        (let ((so (get-string-all p-out))
              (se (get-string-all p-err)))
          (close-port p-out)
          (close-port p-err)
          (check "sa-run-process stdout/stderr/exit"
                 (list so se (status:exit-val (cdr (waitpid pid))))
                 '("out" "err" 7)))))
    (call-with-values
      (lambda () (sa-run-process "true" (r6io:make-transcoder (r6io:utf-16-codec))))
      (lambda (p-in p-out p-err pid)
        (check "sa-run-process honors explicit UTF-16 transcoder and sets FD_CLOEXEC"
               (list (port-encoding p-in) (port-encoding p-out) (port-encoding p-err)
                     (= (logand (fcntl p-in F_GETFD) FD_CLOEXEC) FD_CLOEXEC)
                     (= (logand (fcntl p-out F_GETFD) FD_CLOEXEC) FD_CLOEXEC)
                     (= (logand (fcntl p-err F_GETFD) FD_CLOEXEC) FD_CLOEXEC))
               '("UTF-16" "UTF-16" "UTF-16" #t #t #t))
        (close-port p-in) (close-port p-out) (close-port p-err) (waitpid pid)))
    (call-with-values
      (lambda () (sa-run-process "true" #f))
      (lambda (p-in p-out p-err pid)
        (check "sa-run-process binary mode uses ISO-8859-1"
               (list (port-encoding p-in) (port-encoding p-out) (port-encoding p-err))
               '("ISO-8859-1" "ISO-8859-1" "ISO-8859-1"))
        (close-port p-in) (close-port p-out) (close-port p-err) (waitpid pid)))
    (let* ((config (module-variable (current-module) '%configure-process-port!))
           (original (variable-ref config))
           (fd-count (lambda () (length ((@ (ice-9 ftw) scandir) "/dev/fd"))))
           (before (fd-count))
           (configured 0))
      (dynamic-wind
        (lambda ()
          (variable-set! config
            (lambda (port transcoder)
              (set! configured (+ configured 1))
              (if (= configured 3)
                  (throw 'port-setup-fault)
                  (original port transcoder)))))
        (lambda ()
          (check "third process port configuration failure propagates"
                 (catch 'port-setup-fault
                   (lambda () (sa-run-process "true" (native-transcoder)) #f)
                   (lambda _ #t))
                 #t))
        (lambda () (variable-set! config original)))
      (check "failed process setup closes every pipe fd" (fd-count) before)
      (check "failed process setup leaves no child"
             (catch 'system-error
               (lambda () (waitpid -1 WNOHANG))
               (lambda args (system-error-errno args)))
             ECHILD))
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
    ;; Escape invoked a second time from inside its own dynamic-wind cleanup MUST raise
    ;; (escaped continuation was consumed before abort), keeping 'first as delivered value.
    (let* ((cleanup-err #f)
           (res (sa-call-with-escape-continuation
                  (lambda (k)
                    (dynamic-wind
                      void
                      (lambda () (k 'first))
                      (lambda ()
                        (guard (e ((message-condition? e) (set! cleanup-err (condition-message e))))
                          (k 'second))))))))
      (check "escape keeps first value when cleanup retries escape" res 'first)
      (check-true "escape retry during own unwind raises expired"
                  (and (string? cleanup-err) (string-contains cleanup-err "expired"))))
    ;; Inner escape expires on exception unwind and on enclosing escape unwind, in inner-first order
    (let ((log '()) (inner-k #f))
      (sa-call-with-escape-continuation
        (lambda (outer-k)
          (dynamic-wind
            void
            (lambda ()
              (sa-call-with-escape-continuation
                (lambda (ik)
                  (set! inner-k ik)
                  (dynamic-wind
                    void
                    (lambda () (outer-k 'outer))
                    (lambda () (set! log (cons 'inner log)))))))
            (lambda () (set! log (cons 'outer log))))))
      (check "nested escape unwinds inner-first" (reverse log) '(inner outer))
      (check-raise-message "inner escape expired by enclosing escape" (lambda () (inner-k 1)) "expired"))
    (let ((saved-k #f))
      (guard (e ((message-condition? e) #t))
        (sa-call-with-escape-continuation (lambda (k) (set! saved-k k) (error 'esc-ex "boom"))))
      (check-raise-message "escape expired after exception unwind" (lambda () (saved-k 1)) "expired"))
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

    ;; Honest refusals & fallback values per DESIGN.md & CONTRACT.txt
    (check "sa-current-stack-bytes unavailable returns #f" (sa-current-stack-bytes) #f)
    (check "profiling cannot be enabled" (sa-profile-instrument! #t) #f)
    (check "debug profiling cannot be enabled" (sa-profile-instrument! 'debug) #f)
    (check "profiling remains disabled" (sa-profile-instrumenting?) #f)
    (check "profiling can be disabled" (sa-profile-instrument! #f) #t)
    (let ((runs 0))
      (check "profile compile returns the thunk result"
             (sa-profile-compile (lambda () (set! runs (+ runs 1)) 'compiled))
             'compiled)
      (check "profile compile calls the thunk once" runs 1))
    (check "profile counts are empty" (sa-profile-counts) '())
    (check "profile release is empty" (sa-profile-release!) '())
    (sa-profile-clear!)
    (check "profiling stays disabled after clear" (sa-profile-instrumenting?) #f)
    (let ((bp "build/guile/no-such-block-profile.bp"))
      (when (file-exists? bp) (delete-file bp))
      (check "sa-block-profile-dump! returns 0" (sa-block-profile-dump! bp 'tag) 0)
      (check "sa-block-profile-dump! writes no file" (file-exists? bp) #f))
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
    (check "sa-gc-install-after-collect! returns #f until ceiling policy is qualified"
           (sa-gc-install-after-collect! (lambda (_) (void)) (lambda (_p _i) (void)))
           #f)
    (let* ((_ (sa-gc-collect))
           (holder (box #f))
           (before (sa-bytes-allocated))
           (bv-bytes (* 16 1024 1024))
           (_alloc (begin
                     (set-box! holder (sa-make-large-bytevector bv-bytes))
                     (bytevector-u8-set! (unbox holder) 0 42)
                     (sa-gc-collect)))
           (retained (sa-bytes-allocated))
           (_drop (begin
                    (set-box! holder #f)
                    (sa-gc-collect)
                    (sa-gc-collect)))
           (released (sa-bytes-allocated)))
      (check-true "large bytevector retained increases sa-bytes-allocated"
                  (and (>= retained (+ before (* 8 1024 1024)))
                       (>= (sa-total-memory-bytes) retained)
                       (= (sa-gc-max-generation) 0)))
      (check-true "dropping large bytevector releases heap across sa-gc-collect"
                  (< released retained)))

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

    ;; Gate the VM ordering here. The native witness disassembles the same
    ;; forms on arm64. Section 7a exercises the actual seq publication paths.
    (format #t "Fence ordering: VM checks and publication races here, arm64 native disassembly in witnesses/w2-fence-jit.scm~%")
    (let* ((find-pos (lambda (haystack needle) (string-contains haystack needle)))
           (p-prod (open-output-string))
           (p-cons (open-output-string))
           (c-prod (compile '(lambda (v bx)
                               (vector-set! v 0 42)
                               (memory-order-release)
                               (atomic-box-set! bx v))
                            #:env (interaction-environment)))
           (c-cons (compile '(lambda (bx)
                               (let ((v (atomic-box-ref bx)))
                                 (memory-order-acquire)
                                 (vector-ref v 0)))
                            #:env (interaction-environment))))
      (parameterize ((current-output-port p-prod)) (disassemble-program c-prod))
      (parameterize ((current-output-port p-cons)) (disassemble-program c-cons))
      (let* ((d-prod (get-output-string p-prod))
             (d-cons (get-output-string p-cons))
             (pos-vset (find-pos d-prod "(scm-set!/immediate"))
             (pos-rel (find-pos d-prod "memory-order-release"))
             (pos-rel-call (and pos-rel (string-contains d-prod "(call " pos-rel)))
             (pos-bset (find-pos d-prod "(atomic-scm-set!/immediate"))
             (pos-bref (find-pos d-cons "(atomic-scm-ref/immediate"))
             (pos-acq (find-pos d-cons "memory-order-acquire"))
             (pos-acq-call (and pos-acq (string-contains d-cons "(call " pos-acq)))
             (pos-vec (and pos-acq-call (string-contains d-cons ";; vector?" pos-acq-call)))
             (pos-vref (and pos-vec (string-contains d-cons "(scm-ref/immediate" pos-vec))))
        (check-true "producer bytecode keeps (scm-set!/immediate) < memory-order-release call < (atomic-scm-set!/immediate)"
                    (and pos-vset pos-rel pos-rel-call pos-bset
                         (< pos-vset pos-rel)
                         (< pos-rel pos-rel-call)
                         (< pos-rel-call pos-bset)))
        (check-true "consumer bytecode keeps (atomic-scm-ref/immediate) < memory-order-acquire call < vector (scm-ref/immediate)"
                    (and pos-bref pos-acq pos-acq-call pos-vec pos-vref
                         (< pos-bref pos-acq)
                         (< pos-acq pos-acq-call)
                         (< pos-acq-call pos-vec)
                         (< pos-vec pos-vref)))))

    (format #t "== 7. arm64 multi-thread concurrency races ==\n")
    ;; 7a: cseq tail forcing, claiming, plain-tail-set race, controls, exception rollback, fast reader
    (let* ((mk-payload
             (lambda (idx)
               (let ((v (make-vector 16 #f)))
                 (let loop ((k 0))
                   (when (< k 16)
                     (vector-set! v k (+ (* idx 100) k))
                     (loop (+ k 1))))
                 v)))
           (payload-valid?
             (lambda (v idx)
               (and (vector? v)
                    (= (vector-length v) 16)
                    (let loop ((k 0))
                      (if (= k 16)
                          #t
                          (and (eqv? (vector-ref v k) (+ (* idx 100) k))
                               (loop (+ k 1)))))))))
      ;; Controls: incomplete payload & failed CAS must be rejected
      (let ((partial (make-vector 16 #f)))
        (vector-set! partial 0 700)
        (check "incomplete-payload control rejects half-initialized vector"
               (payload-valid? partial 7)
               #f))
      (let* ((bx (box 'orig))
             (c (cseq-realized 'h jolt-nil)))
        (check "failed-CAS control on sa-box-cas! leaves original intact"
               (list (sa-box-cas! bx 'wrong 'new) (unbox bx))
               '(#f orig))
        (check "failed-CAS control on sa-record-cas! leaves cseq tail intact"
               (list (sa-record-cas! c cseq-tail-index 'wrong 'new) (jolt-nil? (cseq-tail c)))
               '(#f #t)))

      ;; 8-thread cseq chain walk with thunk invocation count and full vector payload validation
      (let* ((seq-n 250)
             (attempts (make-atomic-box 0))
             (s (letrec ((build
                           (lambda (i)
                             (if (= i seq-n)
                                 jolt-nil
                                 (cseq-lazy
                                   (mk-payload i)
                                   (lambda ()
                                     (let retry ()
                                       (let ((a (atomic-box-ref attempts)))
                                         (unless (sa-box-cas! attempts a (+ a 1)) (retry))))
                                     (build (+ i 1))))))))
                  (build 0))))
        (run-parallel! 8
          (lambda (_tid)
            (let loop ((cur s) (expected 0))
              (unless (jolt-nil? cur)
                (unless (payload-valid? (seq-first cur) expected)
                  (error 'cseq-race "corrupt payload element" expected (seq-first cur)))
                (loop (seq-more cur) (+ expected 1))))))
        (check "cseq-lazy thunk invoked once per cell under 8-thread race"
               (atomic-box-ref attempts) seq-n))

      ;; 2-OS-thread fresh-cell round race with NO barrier between publish/force and read
      (let* ((rounds 120)
             (cells (list->vector (map (lambda (_) #f) (iota rounds))))
             (plain-cells (list->vector (map (lambda (_) #f) (iota rounds))))
             (cvec-heads (list->vector (map (lambda (_) #f) (iota rounds))))
             (cas-calls (make-atomic-box 0))
             (mu (make-mutex))
             (cv (make-condition))
             (round-id (make-atomic-box -1))
             (done-cnt (make-atomic-box 0))
             (finish? #f))
        (let ((w2
                (fork-thread
                  (lambda ()
                    (let loop ((last -1))
                      (let ((r (let wait ()
                                 (let ((cur (atomic-box-ref round-id)))
                                   (if (= cur last)
                                       (begin
                                         (jolt-with-mutex mu
                                           (when (= (atomic-box-ref round-id) last)
                                             (condition-wait cv mu)))
                                         (wait))
                                       cur)))))
                        (when (>= r 0)
                          (let ((c (vector-ref cells r))
                                (pc (vector-ref plain-cells r))
                                (vs (vector-ref cvec-heads r)))
                            ;; Race CAS forcer on c
                            (let ((tail (seq-more c)))
                              (unless (and (cseq? tail)
                                           (= (cseq-kind tail) 0)
                                           (payload-valid? (seq-first tail) (+ r 1)))
                                (error 'cseq-round "w2 bad CAS tail" r tail)))
                            ;; Wait via spinning on plain-tail-set path + fast seq-more reader (no lock)
                            (let spin ()
                              (unless (cseq? (cseq-tail pc)) (spin)))
                            (let ((ptail (seq-more pc)))
                              (unless (and (cseq? ptail)
                                           (payload-valid? (seq-first ptail) (+ r 2))
                                           (payload-valid? (seq-first (seq-more ptail)) (+ r 3)))
                                (error 'cseq-round "w2 bad plain-tail-set payload" r ptail)))
                            ;; Race cvec (not t) plain tail-set path
                            (let ((vt (seq-more vs)))
                              (unless (and (cseq? vt) (payload-valid? (seq-first vt) (+ r 4)))
                                (error 'cseq-round "w2 bad cvec plain-tail-set" r vt))))
                          (let retry ()
                            (let ((d (atomic-box-ref done-cnt)))
                              (unless (sa-box-cas! done-cnt d (+ d 1)) (retry))))
                          (jolt-with-mutex mu (condition-broadcast cv))
                          (unless finish? (loop r)))))))))
          (let loop ((r 0))
            (when (< r rounds)
              (vector-set! cells r
                           (cseq-lazy (mk-payload r)
                                      (lambda ()
                                        (let retry ()
                                          (let ((n (atomic-box-ref cas-calls)))
                                            (unless (sa-box-cas! cas-calls n (+ n 1)) (retry))))
                                        (cseq-realized (mk-payload (+ r 1)) jolt-nil))))
              (vector-set! plain-cells r (cseq-lazy (mk-payload r) (lambda () jolt-nil)))
              (vector-set! cvec-heads r (jolt-seq (jolt-vector (mk-payload r) (mk-payload (+ r 4)))))
              (jolt-with-mutex mu
                (atomic-box-set! done-cnt 0)
                (atomic-box-set! round-id r)
                (condition-broadcast cv))
              ;; Producer / competitor forces cell r AND runs unbarriered cseq-publish-tail!
              (let ((c (vector-ref cells r))
                    (pc (vector-ref plain-cells r))
                    (vs (vector-ref cvec-heads r)))
                (let ((tail (seq-more c)))
                  (unless (and (cseq? tail) (payload-valid? (seq-first tail) (+ r 1)))
                    (error 'cseq-round "w1 bad CAS tail" r tail)))
                ;; Plain tail-set publication path with unshared private vector init -> release -> set
                (let ((t2 (cseq-realized (mk-payload (+ r 3)) jolt-nil)))
                  (cseq-publish-tail! pc (cseq-realized (mk-payload (+ r 2)) t2)))
                ;; Compete on cvec (not t) plain tail-set path
                (let ((vt (seq-more vs)))
                  (unless (and (cseq? vt) (payload-valid? (seq-first vt) (+ r 4)))
                    (error 'cseq-round "w1 bad cvec plain-tail-set" r vt))))
              (jolt-with-mutex mu
                (let wait ()
                  (unless (>= (atomic-box-ref done-cnt) 1)
                    (condition-wait cv mu)
                    (wait))))
              (loop (+ r 1))))
          (jolt-with-mutex mu
            (set! finish? #t)
            (atomic-box-set! round-id -2)
            (condition-broadcast cv))
          (join-thread w2))
        (check "fresh-cell 2-thread race executed thunk once per round (CAS + plain-tail-set)"
               (atomic-box-ref cas-calls) rounds))

      ;; Exception rollback check: failing tail must release claim so another caller observes recovery too
      (let* ((toggle (make-atomic-box #t))
             (s (cseq-lazy 0
                  (lambda ()
                    (if (sa-box-cas! toggle #t #f)
                        (error 'cseq-tail "transient tail fault")
                        (cseq-realized 1 jolt-nil))))))
        (check-raise-message "cseq first tail fault raises" (lambda () (seq-more s)) "transient tail fault")
        (check "cseq rolled back claim retries cleanly" (seq-first (seq-more s)) 1)))

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
           (validate-pic
             (lambda (v)
               (unless (and (vector? v) (= (vector-length v) (+ top 1))
                            (fixnum? (vector-ref v top)) (>= (vector-ref v top) -1))
                 (error 'pic-race "invalid cache header" v))
               (let loop ((slot 0) (seen '()) (empty? #f))
                 (when (< slot top)
                   (let ((d (vector-ref v slot))
                         (impl (vector-ref v (+ slot 1))))
                     (if d
                         (let ((idx ((@ (srfi srfi-1) list-index) (lambda (known) (eq? known d)) descs)))
                           (unless (and idx (not (memq d seen)) (not empty?)
                                        (>= (vector-ref v top) 0) (procedure? impl)
                                        (let ((answer (impl (vector-ref recs idx))))
                                          (and (exact-integer? answer) (<= 0 answer 4005)
                                               (= (modulo answer 100) idx))))
                             (error 'pic-race "invalid descriptor/method pair" slot v))
                           (loop (+ slot 2) (cons d seen) #f))
                         (begin
                           (when (or impl (and (= slot 0) (not (= (vector-ref v top) -1))))
                             (error 'pic-race "invalid empty pair" slot v))
                           (loop (+ slot 2) seen #t))))))))
           (call-pic
             (lambda (r)
               (let* ((_v (jolt-pic-site-ref _picv$))
                      (_d (jrec-pic-desc r))
                      (ep (jolt-proto-epoch-ref)))
                 (validate-pic _v)
                 (let ((impl
                         (if (and _d (fx=? (vector-ref _v top) ep))
                             (or (and (eq? (vector-ref _v 0) _d) (vector-ref _v 1))
                                 (and (eq? (vector-ref _v 2) _d) (vector-ref _v 3))
                                 (and (eq? (vector-ref _v 4) _d) (vector-ref _v 5))
                                 (and (eq? (vector-ref _v 6) _d) (vector-ref _v 7))
                                 (let ((_nv (jolt-pic-add _v _d proto-name method-name r)))
                                   (if (procedure? _nv)
                                       _nv
                                       (begin (validate-pic _nv)
                                              (jolt-pic-site-set! _picv$ _nv)
                                              (vector-ref _nv 1)))))
                             (if _d
                                 (let ((_nv (jolt-pic-add _v _d proto-name method-name r)))
                                   (if (procedure? _nv)
                                       _nv
                                       (begin (validate-pic _nv)
                                              (jolt-pic-site-set! _picv$ _nv)
                                              (vector-ref _nv 1))))
                                 (protocol-resolve proto-name method-name r)))))
                   (impl r)))))
           (completed-gens (list->vector (map (lambda (_) (make-atomic-box 0)) tags)))
           (check-registrations
             (lambda ()
               (for-each
                 (lambda (r)
                   (let ((got (call-pic r))
                         (expected ((protocol-resolve proto-name method-name r) r)))
                     (unless (= got expected)
                       (error 'pic-race "PIC disagrees with uncached walk" r got expected))))
                 (vector->list recs))))
           (started (make-atomic-box #f))
           (stop (make-atomic-box #f)))
      (let ((writer
              (fork-thread
                (lambda ()
                  (let wait () (unless (atomic-box-ref started) (yield) (wait)))
                  (let loop ((gen 1))
                    (when (<= gen 40)
                      (for-each
                        (lambda (tag i)
                          (register-protocol-method tag proto-name method-name
                            (lambda (_self) (+ (* gen 100) i)))
                          (atomic-box-set! (vector-ref completed-gens i) gen)
                          (check-registrations))
                        tags '(0 1 2 3 4 5))
                      (loop (+ gen 1))))
                  (atomic-box-set! stop #t)))))
        (run-parallel! 6
          (lambda (tid)
            (atomic-box-set! started #t)
            (let ((prev-gens (make-vector 6 0)))
              (let loop ((n 0))
                (unless (and (atomic-box-ref stop) (>= n 400))
                  (let* ((idx (modulo (+ n tid) 6))
                         (r (vector-ref recs idx))
                         (min-gen (atomic-box-ref (vector-ref completed-gens idx)))
                         (got (call-pic r))
                         (got-gen (quotient got 100))
                         (base (modulo got 100))
                         (prev-gen (vector-ref prev-gens idx)))
                    (unless (= base idx)
                      (error 'pic-race "wrong type dispatch" idx got))
                    (when (< got-gen min-gen)
                      (error 'pic-race "served pre-update stale generation" idx got-gen min-gen))
                    (when (< got-gen prev-gen)
                      (error 'pic-race "generation regressed for tag" idx got-gen prev-gen))
                    (vector-set! prev-gens idx got-gen))
                  (loop (+ n 1)))))))
        (join-thread writer))
      ;; Final agreement against uncached protocol-resolve & final generation 40
      (for-each
        (lambda (r)
          (let ((got (call-pic r)))
            (unless (and (= (quotient got 100) 40)
                         (= got ((protocol-resolve proto-name method-name r) r)))
              (error 'pic-race "post-update PIC disagrees with uncached resolve or gen 40" got))))
        (vector->list recs))
      (gc-pass! "PIC hot-site generation monotonicity & uncached equivalence"))

    ;; 7d: race instance-site replacement against hierarchy and arm updates.
    (let* ((site (jolt-instance-site-make))
           (t-map (jolt-symbol #f "clojure.lang.IPersistentMap"))
           (samples (list (jolt-hash-map (keyword #f "a") 1)
                          (jolt-vector 1 2) "str" 42
                          (jolt-hash-set (keyword #f "k"))))
           (started (make-atomic-box #f))
           (stop (make-atomic-box #f)))
      (define (validate-state site token valid-verdict?)
        (let ((state (sa-site-cell-ref site)))
          (when state
            (unless (and (vector? state) (= (vector-length state) 6)
                         (eq? (vector-ref state 0) token)
                         (eq? (vector-ref state 1) token)
                         (eq? (vector-ref state 2) (symbol-t-name token))
                         (fixnum? (vector-ref state 5))
                         (>= (vector-ref state 5) 0)
                         (valid-verdict? (vector-ref state 3) (vector-ref state 4)))
              (error 'instance-site-race "invalid site state" state)))))
      (define (check-map v)
        (let ((ans (jolt-instance-site site t-map v))
              (expected (instance-check-walk t-map v)))
          (unless (eq? ans expected)
            (error 'instance-site-race "site disagrees with plain walk" v ans expected)))
        (validate-state site t-map
          (lambda (kind ans)
            (exists (lambda (sample)
                   (and (eq? kind (instance-kind-key sample))
                        (eq? ans (instance-check-walk t-map sample))))
                 samples))))
      (let ((writer
              (fork-thread
                (lambda ()
                  (let wait () (unless (atomic-box-ref started) (yield) (wait)))
                  (do ((k 0 (+ k 1))) ((= k 30))
                    (jch-register-leaf! (format #f "guile.inst.Leaf~a" k)
                                        '("java.lang.Object"))
                    (for-each check-map samples)
                    (register-class-arm! (lambda (_x) #f) (lambda (_x) #f))
                    (for-each check-map samples))
                  (atomic-box-set! stop #t)))))
        (run-parallel! 6
          (lambda (tid)
            (atomic-box-set! started #t)
            (let loop ((n 0))
              (unless (and (atomic-box-ref stop) (>= n 300))
                (check-map (list-ref samples (modulo (+ n tid) (length samples))))
                (loop (+ n 1))))))
        (join-thread writer))
      ;; The dynamic arm changes a cached verdict for the same kind and token.
      (let* ((arm-site (jolt-instance-site-make))
             (tok-arm (jolt-symbol #f "guile.check.DynamicArm"))
             (val-arm 12345)
             (kind (instance-kind-key val-arm))
             (reading? (make-atomic-box #f))
             (flipped? (make-atomic-box #f)))
        (define (read-arm)
          (let ((ans (jolt-instance-site arm-site tok-arm val-arm)))
            (validate-state arm-site tok-arm
              (lambda (k verdict) (and (eq? k kind) (boolean? verdict))))
            ans))
        (check "pre-arm jolt-instance-site is #f" (read-arm) #f)
        (let ((arm-writer
                (fork-thread
                  (lambda ()
                    (let wait () (unless (atomic-box-ref reading?) (yield) (wait)))
                    (register-instance-check-arm!
                      (lambda (ts v)
                        (if (and (string=? (symbol-t-name ts) "guile.check.DynamicArm")
                                 (eqv? v val-arm))
                            #t
                            'pass)))
                    (atomic-box-set! flipped? #t)))))
          (run-parallel! 6
            (lambda (_tid)
              (atomic-box-set! reading? #t)
              (let loop ((n 0))
                (let* ((post? (atomic-box-ref flipped?))
                       (ans (read-arm)))
                  (when (and post? (not (eq? ans (instance-check-walk tok-arm val-arm))))
                    (error 'instance-arm-race "stale verdict after registration" ans))
                  (unless (and post? (>= n 200))
                    (loop (+ n 1)))))))
          (join-thread arm-writer))
        (check "post-arm site agrees with the plain walk"
               (list (read-arm) (instance-check-walk tok-arm val-arm)) '(#t #t)))
      (gc-pass! "instance site race, complete states and uncached verdicts after each registration"))

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

    ;; 7f: real jolt-defmulti-setup constructor, non-exact dispatch, & callback-keyed re-entrancy
    (let ((sym-fresh (jolt-symbol "user" "fresh-contract-mm")))
      (let ((fresh (jolt-defmulti-setup sym-fresh (lambda (x) x))))
        (jolt-defmethod-setup sym-fresh (keyword #f "default") (lambda (x) (list 'fresh-def x)) "user")
        (check "real jolt-defmulti-setup dispatches non-exact value cleanly"
               (multifn-dispatch1 fresh 'unregistered-key)
               '(fresh-def unregistered-key))))
    (let* ((sym-race (jolt-symbol "user" "race-mm"))
           (sym-inner (jolt-symbol "user" "inner-mm"))
           (mf (jolt-defmulti-setup sym-race (lambda (x) x)))
           (mf-inner (jolt-defmulti-setup sym-inner (lambda (x) x))))
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
