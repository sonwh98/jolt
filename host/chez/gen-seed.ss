;; Cross-mint the checked seed from the converged Chez compiler.
(import (chezscheme))

(define target
  (let ((args (cdr (command-line))))
    (unless (and (= (length args) 2) (member (car args) '("gambit" "guile")))
      (error 'gen-seed "expected target gambit or guile and staging directory" args))
    (car args)))
(define gs-out-dir (caddr (command-line)))

(load "host/chez/scheme-adapter-runtime.ss")  ; before rt.ss: macros + top-levels in rt.ss/java/*.ss call sa-*
(load "host/chez/rt.ss")
(set-chez-ns! "clojure.core")
(load "host/chez/seed/prelude.ss")
(load "host/chez/post-prelude.ss")
(set-chez-ns! "user")
(load "host/chez/host-contract.ss")
(load "host/chez/seed/image.ss")
(load "host/chez/compile-eval.ss")
(load "host/chez/emit-image.ss")

;; The flags live on the published compiler unit. A fresh unit initially
;; selects Chez and has prelude mode and var-cell hoisting disabled.
(ei-fresh-unit!)
(define (set-flag! name value)
  (let ((setter (var-deref "jolt.backend-scheme" name)))
    (unless (procedure? setter)
      (error 'gen-seed "compiler setting is missing" name))
    (setter value)))
(set-flag! "set-prelude-mode!" #t)
(set-flag! "set-var-cache!" #t)
(set-flag! "set-target!" (keyword #f target))
(unless (eq? ((var-deref "jolt.backend-scheme.session" "target")) (keyword #f target))
  (error 'gen-seed "compiler did not select requested target" target))
(printf "gen-seed: backend target -> :~a\n" target)

;; Emit both artifacts to strings FIRST, verify, then write. A chez-flavored
;; emission must fail without producing files.
(ei-reset-skipped!)
(define gs-prelude (jolt-emit-prelude))
(define gs-image (jolt-emit-image))

(unless (zero? ei-skipped-count)
  (error 'gen-seed "forms skipped during cross-mint" ei-skipped-count))

;; Read emitted Scheme as data. Quoted compiler templates and string values
;; may describe other targets, while executable forms may not use those heads.
(define forbidden-heads
  '(foreign-procedure foreign-callable define-ftype make-ftype-pointer
    ftype-&ref ftype-ref ftype-set! &))

(define (gs-verify text name)
  (define (walk form)
    (when (and (string=? target "guile") (or (box? form) (bwp-object? form)))
      (error 'gen-seed "forbidden Chez literal" name form))
    (when (and (pair? form) (not (eq? (car form) 'quote)))
      (let ((head (car form)))
        (when (and (symbol? head)
                   (or (memq head forbidden-heads)
                       (let ((spelling (symbol->string head)))
                         (or (and (>= (string-length spelling) 3)
                                  (string=? (substring spelling 0 3) "#3%"))
                             (and (string=? target "guile")
                                  (>= (string-length spelling) 2)
                                  (string=? (substring spelling 0 2) "##"))))))
          (error 'gen-seed "forbidden executable head" name head)))
      (walk (car form))
      (walk-tail (cdr form))))
  (define (walk-tail forms)
    (when (pair? forms)
      (walk (car forms))
      (walk-tail (cdr forms))))
  (let ((port (open-input-string text)))
    (let loop ((form (read port)) (count 0))
      (if (eof-object? form)
          (begin
            (when (zero? count) (error 'gen-seed "empty artifact" name))
            (printf "gen-seed: ~a verified (~a forms)\n" name count))
          (begin
            (unless (and (pair? form) (eq? (car form) 'guard))
              (error 'gen-seed "unexpected top-level form" name form))
            (walk form)
            (loop (read port) (+ count 1)))))))

(gs-verify gs-prelude "prelude")
(gs-verify gs-image "image")

(define (gs-write path text)
  (let ((p (open-output-file path 'replace)))
    (put-string p text)
    (close-port p))
  (display (string-append "gen-seed: wrote " path " ("
                          (number->string (bytevector-length (string->utf8 text))) " bytes)\n")))

(define (gs-prologue text)
  (if (string=? target "guile") (string-append "#!no-fold-case\n" text) text))

(gs-write (string-append gs-out-dir "/prelude.ss") (gs-prologue gs-prelude))
(gs-write (string-append gs-out-dir "/image.ss") (gs-prologue gs-image))
(printf "gen-seed: ~a seed minted on Chez\n" target)
