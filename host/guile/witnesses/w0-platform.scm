;; W0 — platform/configuration witness for the provisioned Guile 3.0.11.
;;
;; Records, verbatim, the identity facts TARGET-CONTRACT.md says a port
;; derives (os-family / arch / endian / host-tag) plus the runtime
;; configuration facts the Phase 2a matrix depends on:
;;   - exact (version) and %host-type
;;   - POSIX (uname) fields
;;   - (native-endianness) for sa-endian
;;   - threads feature presence ((provided? 'threads))
;;   - (srfi srfi-18) resolvability — the guile.ss stub header and the
;;     brief both say it is GONE in 3.0.11; the 3.0.11 manual documents
;;     it (manual §7.5.15).  This records the executable truth.
;;   - GC engine probe: (gc-stats) key set (feeds the sa-bytes-allocated /
;;     sa-total-memory-bytes mapping rows and proves (gc) is observable)
;;   - memory accounting primitives presence
;;
;; Every check prints CHECK-OK / CHECK-FAIL; the verdict is PASS only when
;; no CHECK-FAIL appears and the required bindings resolved.

(use-modules (ice-9 threads)
             (srfi srfi-1)
             (rnrs bytevectors))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a: ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label
          (if ok "yes" "NO"))
  (or ok (set! fails (+ fails 1))))

(format #t "=== W0 platform witness ===~%")
(format #t "version=~a~%" (version))
(format #t "effective-version=~a~%" (effective-version))
(format #t "host-type=~a~%" %host-type)
(format #t "native-endianness=~a~%" (native-endianness))

(let ((u (uname)))
  (format #t "uname: sys=~s node=~s release=~s machine=~s~%"
          (utsname:sysname u) (utsname:nodename u)
          (utsname:release u) (utsname:machine u)))

(format #t "threads-feature=~a~%" (provided? 'threads))
(check "threads feature provided" (provided? 'threads))
(check "endian is a symbol" (symbol? (native-endianness)))
(check "version string nonempty" (> (string-length (version)) 0))

;; SRFI-18 presence — the surprise row (names use the SRFI's own bang
;; spellings: condition-variable-signal! / condition-variable-broadcast!).
(let ((m (false-if-exception (resolve-interface '(srfi srfi-18)))))
  (format #t "srfi-18-resolvable=~a~%" (and m #t))
  (if m
      (let ((names '(current-thread make-thread thread-start! thread-join!
                    thread-sleep! make-mutex mutex-lock! mutex-unlock!
                    make-condition-variable condition-variable-signal!
                    condition-variable-broadcast! current-time
                    seconds->time time->seconds)))
        (format #t "srfi-18 exports present: ~a~%"
                (filter (lambda (n) (module-bound? m n)) names))
        (check "srfi-18 module resolves with the thread/mutex/condvar names"
               (every (lambda (n) (module-bound? m n)) names)))
      (check "srfi-18 module resolves" #f)))

;; (ice-9 threads) surface actually used by the contract mapping.
(let ((m (resolve-interface '(ice-9 threads))))
  (let ((names '(call-with-new-thread join-thread make-mutex lock-mutex
                 unlock-mutex try-mutex with-mutex make-condition-variable
                 wait-condition-variable signal-condition-variable
                 broadcast-condition-variable yield
                 make-recursive-mutex thread-exited?)))
    (format #t "ice-9-threads missing: ~a~%"
            (remove (lambda (n) (module-bound? m n)) names))
    (check "ice-9 threads exports the contract's mapping names"
           (every (lambda (n) (module-bound? m n)) names))))

;; SRFI-18 disjointness fact the manual pins (manual §7.5.15): a Guile
;; mutex is not a SRFI-18 mutex.  Record the primitive object.
(let ((g (make-mutex)))
  (format #t "guile-make-mutex-procedure-ok=~a~%" (mutex? g))
  (check "ice-9 make-mutex constructs a primitive mutex" (mutex? g)))

;; GC observability: (gc) must be a real collection (feeds W6 and the
;; sa-gc-collect row).  We only record stats shape here.
(define stats-before (gc-stats))
(gc)
(define stats-after (gc-stats))
(format #t "gc-stats keys: ~a~%"
        (sort (map car stats-after)
              (lambda (a b) (string<? (symbol->string a)
                                      (symbol->string b)))))
(check "gc-stats is a nonempty alist" (pair? stats-after))
(let ((key-have (map car stats-after)))
  (for-each
   (lambda (k)
     (format #t "gc-stats ~a = ~a~%" k (assq-ref stats-after k)))
   (filter (lambda (k) (memq k key-have))
           '(gc-time-taken gc-times heap-allocated-since-gc heap-free-size
             heap-size heap-total-allocated protected-objects))))
(check "(gc) ran between two gc-stats reads (gc-times incremented)"
       (> (assq-ref stats-after 'gc-times)
          (assq-ref stats-before 'gc-times)))

;; Negative controls: feature/module probes must fail on nonexistent targets
;; (not vacuously true).
(check "NC1 control: nonexistent feature is not provided"
       (not (provided? 'definitely-no-such-feature-w0)))
(check "NC2 control: nonexistent module does not resolve"
       (not (false-if-exception (resolve-interface '(no such module w0)))))

;; sa-host-tag candidate: any stable identifier; nothing parses it.
(format #t "host-tag-candidate=~s~%"
        (string-append "guile-" (version) "-" %host-type))

(if (zero? fails)
    (format #t "W0-VERDICT: PASS (platform recorded, ~a checks)~%" "all")
    (format #t "W0-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
