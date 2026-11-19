#!/usr/bin/env gsi-script
;; Native source launcher for the real Yin REPL. Run from the Jolt root with
;; gsi host/gambit/yin-repl-main.ss /path/to/datomworld [Yin arguments...].
(##include "boot.ss")
(##include "host-apply.ss")
(##include "source-loader.ss")

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
               (message (jolt-throwable-message value)))
          (fprintf (current-error-port) "yin.repl startup failed: ~a\n"
                   (if (string? message) message (jolt-pr-readable value)))
          (exit 1)))
      (lambda ()
        ;; Cache the qualified bridge before resolving Yin's paths relative to
        ;; its own checkout. The source loader itself uses absolute roots.
        (joltffi-ensure-bridge! 'yin.repl)
        (let ((load-ns
                (gambit-install-source-loader!
                  (list (list (path-expand "src/jolt" root) ".jolt" ".cljc" ".clj")
                        (list (path-expand "src/cljc" root) ".cljc" ".clj")
                        (list (path-expand "src/clj" root) ".clj")
                        (list (path-expand "stdlib" jolt-root) ".jolt" ".cljc" ".clj")
                        (list (path-expand "jolt-core" jolt-root) ".cljc" ".clj"))
                  '("clojure.core"))))
          (parameterize ((current-directory root))
            (load-ns "yin.repl.main" #f)
            (let ((main (var-deref "yin.repl.main" "-main")))
              (unless (procedure? main)
                (error "yin.repl.main/-main did not load"))
              (apply jolt-invoke main (cdr args)))))))))
