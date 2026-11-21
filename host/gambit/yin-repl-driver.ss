;; The native and interpreted boots use the same source loader and Yin owner.
(##include "host-apply.ss")
(##include "source-loader.ss")
(##include "unbound-vars-lib.ss")
(##include "yin/blake3.ss")

(define (gambit-yin-random-bytes size)
  (let* ((n (jnum->exact size))
         (out (make-u8vector n)))
    (call-with-input-file "/dev/urandom"
      (lambda (port)
        (unless (= (read-subu8vector out 0 n port) n)
          (error "Gambit could not read OS entropy"))))
    out))

;; A single outstanding request keeps the input reader from filling the
;; mailbox. Only Yin's owner interprets submitted lines.
(define (gambit-yin-wake)
  (vector
    (thread-start!
      (make-thread
        (lambda ()
          (let loop ()
            (let* ((owner (thread-receive))
                   (line (read-line)))
              (thread-send owner (if (eof-object? line) jolt-nil line))
              (unless (eof-object? line) (loop)))))))
    #f))

(define (gambit-yin-close-wake! wake)
  (thread-terminate! (vector-ref wake 0))
  jolt-nil)

(define (gambit-yin-wait-input! wake ms on-line)
  (let ((seconds (/ ms 1000.0)))
    (if (jolt-nil? on-line)
        (thread-sleep! seconds)
        (begin
          (unless (vector-ref wake 1)
            (thread-send (vector-ref wake 0) (current-thread))
            (vector-set! wake 1 #t))
          (let ((line (thread-receive seconds #f)))
            (when line
              (vector-set! wake 1 #f)
              (jolt-invoke on-line line))))))
  jolt-nil)

(set! jolt-random-bytes gambit-yin-random-bytes)
(register-class-statics! "System"
  (list (cons "currentTimeMillis" gambit-epoch-ms)
        (cons "exit" (lambda (status) (exit (jnum->exact status))))))

(let ((args (cdr (command-line))))
  (unless (pair? args)
    (display "usage: yin-repl-main.ss DATOMWORLD_ROOT [Yin arguments...]\n" (current-error-port))
    (exit 2))
  (let ((root (path-expand (car args)))
        (jolt-root (current-directory)))
    (unless (file-exists? (path-expand "src/cljc/yin/repl/main.cljc" root))
      (fprintf (current-error-port) "yin.repl: no source entry under ~a\n" root)
      (exit 2))
    (with-exception-catcher
      (lambda (e)
        (let* ((value (jolt-unwrap-throw e))
               (message (jolt-throwable-message value))
               (location (jolt-current-source-string)))
          (fprintf (current-error-port) "yin.repl startup failed: ~a\n"
                   (if (string? message) message (jolt-pr-readable value)))
          (when (and (string? location) (not (string=? location "")))
            (fprintf (current-error-port) "Yin source: ~a\n" location))
          (exit 1)))
      (lambda ()
        ;; Cache the qualified bridge before resolving Yin's paths relative to
        ;; its own checkout. The source loader itself uses absolute roots.
        (joltffi-ensure-bridge! 'yin.repl)
        (let ((load-ns
                (gambit-install-source-loader!
                  (list (list (path-expand "host/gambit/yin" jolt-root) ".jolt")
                        (list (path-expand "src/jolt" root) ".jolt" ".cljc" ".clj")
                        (list (path-expand "src/cljc" root) ".cljc" ".clj")
                        (list (path-expand "src/clj" root) ".clj")
                        (list (path-expand "stdlib" jolt-root) ".jolt" ".cljc" ".clj")
                        (list (path-expand "jolt-core" jolt-root) ".cljc" ".clj"))
                  '("clojure.core"))))
          (parameterize ((current-directory root))
            (let* ((audit? (getenv "JOLT_YIN_AUDIT" #f))
                   (before (and audit? (unbound-var-names))))
              (dynamic-wind
                (lambda () #f)
                (lambda () (load-ns "jolt.gambit.yin" #f))
                (lambda ()
                  (when audit?
                    (let ((added (filter (lambda (name) (not (member name before)))
                                         (unbound-var-names))))
                      (fprintf (current-error-port) "yin source var audit: ~a newly unbound\n"
                               (length added))
                      (for-each (lambda (name) (fprintf (current-error-port) "  ~a\n" name))
                                added))))))
            (def-var! "yin.repl" "host-text" (string-append "Host: jolt / Gambit " (system-version-string)))
            (let ((main (var-deref "jolt.gambit.yin" "-main")))
              (unless (procedure? main)
                (error "jolt.gambit.yin/-main did not load"))
              (apply jolt-invoke main (cdr args)))))))))
