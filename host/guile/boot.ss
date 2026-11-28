#!no-fold-case
;; host/guile/boot.ss — Guile 3.0.11 reader setup, (jolt runtime) module, and
;; profile selection. The default kernel profile is used by adapter probes.

(read-enable 'r6rs-hex-escapes)
(read-enable 'r7rs-symbols)

(define-module (jolt runtime)
  #:declarative? #f
  #:duplicates (replace)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 control)
  #:use-module (ice-9 pretty-print)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 soft-ports)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-4)
  #:use-module (srfi srfi-11)
  #:use-module ((srfi srfi-19) #:prefix srfi19:)
  #:use-module ((system foreign) #:prefix ffi:)
  #:use-module (system foreign-library)
  #:use-module ((rnrs base) #:select ((error . r6base:error) assertion-violation))
  #:use-module (rnrs arithmetic fixnums)
  #:use-module (rnrs arithmetic bitwise)
  #:use-module (rnrs arithmetic flonums)
  #:use-module ((rnrs lists) #:select (find for-all exists fold-left fold-right remp remq remv memp assp))
  #:use-module (rnrs syntax-case)
  #:use-module ((rnrs bytevectors) #:prefix r6bv:)
  #:use-module (rnrs conditions)
  #:use-module (rnrs exceptions)
  #:use-module ((rnrs hashtables) #:prefix r6ht:)
  #:use-module ((rnrs io ports) #:prefix r6io:)
  #:use-module ((rnrs records inspection) #:prefix r6i:)
  #:use-module ((rnrs records procedural) #:prefix r6p:)
  #:use-module ((rnrs sorting) #:prefix r6sort:))

(define %jolt-guile-dir
  (let ((cf (current-filename)))
    (if cf (dirname cf) "host/guile")))

(define (%jolt-guile-path rel)
  (string-append %jolt-guile-dir "/" rel))

(define (%jolt-chez-path rel)
  (string-append %jolt-guile-dir "/../chez/" rel))

(define %jolt-loaded-files '())

(define (%jolt-load-file path)
  (catch #t
    (lambda ()
      (primitive-load path)
      (set! %jolt-loaded-files (cons path %jolt-loaded-files)))
    (lambda (key . args)
      (format (current-error-port) "boot.ss: failed loading ~a\n" path)
      (apply throw key args))))

;; The shared runtime uses repo-relative names for its embedded loads.
(define (load path)
  (%jolt-load-file (if (absolute-file-name? path) path
                       (string-append %jolt-guile-dir "/../../" path))))

(define (%jolt-load-guile rel)
  (%jolt-load-file (%jolt-guile-path rel)))

(define (%jolt-load-chez rel)
  (%jolt-load-file (%jolt-chez-path rel)))

(define raise (@ (rnrs exceptions) raise))

(define (most-negative-fixnum) (@ (guile) most-negative-fixnum))
(define (most-positive-fixnum) (@ (guile) most-positive-fixnum))
(define (flonum->fixnum x) (inexact->exact (truncate x)))

;; Stage 1: Compatibility shims and Guile CONTRACT runtime adapter
(%jolt-load-guile "prelude-shims.ss")
(%jolt-load-guile "scheme-adapter-runtime.ss")

;; Stage 2: Core value model, checked 32-bit hasheq, persistent collections, seq
(%jolt-load-chez "values.ss")
(%jolt-load-guile "hasheq.ss")
(%jolt-load-chez "collections.ss")
(%jolt-load-chez "seq.ss")

(%jolt-load-guile "rt-core.ss")
(define %jolt-profile (or (getenv "JOLT_GUILE_PROFILE") "kernel"))
(unless (member %jolt-profile '("kernel" "repl" "full"))
  (error 'boot "unknown Guile profile" %jolt-profile))
(define (lazy-shims-method! name) #f)

(if (string=? %jolt-profile "kernel")
    (for-each %jolt-load-chez
              '("multimethods.ss" "java/jdk-interfaces.ss" "java/class-hierarchy.ss")))
(%jolt-load-guile "profiles.ss")
