(primitive-load "host/guile/boot.ss")
(use-modules (system base compile) (language tree-il analyze))

(define (warnings-for form)
  (let ((out (open-output-string)))
    (parameterize ((current-warning-port out))
      (let ((tree (compile form #:to 'tree-il #:env (interaction-environment))))
        (analyze-tree
          (list (make-use-before-definition-analysis
                  #:enabled-warnings '(unbound-variable)))
          tree (interaction-environment))))
    (get-output-string out)))

(define control
  (warnings-for '(lambda (enabled?) (if enabled? 'ok %guile-unbound-control))))
(unless (string-contains control "%guile-unbound-control")
  (error 'guileunbound "untaken branch control produced no unbound warning" control))
(display control)

(define warnings
  ((@ (srfi srfi-1) filter-map)
    (lambda (path)
      (let ((report
              (call-with-input-file path
                (lambda (port)
                  (let ((out (open-output-string)))
                    (let loop ((form (read port)))
                      (unless (eof-object? form)
                        (display (warnings-for form) out)
                        (loop (read port))))
                    (get-output-string out))))))
        (and (not (string-null? report)) (cons path report))))
    (reverse %jolt-loaded-files)))

(for-each (lambda (entry) (format #t "~a\n~a" (car entry) (cdr entry))) warnings)
(unless (null? warnings)
  (error 'guileunbound "unresolved top-level references" (length warnings)))
(format #t "guileunbound: scanned ~a loaded files\n" (length %jolt-loaded-files))
(display "guileunbound: PASS (full)\n")
