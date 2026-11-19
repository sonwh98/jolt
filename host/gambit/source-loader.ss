;; Opt-in native source namespace loading for embedded applications. Unlike the
;; Chez loader, this only interprets source. It has no cache, FASL, AOT, runtime
;; dependency discovery, or native-library discovery.

(define (gambit-namespace-path name)
  (let ((chars (string->list name)))
    (let check ((rest chars) (need-name? #t))
      (unless (cond
                ((null? rest) (not need-name?))
                ((char=? (car rest) #\.) (and (not need-name?) (check (cdr rest) #t)))
                ((or (char-alphabetic? (car rest)) (char-numeric? (car rest))
                     (memv (car rest) '(#\- #\_)))
                 (check (cdr rest) #f))
                (else #f))
        (throw-jvm 'IllegalArgumentException (string-append "Invalid namespace: " name))))
    (list->string
      (map (lambda (ch) (case ch ((#\.) #\/) ((#\-) #\_) (else ch))) chars))))

;; Gambit's reader tags bracket-delimited lists. Raw Scheme in loaded
;; Jolt libraries uses R6RS brackets as grouping delimiters.
(define (gambit-source-scheme-form datum)
  (define (read-list items)
    (if (pair? items)
        (cons (gambit-source-scheme-form (car items)) (read-list (cdr items)))
        items))
  (cond
    ((pair? datum)
     (case (car datum)
       ((|[...]|) (read-list (cdr datum)))
       ((endianness)
        (unless (and (list? datum) (= (length datum) 2)
                     (memq (cadr datum) '(big little)))
          (error "invalid endianness" datum))
        (list 'quote (cadr datum)))
       (else (read-list datum))))
    ((vector? datum) (vector-map gambit-source-scheme-form datum))
    (else datum)))

(define (gambit-source-scheme-eval text)
  (let ((port (open-input-string (jolt-need-string text))))
    (input-port-readtable-set! port
      (readtable-sharing-allowed?-set (input-port-readtable port) #f))
    (let loop ((last jolt-nil))
      (let ((form (read port)))
        (if (eof-object? form)
            last
            (loop (eval (gambit-source-scheme-form form))))))))

;; Each root is (directory suffix ...), in classpath order. BOOTED names denote
;; whole namespaces supplied by the embedding host and take precedence over
;; files. A mere intern or :as-alias never satisfies a source dependency.
(define (gambit-install-source-loader! roots booted)
  (define loaded (make-table test: string=?))
  (define (find-file name)
    (let ((base (gambit-namespace-path name)))
      (let find-root ((rest roots))
        (and (pair? rest)
             (let find-suffix ((suffixes (cdar rest)))
               (if (null? suffixes)
                   (find-root (cdr rest))
                   (let ((file (string-append (caar rest) "/" base (car suffixes))))
                     (if (and (file-exists? file) (eq? 'regular (file-type file)))
                         file
                         (find-suffix (cdr suffixes))))))))))
  (define (load-namespace name force?)
    (when force?
      (throw-jvm 'UnsupportedOperationException
                 "namespace reload is unsupported on the gambit source loader"))
    (unless (member name booted)
      (case (table-ref loaded name #f)
        ((ready) #f)
        ((loading)
         (throw-jvm 'IllegalStateException (string-append "Cyclic namespace load: " name)))
        ((failed)
         (throw-jvm 'IllegalStateException (string-append "Earlier namespace load failed: " name)))
        (else
         (let ((file (find-file name)))
           (unless file
             (throw-jvm 'FileNotFoundException (string-append "No source for namespace: " name)))
           (table-set! loaded name 'loading)
           (when (getenv "JOLT_TRACE_SOURCE" #f)
             (fprintf (current-error-port) "[~as] load ~a\n" (inexact->exact (round (time->seconds (current-time)))) name)
             (force-output (current-error-port)))
           (guard (e (#t (table-set! loaded name 'failed) (raise e)))
             (jolt-with-ns-bound
               (lambda ()
                 (jolt-eval-string (call-with-input-file file gambit-read-all) file)
                 (unless (string=? name (chez-current-ns))
                   (throw-jvm 'IllegalStateException
                              (string-append file ": expected namespace " name)))))
             (when (getenv "JOLT_TRACE_SOURCE" #f)
               (fprintf (current-error-port) "[~as] ready ~a\n" (inexact->exact (round (time->seconds (current-time)))) name)
               (force-output (current-error-port)))
             (table-set! loaded name 'ready)))))))
  (set-ns-load-target! load-namespace)
  (set-ns-with-load-opts!
    (lambda (flags proceed)
      (unless (null? flags)
        (throw-jvm 'UnsupportedOperationException
                   (string-append "require option is unsupported on the gambit source loader: :"
                                  (car flags))))
      (proceed #f)))
  (def-var! "jolt.host" "scheme-eval-string" gambit-source-scheme-eval)
  (def-var! "clojure.core" "require" jolt-require)
  (def-var! "clojure.core" "use" jolt-use)
  load-namespace)
