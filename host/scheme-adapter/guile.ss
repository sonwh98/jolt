#!no-fold-case
;; host/scheme-adapter/guile.ss — PSL adaptercheck gate for the Guile target.
;;
;; Verifies every identifier listed in host/scheme-adapter/CONTRACT.txt is bound
;; in the captured Jolt boot module (jolt runtime) and expands every syntax form
;; exported across the contract. Invoked by `make adaptercheck` and shared with
;; `host/guile/guilecheck.ss`.

(let ((existing (resolve-module '(jolt runtime) #f #f #:ensure #f)))
  (unless (and existing (module-variable existing '%jolt-boot-module))
    (let* ((here (let ((cf (current-filename))) (and cf (dirname cf))))
           (cwd-boot (string-append (getcwd) "/host/guile/boot.ss"))
           (boot-path
             (cond
               ((and here (file-exists? (string-append here "/../guile/boot.ss")))
                (canonicalize-path (string-append here "/../guile/boot.ss")))
               ((file-exists? cwd-boot) cwd-boot)
               (else (error 'guile-adaptercheck "cannot locate host/guile/boot.ss")))))
      (primitive-load boot-path))))

(eval
 '(begin
    (define (%ac-repo-root)
      (cond
        ((file-exists? "host/scheme-adapter/CONTRACT.txt") "")
        ((let ((cf (current-filename)))
           (and cf
                (let ((p (string-append (dirname cf) "/../../host/scheme-adapter/CONTRACT.txt")))
                  (and (file-exists? p) (string-append (dirname cf) "/../../")))))
         => identity)
        (else "")))

    (define (%ac-contract-names path)
      (call-with-input-file path
        (lambda (p)
          (let loop ((acc '()))
            (let ((line (get-line p)))
              (if (eof-object? line)
                  (reverse acc)
                  (let* ((trimmed (string-trim-both line)))
                    (if (or (string=? trimmed "")
                            (char=? (string-ref trimmed 0) #\#))
                        (loop acc)
                        (loop (cons (string->symbol trimmed) acc))))))))))

    (define %ac-syntax-samples
      '((with-mutex . (with-mutex (make-mutex) (+ 1 2)))
        (sa-foreign-procedure . (sa-foreign-procedure "puts" (void*) int))
        (sa-foreign-procedure-native-error . (sa-foreign-procedure-native-error "puts" (void*) int))
        (sa-foreign-procedure-blocking . (sa-foreign-procedure-blocking "puts" (void*) int))
        (sa-foreign-callable . (sa-foreign-callable (lambda (x) x) (int) int))
        (sa-foreign-callable-collect-safe . (sa-foreign-callable-collect-safe (lambda (x) x) (int) int))
        (sa-ufx+ . (sa-ufx+ 1 2))
        (sa-ufx- . (sa-ufx- 5 2))
        (sa-ufx<? . (sa-ufx<? 1 2))
        (sa-ufx>=? . (sa-ufx>=? 2 1))
        (sa-ufx=? . (sa-ufx=? 2 2))
        (sa-uvector-ref . (sa-uvector-ref (vector 10 20) 1))
        (sa-uvector-set! . (let ((v (vector 1 2))) (sa-uvector-set! v 0 9) v))
        (sa-ustring-ref . (sa-ustring-ref "abc" 1))
        (sa-uflvector-ref . (sa-uflvector-ref (make-flvector 2 1.5) 0))
        (sa-uflvector-set! . (let ((v (make-flvector 2 1.5))) (sa-uflvector-set! v 0 2.5) v))
        (sa-ubytevector-ieee-single-native-ref . (sa-ubytevector-ieee-single-native-ref (make-bytevector 4 0) 0))
        (sa-ubytevector-ieee-single-native-set! . (let ((bv (make-bytevector 4 0))) (sa-ubytevector-ieee-single-native-set! bv 0 1.5) bv))
        (sa-ubytevector-ieee-double-native-ref . (sa-ubytevector-ieee-double-native-ref (make-bytevector 8 0) 0))
        (sa-ubytevector-ieee-double-native-set! . (let ((bv (make-bytevector 8 0))) (sa-ubytevector-ieee-double-native-set! bv 0 1.5) bv))))

    (define (jolt-guile-adapter-check!)
      (let* ((root (%ac-repo-root))
             (contract-path (string-append root "host/scheme-adapter/CONTRACT.txt"))
             (names (%ac-contract-names contract-path))
             (env (interaction-environment))
             (missing '())
             (syntax-checked 0))
        (for-each
          (lambda (sym)
            (let ((v (module-variable env sym)))
              (cond
                ((or (not v) (not (variable-bound? v)))
                 (set! missing (cons sym missing)))
                ((macro? (variable-ref v))
                 (let ((sample (assq sym %ac-syntax-samples)))
                   (if (not sample)
                       (set! missing (cons (string->symbol (string-append (symbol->string sym) " (no syntax sample)")) missing))
                       (catch #t
                         (lambda ()
                           (eval `(macroexpand ',(cdr sample)) env)
                           (set! syntax-checked (+ syntax-checked 1)))
                         (lambda (key . args)
                           (format (current-error-port)
                                   "adaptercheck (guile): syntax expansion failed for ~s: ~s ~s\n"
                                   sym key args)
                           (set! missing (cons sym missing))))))))))
          names)
        (if (null? missing)
            (begin
              (format #t "adaptercheck (guile): ~a contract names checked (~a syntax forms expanded) against (jolt runtime)\n"
                      (length names) syntax-checked)
              (format #t "adaptercheck (guile): guile adapter contract satisfied\n")
              #t)
            (begin
              (format (current-error-port)
                      "adaptercheck (guile): FAILED — ~a CONTRACT.txt issue(s) on Guile:\n"
                      (length missing))
              (for-each (lambda (s) (format (current-error-port) "  - ~s\n" s))
                        (reverse missing))
              #f)))))
 (resolve-module '(jolt runtime)))

(unless (defined? '%jolt-adaptercheck-library-only?)
  (let ((ok ((module-ref (resolve-module '(jolt runtime)) 'jolt-guile-adapter-check!))))
    (unless ok (exit 1))))
