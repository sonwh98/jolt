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
           (guard (e (#t (table-set! loaded name 'failed) (raise e)))
             (jolt-with-ns-bound
               (lambda ()
                 (jolt-eval-string (call-with-input-file file gambit-read-all) file)
                 (unless (string=? name (chez-current-ns))
                   (throw-jvm 'IllegalStateException
                              (string-append file ": expected namespace " name)))))
             (table-set! loaded name 'ready)))))))
  (set-ns-load-target! load-namespace)
  (set-ns-with-load-opts!
    (lambda (flags proceed)
      (unless (null? flags)
        (throw-jvm 'UnsupportedOperationException
                   (string-append "require option is unsupported on the gambit source loader: :"
                                  (car flags))))
      (proceed #f)))
  (def-var! "clojure.core" "require" jolt-require)
  (def-var! "clojure.core" "use" jolt-use)
  load-namespace)
