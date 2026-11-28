#!no-fold-case
;; host/guile/scheme-adapter-runtime.ss — Guile 3.0.11 adapter implementing CONTRACT.txt
;; and host shared-table/site/epoch macros.

;; ---- Platform C11 helper library (fences + 64-bit signed stat mtime) -------
(define %jolt-platform-ext
  (let ((sys (utsname:sysname (uname))))
    (cond
      ((string=? sys "Darwin") ".dylib")
      (else ".so"))))

(define (%find-platform-lib)
  (let* ((env-path (getenv "JOLT_GUILE_PLATFORM_LIB"))
         (here (let ((cf (current-filename))) (and cf (dirname cf))))
         (candidates
          (append
            (if env-path (list env-path) '())
            (if here
                (list (string-append here "/../../build/guile/libjolt-guile-platform" %jolt-platform-ext))
                '())
            (list (string-append "build/guile/libjolt-guile-platform" %jolt-platform-ext)))))
    (let loop ((cs candidates))
      (cond
        ((null? cs)
         (error 'jolt-platform-lib
                "jolt.guile: cannot locate build/guile/libjolt-guile-platform"
                candidates))
        ((file-exists? (car cs)) (car cs))
        (else (loop (cdr cs)))))))

(define %jolt-platform-lib (load-foreign-library (%find-platform-lib)))

(define %jolt-fence-release
  (foreign-library-function %jolt-platform-lib "jolt_guile_fence_release"
                            #:return-type ffi:void
                            #:arg-types '()))

(define %jolt-fence-acquire
  (foreign-library-function %jolt-platform-lib "jolt_guile_fence_acquire"
                            #:return-type ffi:void
                            #:arg-types '()))

(define %jolt-stat-mtime
  (foreign-library-function %jolt-platform-lib "jolt_guile_stat_mtime"
                            #:return-type ffi:int
                            #:arg-types (list '* '* '*)
                            #:return-errno? #t))

(define (memory-order-release) (%jolt-fence-release))
(define (memory-order-acquire) (%jolt-fence-acquire))

;; ---- threads tier ----------------------------------------------------------
(define %jolt-thread-id-mu (make-mutex 'allow-external-unlock))
(define %jolt-thread-id-tbl (make-weak-key-hash-table))
(define %jolt-thread-next-id (make-atomic-box 1))

(define (%ensure-thread-id t)
  (or (dynamic-wind
        (lambda () (lock-mutex %jolt-thread-id-mu))
        (lambda () (hashq-ref %jolt-thread-id-tbl t #f))
        (lambda () (unlock-mutex %jolt-thread-id-mu)))
      (let next-id ()
        (let* ((id (atomic-box-ref %jolt-thread-next-id))
               (nx (+ id 1)))
          (if (eq? (atomic-box-compare-and-swap! %jolt-thread-next-id id nx) id)
              (dynamic-wind
                (lambda () (lock-mutex %jolt-thread-id-mu))
                (lambda ()
                  (or (hashq-ref %jolt-thread-id-tbl t #f)
                      (begin (hashq-set! %jolt-thread-id-tbl t id) id)))
                (lambda () (unlock-mutex %jolt-thread-id-mu)))
              (next-id))))))

(define (get-thread-id)
  (%ensure-thread-id (current-thread)))

(define (sa-thread-id-of t)
  (and (thread? t)
       (not (thread-exited? t))
       (%ensure-thread-id t)))

;; Initialize thread-id eagerly when spawning via fork-thread too so
;; sa-thread-id-of returns a stable integer while live, and notify runtime of MT.
(define %jolt-on-fork-thread (lambda () #f))
(define (fork-thread thunk)
  (%jolt-on-fork-thread)
  (call-with-new-thread
    (lambda ()
      (get-thread-id)
      (thunk))))

(define %guile-make-mutex make-mutex)
(define make-mutex
  (case-lambda
    (() (jolt-count-mutex!) (%guile-make-mutex 'allow-external-unlock))
    ((_name) (jolt-count-mutex!) (%guile-make-mutex 'allow-external-unlock))))

(define mutex-acquire
  (case-lambda
    ((mu) (lock-mutex mu) #t)
    ((mu block?) (if block? (begin (lock-mutex mu) #t) (try-mutex mu)))))

(define (mutex-release mu)
  (unlock-mutex mu))

(define-syntax with-mutex
  (syntax-rules ()
    ((_ mu b0 b ...)
     (let ((m mu))
       (dynamic-wind
         (lambda () (mutex-acquire m))
         (lambda () b0 b ...)
         (lambda () (mutex-release m)))))))

(define make-condition make-condition-variable)

(define (%deadline-from-timeout timeout)
  (cond
    ((srfi19:time? timeout)
     (let* ((now (gettimeofday))
            (s (+ (car now) (srfi19:time-second timeout)))
            (us (+ (cdr now) (quotient (srfi19:time-nanosecond timeout) 1000))))
       (let ((carry (quotient us 1000000)))
         (cons (+ s carry) (remainder us 1000000)))))
    ((real? timeout)
     (let* ((now (gettimeofday))
            (total-us (inexact->exact (round (* timeout 1000000))))
            (us (+ (cdr now) total-us)))
       (let ((carry (floor-quotient us 1000000)))
         (cons (+ (car now) carry) (floor-remainder us 1000000)))))
    (else (error 'condition-wait "invalid timeout" timeout))))

(define condition-wait
  (case-lambda
    ((cv mu) (wait-condition-variable cv mu))
    ((cv mu timeout)
     (if timeout
         (wait-condition-variable cv mu (%deadline-from-timeout timeout))
         (wait-condition-variable cv mu)))))

(define condition-signal signal-condition-variable)
(define condition-broadcast broadcast-condition-variable)

(define make-thread-parameter
  (case-lambda
    ((init) (make-parameter init))
    ((init conv) (make-parameter init conv))))

;; ---- system & capability-system tiers --------------------------------------
(define %guile-system system)
(define (system cmd)
  (let ((st (%guile-system cmd)))
    (or (status:exit-val st) st)))

(define %guile-sleep sleep)
(define (sleep dur)
  (cond
    ((srfi19:time? dur)
     (let ((s (srfi19:time-second dur))
           (ns (srfi19:time-nanosecond dur)))
       (when (or (> s 0) (> ns 0))
         (let ((us (+ (* (max 0 s) 1000000) (quotient (max 0 ns) 1000))))
           (when (> us 0) (usleep us))))))
    ((real? dur)
     (when (> dur 0)
       (if (integer? dur)
           (%guile-sleep dur)
           (let ((us (inexact->exact (round (* dur 1000000)))))
             (when (> us 0) (usleep us))))))
    (else (error 'sleep "expected SRFI-19 time or real seconds" dur))))

(define (make-time type nanosecond second)
  (srfi19:make-time type nanosecond second))

(define current-time
  (case-lambda
    (() (srfi19:current-time))
    ((type) (srfi19:current-time type))))

;; (sa-run-process cmd transcoder) -> (values stdin-out stdout-in stderr-in pid)
(define (sa-run-process cmd transcoder)
  (let* ((in-pipe (pipe))
         (out-pipe (pipe))
         (err-pipe (pipe))
         (in-r (car in-pipe)) (in-w (cdr in-pipe))
         (out-r (car out-pipe)) (out-w (cdr out-pipe))
         (err-r (car err-pipe)) (err-w (cdr err-pipe))
         (pid #f))
    (catch #t
      (lambda ()
        (set! pid
          (spawn "/bin/sh" (list "/bin/sh" "-c" cmd)
                 #:input in-r #:output out-w #:error err-w
                 #:search-path? #f)))
      (lambda args
        (for-each (lambda (p) (catch #t (lambda () (close-port p)) (lambda _ #f)))
                  (list in-r in-w out-r out-w err-r err-w))
        (apply throw args)))
    (close-port in-r)
    (close-port out-w)
    (close-port err-w)
    (unless transcoder
      (set-port-encoding! in-w "ISO-8859-1")
      (set-port-encoding! out-r "ISO-8859-1")
      (set-port-encoding! err-r "ISO-8859-1"))
    (values in-w out-r err-r pid)))

(define (sa-environment-pairs)
  (let loop ((es (environ)) (acc '()))
    (if (null? es)
        (reverse acc)
        (let* ((entry (car es))
               (len (string-length entry))
               (eq-pos
                (let scan ((i 0))
                  (cond ((fx=? i len) #f)
                        ((char=? (string-ref entry i) #\=) i)
                        (else (scan (fx+ i 1)))))))
          (loop (cdr es)
                (if (and eq-pos (fx>? eq-pos 0))
                    (cons (cons (substring entry 0 eq-pos)
                                (substring entry (fx+ eq-pos 1) len))
                          acc)
                    acc))))))

(define (sa-os-release)
  (guard (e (#t #f))
    (utsname:release (uname))))

(define (%guile-monotonic-ns)
  (let ((t (srfi19:current-time 'time-monotonic)))
    (+ (* (srfi19:time-second t) 1000000000)
       (srfi19:time-nanosecond t))))

(define %jolt-start-mono-ns (%guile-monotonic-ns))

(define (sa-real-time-ms)
  (quotient (- (%guile-monotonic-ns) %jolt-start-mono-ns) 1000000))

(define (sa-epoch-ms)
  (let ((t (srfi19:current-time 'time-utc)))
    (+ (* (srfi19:time-second t) 1000)
       (quotient (srfi19:time-nanosecond t) 1000000))))

(define (sa-file-mtime-ms path)
  (unless (string? path)
    (error 'sa-file-mtime-ms "expected path string" path))
  (let* ((path-bv (string->utf8 (string-append path "\x0;")))
         (sec-bv (make-bytevector 8 0))
         (nsec-bv (make-bytevector 8 0)))
    (call-with-values
      (lambda ()
        (%jolt-stat-mtime (ffi:bytevector->pointer path-bv)
                          (ffi:bytevector->pointer sec-bv)
                          (ffi:bytevector->pointer nsec-bv)))
      (lambda (rc err)
        (let ((sec (bytevector-s64-native-ref sec-bv 0))
              (nsec (bytevector-s64-native-ref nsec-bv 0))
              ;; Reference path-bv after foreign call so Boehm GC keeps it live.
              (_keep (bytevector-length path-bv)))
          (if (< rc 0)
              (error 'sa-file-mtime-ms
                     (string-append "jolt.guile: stat failed: " (strerror err))
                     path err)
              (+ (* sec 1000) (floor-quotient nsec 1000000))))))))

(define %jolt-gc-trip-bytes (make-atomic-box 0))
(define %jolt-after-collect-running? (make-fluid #f))
(define %jolt-max-mem-bytes (make-atomic-box 0))

(define (sa-total-memory-bytes)
  (let ((s (gc-stats)))
    (or (assq-ref s 'heap-size) 0)))

(define (sa-bytes-allocated)
  (let* ((s (gc-stats))
         (total (or (assq-ref s 'heap-size) 0))
         (free (or (assq-ref s 'heap-free-size) 0)))
    (max 0 (- total free))))

(define (sa-max-memory-bytes)
  (let ((cur (sa-total-memory-bytes)))
    (let loop ()
      (let ((prev (atomic-box-ref %jolt-max-mem-bytes)))
        (if (>= prev cur)
            prev
            (if (eq? (atomic-box-compare-and-swap! %jolt-max-mem-bytes prev cur) prev)
                cur
                (loop)))))))

(define (sa-reset-max-memory-bytes!)
  (atomic-box-set! %jolt-max-mem-bytes (sa-total-memory-bytes))
  (void))

(define (sa-gc-collect) (gc))
(define (sa-gc-max-generation) 0)
(define (sa-gc-trip-bytes! n)
  (atomic-box-set! %jolt-gc-trip-bytes n)
  (void))
(define (sa-gc-trip-bytes) (atomic-box-ref %jolt-gc-trip-bytes))
(define (sa-gc-reserve-ratio! _r) (void))
(define (sa-gc-tight! _limit) (void))
(define (sa-make-large-bytevector n) (make-bytevector n))
(define (sa-pin-for-owner! _owner _obj) (void))
(define (sa-unpin-for-owner! _owner) (void))

(define %jolt-after-gc-proc #f)
(define (sa-gc-install-after-collect! maintain observe)
  (when %jolt-after-gc-proc
    (remove-hook! after-gc-hook %jolt-after-gc-proc)
    (set! %jolt-after-gc-proc #f))
  (let ((last-end (%guile-monotonic-ns))
        (mu (%guile-make-mutex))
        (collect-full! (case-lambda (() (gc)) ((_room) (gc)))))
    (let ((handler
            (lambda ()
              (unless (fluid-ref %jolt-after-collect-running?)
                (with-fluids ((%jolt-after-collect-running? #t))
                  (when (try-mutex mu)
                    (dynamic-wind
                      void
                      (lambda ()
                        (let ((t0 (%guile-monotonic-ns)))
                          (maintain collect-full!)
                          (let ((t1 (%guile-monotonic-ns)))
                            (observe (- t1 t0) (- t1 last-end))
                            (set! last-end t1))))
                      (lambda () (unlock-mutex mu)))))))))
      (set! %jolt-after-gc-proc handler)
      (add-hook! after-gc-hook handler))
    #t))

(define (sa-gc-install-stall-watch! _seconds _on-stall) #f)
(define (sa-gc-install-after-rendezvous! _thunk) #f)
(define (sa-current-stack-bytes) 0)

(define (sa-make-output-port name put! put-some! flush! clear! close!)
  (make-soft-port
    #:id (if (string? name) (string->symbol name) name)
    #:write-string
    (lambda (s)
      (cond
        (put-some! (put-some! s 0 (string-length s)))
        (put!
         (let ((n (string-length s)))
           (let loop ((i 0))
             (when (fx<? i n)
               (put! (string-ref s i))
               (loop (fx+ i 1)))))))
      (when flush! (flush!)))
    #:close
    (lambda ()
      (when flush! (flush!))
      (when clear! (clear!))
      (when close! (close!)))))

(define (sa-host-tag)
  (string-append (utsname:machine (uname)) "-" (utsname:sysname (uname))))

(define (sa-os-family)
  (let ((sys (utsname:sysname (uname))))
    (cond
      ((string=? sys "Darwin") 'macos)
      ((string=? sys "Linux") 'linux)
      ((string-prefix? "MINGW" sys) 'windows)
      ((string-prefix? "CYGWIN" sys) 'windows)
      (else #f))))

(define (sa-arch)
  (let ((m (utsname:machine (uname))))
    (cond
      ((or (string=? m "arm64") (string=? m "aarch64")) 'arm64)
      ((or (string=? m "x86_64") (string=? m "amd64")) 'x86_64)
      (else (string->symbol m)))))

(define (sa-endian) (native-endianness))

(define (sa-stats)
  (let* ((s (gc-stats))
         (tu internal-time-units-per-second)
         (cpu-ns (inexact->exact (floor (* (/ (get-internal-run-time) tu) 1000000000))))
         (real-ns (- (%guile-monotonic-ns) %jolt-start-mono-ns))
         (gc-cnt (or (assq-ref s 'gc-times) 0))
         (gc-ns (inexact->exact (floor (* (/ (or (assq-ref s 'gc-time-taken) 0) tu) 1000000000))))
         (alloc (or (assq-ref s 'heap-total-allocated) 0)))
    (vector cpu-ns real-ns gc-cnt gc-ns gc-ns alloc alloc)))

;; ---- capability-introspect -------------------------------------------------
(define sa-introspect-enabled? (make-parameter #f))
(define (sa-continuation-frames _k) '())
(define (sa-procedure-info _x) #f)
(define (sa-procedure-code-name _p) #f)

;; ---- capability-ffi (paired lock/unlock no-ops + honest refusals) ----------
(define (sa-lock-object _x) (void))
(define (sa-unlock-object _x) (void))

(define (sa-foreign-alloc _n)
  (error 'sa-foreign-alloc "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-foreign-free _p)
  (error 'sa-foreign-free "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-foreign-ref _type _addr _off)
  (error 'sa-foreign-ref "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-foreign-set! _type _addr _off _v)
  (error 'sa-foreign-set! "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-foreign-bytes-ref! _addr _bv _n)
  (error 'sa-foreign-bytes-ref! "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-foreign-bytes-set! _addr _bv _n)
  (error 'sa-foreign-bytes-set! "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-foreign-zero! _addr _n)
  (error 'sa-foreign-zero! "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-foreign-sizeof _type)
  (error 'sa-foreign-sizeof "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-load-shared-object _name)
  (error 'sa-load-shared-object "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-foreign-entry? _name) #f)
(define (sa-foreign-entry-address _name)
  (error 'sa-foreign-entry-address "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-foreign-callable-entry-point _co)
  (error 'sa-foreign-callable-entry-point "jolt.guile: user FFI is unsupported on the guile target"))
(define (sa-foreign-procedure-runtime _name _args _res _blocking?)
  (error 'sa-foreign-procedure-runtime "jolt.guile: user FFI is unsupported on the guile target"))

(define-syntax sa-foreign-procedure
  (syntax-rules ()
    ((_ name args res)
     (lambda _
       (error 'sa-foreign-procedure "jolt.guile: user FFI is unsupported on the guile target" name)))))

(define-syntax sa-foreign-procedure-native-error
  (syntax-rules ()
    ((_ name args res)
     (lambda _
       (error 'sa-foreign-procedure-native-error
              "jolt.guile: user FFI is unsupported on the guile target" name)))))

(define-syntax sa-foreign-procedure-blocking
  (syntax-rules ()
    ((_ name args res)
     (lambda _
       (error 'sa-foreign-procedure-blocking
              "jolt.guile: user FFI is unsupported on the guile target" name)))))

(define-syntax sa-foreign-callable
  (syntax-rules ()
    ((_ proc args res)
     (error 'sa-foreign-callable "jolt.guile: user FFI is unsupported on the guile target"))))

(define-syntax sa-foreign-callable-collect-safe
  (syntax-rules ()
    ((_ proc args res)
     (error 'sa-foreign-callable-collect-safe
            "jolt.guile: user FFI is unsupported on the guile target"))))

;; ---- capability-continuations (one-shot escape via prompt) -----------------
(define (sa-call-with-escape-continuation proc)
  (let ((tag (make-prompt-tag 'sa-escape))
        (spent #f))
    (dynamic-wind
      (lambda ()
        (when spent
          (error 'sa-call-with-escape-continuation
                 "jolt.guile: cannot re-enter spent escape continuation")))
      (lambda ()
        (call-with-prompt tag
          (lambda ()
            (proc (lambda vals
                    (when spent
                      (error 'sa-call-with-escape-continuation
                             "jolt.guile: escape continuation has expired"))
                    (apply abort-to-prompt tag vals))))
          (lambda (_k . vals)
            (apply values vals))))
      (lambda ()
        (set! spent #t)))))

;; ---- capability-native-compile / capability-image / profile / sample -------
(define (sa-baked-global sym)
  (let ((var (module-variable %jolt-boot-module sym)))
    (and var (variable-bound? var) (variable-ref var))))

(define (sa-compile-file src _so _profile)
  (error 'sa-compile-file
         "jolt.guile: native AOT compilation is unsupported on the guile target" src))

(define (sa-make-boot-file out _base-boots)
  (error 'sa-make-boot-file
         "jolt.guile: boot-file generation is unsupported on the guile target" out))

(define (sa-fasl-write _obj _port . _rest)
  (error 'sa-fasl-write
         "jolt.guile: fasl serialization is unsupported on the guile target"))

(define (sa-fasl-read _port . _rest)
  (error 'sa-fasl-read
         "jolt.guile: fasl serialization is unsupported on the guile target"))

(define (sa-block-profile-dump! _path _tag)
  (error 'sa-block-profile-dump!
         "jolt.guile: block profiling is unsupported on the guile target"))
(define (sa-block-profile-tag _path)
  (error 'sa-block-profile-tag
         "jolt.guile: block profiling is unsupported on the guile target"))
(define (sa-block-profile-load-unit! _paths _src) #f)

(define (sa-profile-instrument! on?) (not on?))
(define (sa-profile-instrumenting?) #f)
(define (sa-profile-compile thunk) (thunk))
(define (sa-profile-counts) '())
(define (sa-profile-release!) '())
(define (sa-profile-clear!) (void))

(define (sa-stack-walk _k _cap _proc) #f)
(define (sa-frame-source-pair _frame) #f)
(define (sa-code-name _code) #f)
(define (sa-thread-cpu-nanos) 0)

;; ---- capability-unchecked (lowered to checked Guile primitives) ------------
(define-syntax sa-ufx+ (syntax-rules () ((_ a b) (fx+ a b))))
(define-syntax sa-ufx- (syntax-rules () ((_ a b) (fx- a b))))
(define-syntax sa-ufx<? (syntax-rules () ((_ a b) (fx<? a b))))
(define-syntax sa-ufx>=? (syntax-rules () ((_ a b) (fx>=? a b))))
(define-syntax sa-ufx=? (syntax-rules () ((_ a b) (fx=? a b))))
(define-syntax sa-uvector-ref (syntax-rules () ((_ v i) (vector-ref v i))))
(define-syntax sa-uvector-set! (syntax-rules () ((_ v i x) (vector-set! v i x))))
(define-syntax sa-ustring-ref (syntax-rules () ((_ s i) (string-ref s i))))
(define-syntax sa-uflvector-ref (syntax-rules () ((_ v i) (flvector-ref v i))))
(define-syntax sa-uflvector-set! (syntax-rules () ((_ v i x) (flvector-set! v i x))))
(define-syntax sa-ubytevector-ieee-single-native-ref
  (syntax-rules () ((_ bv at) (bytevector-ieee-single-native-ref bv at))))
(define-syntax sa-ubytevector-ieee-single-native-set!
  (syntax-rules () ((_ bv at x) (bytevector-ieee-single-native-set! bv at x))))
(define-syntax sa-ubytevector-ieee-double-native-ref
  (syntax-rules () ((_ bv at) (bytevector-ieee-double-native-ref bv at))))
(define-syntax sa-ubytevector-ieee-double-native-set!
  (syntax-rules () ((_ bv at x) (bytevector-ieee-double-native-set! bv at x))))

(define (sa-vector-copy-range! to at from start end)
  (let ((count (fx- end start)))
    (if (and (eq? to from) (fx>? at start))
        (let loop ((k (fx- count 1)))
          (when (fx>=? k 0)
            (vector-set! to (fx+ at k) (vector-ref from (fx+ start k)))
            (loop (fx- k 1))))
        (let loop ((k 0))
          (when (fx<? k count)
            (vector-set! to (fx+ at k) (vector-ref from (fx+ start k)))
            (loop (fx+ k 1)))))))

(define (sa-string-copy-range! to at from start end)
  (let ((count (fx- end start)))
    (if (and (eq? to from) (fx>? at start))
        (let loop ((k (fx- count 1)))
          (when (fx>=? k 0)
            (string-set! to (fx+ at k) (string-ref from (fx+ start k)))
            (loop (fx- k 1))))
        (let loop ((k 0))
          (when (fx<? k count)
            (string-set! to (fx+ at k) (string-ref from (fx+ start k)))
            (loop (fx+ k 1)))))))

(define (sa-bytevector-copy-range! to at from start end)
  (r6bv:bytevector-copy! from start to at (fx- end start)))

(define (sa-vector-copy v) (subvector v 0 (vector-length v)))
(define (sa-subvector v start end) (subvector v start end))
(define sa-vector-append vector-append)

;; ---- misc & IEEE-754 & atomic record CAS -----------------------------------
(define (sort pred lst) (r6sort:list-sort pred lst))

(define (hashtable-values ht)
  (call-with-values
    (lambda () (hashtable-entries ht))
    (lambda (_ks vs) vs)))

(define (hashtable-cells ht)
  (call-with-values
    (lambda () (hashtable-entries ht))
    (lambda (ks vs) (vector-map cons ks vs))))

(define (scheme-version)
  (string-append "Guile " (version)))

(define vector-copy
  (case-lambda
    ((v) (sa-vector-copy v))
    ((v start) (sa-subvector v start (vector-length v)))
    ((v start end) (sa-subvector v start end))))

(define (sa-flonum->bits x)
  (let ((bv (make-bytevector 8)))
    (bytevector-ieee-double-set! bv 0 (exact->inexact x) (endianness little))
    (bytevector-u64-ref bv 0 (endianness little))))

(define (sa-bits->flonum b)
  (let ((bv (make-bytevector 8)))
    (bytevector-u64-set! bv 0 b (endianness little))
    (bytevector-ieee-double-ref bv 0 (endianness little))))

(define (sa-flonum-hi32 x)
  (let ((bv (make-bytevector 8)))
    (bytevector-ieee-double-set! bv 0 (exact->inexact x) (endianness little))
    (bytevector-u32-ref bv 4 (endianness little))))

(define (sa-hi32->flonum h)
  (let ((bv (make-bytevector 8 0)))
    (bytevector-u32-set! bv 4 h (endianness little))
    (bytevector-ieee-double-ref bv 0 (endianness little))))

(define (sa-record-cas! r i old new)
  (let* ((rtd (record-rtd r))
         (meta (%rtd-meta-ref rtd)))
    (unless (and meta (vector-ref meta 6))
      (error 'sa-record-cas! "record type does not support atomic field CAS" rtd i))
    (let* ((raw-accs (vector-ref meta 4))
           (raw-box ((vector-ref raw-accs i) r)))
      (unless (atomic-box? raw-box)
        (error 'sa-record-cas! "record slot is immutable" rtd i))
      (eq? (atomic-box-compare-and-swap! raw-box old new) old))))

;; ---- coroutines & terminal (honest refusals in 3a) -------------------------
(define (sa-fiber-spawn _thunk)
  (error 'sa-fiber-spawn "jolt.guile: coroutines are unsupported on the guile target"))
(define (sa-fiber-yield)
  (error 'sa-fiber-yield "jolt.guile: coroutines are unsupported on the guile target"))
(define (sa-fiber-resume _f _val)
  (error 'sa-fiber-resume "jolt.guile: coroutines are unsupported on the guile target"))
(define (sa-fiber-run-all)
  (error 'sa-fiber-run-all "jolt.guile: coroutines are unsupported on the guile target"))

(define (sa-term-open) #f)
(define (%term-unsupported who . _args)
  (error who "jolt.guile: terminal control is unsupported on the guile target"))
(define (sa-term-raw!) (%term-unsupported 'sa-term-raw!))
(define (sa-term-cooked!) (%term-unsupported 'sa-term-cooked!))
(define (sa-term-read-char _block?) (%term-unsupported 'sa-term-read-char))
(define (sa-term-size) (%term-unsupported 'sa-term-size))
(define (sa-term-write-char _c) (%term-unsupported 'sa-term-write-char))
(define (sa-term-char-width _c) (%term-unsupported 'sa-term-char-width))
(define (sa-term-flush) (%term-unsupported 'sa-term-flush))
(define (sa-term-move! _dir _n) (%term-unsupported 'sa-term-move!))
(define (sa-term-clear! _what) (%term-unsupported 'sa-term-clear!))
(define (sa-term-cr!) (%term-unsupported 'sa-term-cr!))
(define (sa-term-lf!) (%term-unsupported 'sa-term-lf!))
(define (sa-term-bell!) (%term-unsupported 'sa-term-bell!))
(define (sa-term-pause!) (%term-unsupported 'sa-term-pause!))
(define (sa-term-color! _id _bg?) (%term-unsupported 'sa-term-color!))

;; ---- Guile-safe shared-table, site, epoch, published-var, and mm helpers ---
;; Never read a plain hashtable concurrently without its mutex; use atomic-box
;; cells for inline-cache sites, epochs, and published whole tables; keep
;; callback-keyed multimethod tables lock-free using immutable snapshots + CAS.
(define-syntax sa-shared-read
  (syntax-rules ()
    ((_ mu expr) (jolt-with-mutex mu expr))))

(define-syntax sa-shared-intern
  (syntax-rules ()
    ((_ mu hit-expr miss-expr)
     (jolt-with-mutex mu (or hit-expr miss-expr)))))

(define-syntax sa-seqlock-read
  (syntax-rules ()
    ((_ mu _gen-box expr)
     (jolt-with-mutex mu expr))))

(define-syntax sa-site-cell-make
  (syntax-rules ()
    ((_ init) (make-atomic-box init))))

(define-syntax sa-site-cell-ref
  (syntax-rules ()
    ((_ cell) (atomic-box-ref cell))))

(define-syntax sa-site-cell-set!
  (syntax-rules ()
    ((_ cell val) (atomic-box-set! cell val))))

(define-syntax sa-epoch-define
  (syntax-rules ()
    ((_ cell var init)
     (begin
       (define var init)
       (define cell (make-atomic-box init))))))

(define-syntax sa-epoch-ref
  (syntax-rules ()
    ((_ cell _var) (atomic-box-ref cell))))

(define-syntax sa-epoch-bump!
  (syntax-rules ()
    ((_ cell var)
     (let loop ()
       (let* ((cur (atomic-box-ref cell))
              (next (fx+ cur 1)))
         (if (eq? (atomic-box-compare-and-swap! cell cur next) cur)
             (set! var next)
             (loop)))))))

(define-syntax sa-pub-define
  (syntax-rules ()
    ((_ cell var init)
     (begin
       (define var init)
       (define cell (make-atomic-box init))))))

(define-syntax sa-pub-ref
  (syntax-rules ()
    ((_ cell _var) (atomic-box-ref cell))))

(define-syntax sa-pub-set!
  (syntax-rules ()
    ((_ cell var val)
     (begin
       (atomic-box-set! cell val)
       (set! var val)))))

(define (sa-mm-ht-copy src h e)
  (let ((dst (make-hashtable h e)))
    (call-with-values
      (lambda () (hashtable-entries src))
      (lambda (ks vs)
        (let ((n (vector-length ks)))
          (let loop ((i 0))
            (when (fx<? i n)
              (hashtable-set! dst (vector-ref ks i) (vector-ref vs i))
              (loop (fx+ i 1)))))))
    dst))

(define (sa-mm-table-make h e)
  (vector h e (make-atomic-box (make-hashtable h e))))

(define-syntax sa-mm-table-ref
  (syntax-rules ()
    ((_ tbl k d)
     (hashtable-ref (atomic-box-ref (vector-ref tbl 2)) k d))))

(define-syntax sa-mm-table-keys
  (syntax-rules ()
    ((_ _mu tbl)
     (hashtable-keys (atomic-box-ref (vector-ref tbl 2))))))

(define-syntax sa-mm-table-entries
  (syntax-rules ()
    ((_ _mu tbl)
     (hashtable-entries (atomic-box-ref (vector-ref tbl 2))))))

(define (sa-mm-swap! tbl update!)
  (let ((h (vector-ref tbl 0))
        (e (vector-ref tbl 1))
        (bx (vector-ref tbl 2)))
    (let loop ()
      (let* ((cur (atomic-box-ref bx))
             (next (sa-mm-ht-copy cur h e)))
        (update! next)
        (unless (eq? (atomic-box-compare-and-swap! bx cur next) cur)
          (loop))))))

(define-syntax sa-mm-table-put!
  (syntax-rules ()
    ((_ _mu tbl k v after ...)
     (begin
       (sa-mm-swap! tbl (lambda (ht) (hashtable-set! ht k v)))
       after ...))))

(define-syntax sa-mm-table-del!
  (syntax-rules ()
    ((_ _mu tbl k after ...)
     (begin
       (sa-mm-swap! tbl (lambda (ht) (hashtable-delete! ht k)))
       after ...))))

(define-syntax sa-mm-table-clear!
  (syntax-rules ()
    ((_ _mu tbl after ...)
     (begin
       (let ((t tbl))
         (atomic-box-set! (vector-ref t 2)
                          (make-hashtable (vector-ref t 0) (vector-ref t 1))))
       after ...))))

(define (sa-mm-prefer-insert! prefers a b h e)
  (let loop ()
    (let ((sub (hashtable-ref (atomic-box-ref (vector-ref prefers 2)) a #f)))
      (if sub
          (sa-mm-swap! sub (lambda (ht) (hashtable-set! ht b #t)))
          (let ((fresh (sa-mm-table-make h e))
                (bx (vector-ref prefers 2)))
            (let* ((cur (atomic-box-ref bx))
                   (existing (hashtable-ref cur a #f)))
              (if existing
                  (loop)
                  (let ((next (sa-mm-ht-copy cur (vector-ref prefers 0) (vector-ref prefers 1))))
                    (sa-mm-swap! fresh (lambda (ht) (hashtable-set! ht b #t)))
                    (hashtable-set! next a fresh)
                    (unless (eq? (atomic-box-compare-and-swap! bx cur next) cur)
                      (loop))))))))))

(define-syntax sa-mm-prefer-put!
  (syntax-rules ()
    ((_ _mu prefers a b h e after ...)
     (begin
       (sa-mm-prefer-insert! prefers a b h e)
       after ...))))

(define (sa-mm-prefers-entries-snap prefers)
  (call-with-values
    (lambda () (hashtable-entries (atomic-box-ref (vector-ref prefers 2))))
    (lambda (ks vs)
      (cons ks
            (vector-map (lambda (sub)
                          (hashtable-keys (atomic-box-ref (vector-ref sub 2))))
                        vs)))))

(define-syntax sa-mm-prefers-entries
  (syntax-rules ()
    ((_ _mu prefers)
     (sa-mm-prefers-entries-snap prefers))))

(define (sa-mm-cache-make h e)
  (vector h e (make-atomic-box (vector -1 #f (make-hashtable h e)))))

(define-syntax sa-mm-cache-ref
  (syntax-rules ()
    ((_ cache k d)
     (hashtable-ref (vector-ref (atomic-box-ref (vector-ref cache 2)) 2) k d))))

(define-syntax sa-mm-cache-validate!
  (syntax-rules ()
    ((_ _mu mf cur-ep-expr cur-hier get-cache _get-ep _set-ep! _get-hier _set-hier!)
     (let* ((c (get-cache mf))
            (bx (vector-ref c 2))
            (h (vector-ref c 0))
            (e (vector-ref c 1))
            (hier cur-hier))
       (let loop ()
         (let ((st (atomic-box-ref bx))
               (ep cur-ep-expr))
           (unless (and (fx=? (vector-ref st 0) ep)
                        (eq? (vector-ref st 1) hier))
             (let ((fresh (vector ep hier (make-hashtable h e))))
               (unless (eq? (atomic-box-compare-and-swap! bx st fresh) st)
                 (loop))))))))))

(define-syntax sa-mm-cache-put!
  (syntax-rules ()
    ((_ _mu _mf cache cur-ep-expr target-ep target-hier dv m _get-ep _get-hier)
     (let* ((c cache)
            (bx (vector-ref c 2))
            (h (vector-ref c 0))
            (e (vector-ref c 1)))
       (let loop ()
         (let ((st (atomic-box-ref bx)))
           (when (and (fx=? target-ep cur-ep-expr)
                      (fx=? (vector-ref st 0) target-ep)
                      (eq? (vector-ref st 1) target-hier))
             (let ((next-ht (sa-mm-ht-copy (vector-ref st 2) h e)))
               (hashtable-set! next-ht dv m)
               (let ((next-st (vector target-ep target-hier next-ht)))
                 (unless (eq? (atomic-box-compare-and-swap! bx st next-st) st)
                   (loop)))))))))))
