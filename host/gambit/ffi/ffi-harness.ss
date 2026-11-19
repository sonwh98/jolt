;; ffi-harness.ss — shared harness for the gambitffi* stage-1 gates.
;;
;; ##include-spliced by each gate script (same-unit rule as gambitcheck: the
;; prelude's shims and the adapter's macros must expand in THIS unit). The
;; bridge and fixture libraries are built by the Makefile BEFORE the gate runs
;; (a c-lambda is a compiled facility; nothing here compiles anything). A
;; missing artifact is a FAILED gate — fail-closed, never a skip.

(##include "../prelude-shims.ss")
(##include "../scheme-adapter-runtime.ss")

(define ffi-failures 0)
(define ffi-checks 0)

(define (ffi-check label actual expected)
  (set! ffi-checks (+ ffi-checks 1))
  (if (equal? actual expected)
      (begin (printf "  ok     ~a\n" label) #t)
      (begin (printf "  FAIL   ~a: got ~s expected ~s\n" label actual expected)
             (set! ffi-failures (+ ffi-failures 1))
             #f)))

(define (ffi-check-true label v)
  (ffi-check label (if v #t #f) #t))

(define (ffi-check-raise-message label thunk expected-msg)
  (set! ffi-checks (+ ffi-checks 1))
  (let ((m (guard (e (#t (condition-message e)))
             (thunk)
             "NO-RAISE")))
    (if (string-contains m expected-msg)
        (begin (printf "  ok     ~a -> ~a\n" label m) #t)
        (begin (printf "  FAIL   ~a: got ~s expected message containing ~s\n"
                       label m expected-msg)
               (set! ffi-failures (+ ffi-failures 1))
               #f))))

(define (ffi-check-raise-exact label thunk expected-msg)
  (set! ffi-checks (+ ffi-checks 1))
  (let ((m (guard (e (#t (condition-message e)))
             (thunk)
             "NO-RAISE")))
    (if (string=? m expected-msg)
        (begin (printf "  ok     ~a -> ~a\n" label m) #t)
        (begin (printf "  FAIL   ~a: got ~s expected exactly ~s\n"
                       label m expected-msg)
               (set! ffi-failures (+ ffi-failures 1))
               #f))))

(define (string-contains s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> m (- n i)) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

;; the fixture library, built into build/gambit-ffi by the Makefile target
(define ffi-fixture-path "build/gambit-ffi/libjoltffi-fixture.dylib")
(define ffi-fixture2-path "build/gambit-ffi/libjoltffi-fixture2.dylib")

;; Selected by the same Makefile OS branch as the fixture link flags. Keep the
;; two supported names explicit; do not guess an accessor on another host.
(define (ffi-errno-accessor-name)
  (let ((name (getenv "JOLT_FFI_ERRNO_ACCESSOR")))
    (if (and name (or (string=? name "__error")
                      (string=? name "__errno_location")))
        name
        (error 'gambitffi-abi "missing/unsupported errno accessor selection; run make gambitffi-abi"))))

;; every gate starts here: the qualified tier is the adapter + the bridge, so
;; the bridge MUST load (fail-closed when absent — that IS the assertion)
(define (ffi-load-fixture!)
  (sa-load-shared-object ffi-fixture-path))

(define (ffi-gate-finish name)
  (printf "\n~a: ~a check(s), ~a failure(s)\n" name ffi-checks ffi-failures)
  (if (= ffi-failures 0)
      (begin (printf "~a: PASS\n" name) (exit 0))
      (begin (printf "~a: FAILED\n" name) (exit 1))))
