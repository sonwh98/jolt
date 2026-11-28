#!no-fold-case
;; host/guile/boot.ss — Guile 3.0.11 reader setup, (jolt runtime) module, and
;; Phase 3a minimal kernel boot manifest.

(read-enable 'r6rs-hex-escapes)
(read-enable 'r7rs-symbols)

(define-module (jolt runtime)
  #:duplicates (replace)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 control)
  #:use-module (ice-9 pretty-print)
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

(define (%jolt-load-file path)
  (catch #t
    (lambda () (primitive-load path))
    (lambda (key . args)
      (format (current-error-port) "boot.ss: failed loading ~a\n" path)
      (apply throw key args))))

(define (%jolt-load-guile rel)
  (%jolt-load-file (%jolt-guile-path rel)))

(define (%jolt-load-chez rel)
  (%jolt-load-file (%jolt-chez-path rel)))

;; Stage 1: Compatibility shims and Guile CONTRACT runtime adapter
(%jolt-load-guile "prelude-shims.ss")
(%jolt-load-guile "scheme-adapter-runtime.ss")

;; Stage 2: Core value model, checked 32-bit hasheq, persistent collections, seq
(%jolt-load-chez "values.ss")
(%jolt-load-guile "hasheq.ss")
(%jolt-load-chez "collections.ss")
(%jolt-load-chez "seq.ss")

;; Stage 3: Minimal kernel subset (vars, dispatch, printing, exceptions, hierarchy/records/meta/lazy-bridge)
(%jolt-load-guile "rt-core.ss")
(%jolt-load-chez "multimethods.ss")
(%jolt-load-chez "java/jdk-interfaces.ss")
(%jolt-load-chez "java/class-hierarchy.ss")
(%jolt-load-chez "records.ss")
(%jolt-load-chez "records-coll.ss")
(%jolt-load-chez "protocols.ss")
(%jolt-load-chez "records-dispatch.ss")
(%jolt-load-chez "java/records-interop.ss")
(%jolt-load-chez "natives-meta.ss")
(%jolt-load-chez "lazy-bridge.ss")
