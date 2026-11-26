;; The public launcher and the DHT diagnostic harness share boot selection.
(define gambit-yin-host (path-directory (this-source-file)))
(define gambit-yin-gsi (path-expand "~~bin/gsi"))
(define gambit-yin-mode (getenv "JOLT_GAMBIT_YIN_MODE" "auto"))
(define gambit-yin-strict? (string=? gambit-yin-mode "compiled"))
(define gambit-yin-source-kernel? (getenv "JOLT_GAMBIT_YIN_SOURCE_KERNEL" #f))

(define (gambit-yin-stderr . items)
  (for-each (lambda (item) (display item (current-error-port))) items)
  (newline (current-error-port))
  (force-output (current-error-port)))

(define (gambit-yin-resolve-boot)
  (if (or gambit-yin-source-kernel? (null? (cdr (command-line))))
      '(#f #f #f)
      (let ((helper
              (with-exception-catcher
                (lambda (e)
                  (gambit-yin-stderr "jolt-gambit: Cannot start the boot builder")
                  (display-exception e (current-error-port))
                  (if gambit-yin-strict? (exit 1) #f))
                (lambda ()
                  (open-process
                    (list path: "python3"
                          arguments: (list (path-expand "build-yin-session.py" gambit-yin-host)
                                           gambit-yin-gsi (cadr (command-line)))
                          direction: 'input stdin-redirection: #f stderr-redirection: #f))))))
        (if helper
            (let* ((selection (read helper))
                   (status (process-status helper)))
              (close-port helper)
              (if (and (= status 0) (list? selection) (= (length selection) 3))
                  selection
                  (exit 1)))
            '(#f #f #f)))))

(define gambit-yin-selection (gambit-yin-resolve-boot))
(define gambit-yin-kernel (car gambit-yin-selection))
(define gambit-yin-code (cadr gambit-yin-selection))
(define gambit-yin-key (caddr gambit-yin-selection))

;; A compiled initializer may already have changed vars or registered FFI
;; wrappers when it throws. Retry in a fresh process before any input was read.
(define (gambit-yin-restart-source error source-kernel?)
  (gambit-yin-stderr "jolt-gambit: Compiled Yin startup failed")
  (display-exception error (current-error-port))
  (force-output (current-error-port))
  (if gambit-yin-strict?
      (exit 1)
      (begin
        (gambit-yin-stderr "jolt-gambit: Retrying from source")
        (setenv "JOLT_GAMBIT_YIN_MODE" "source")
        (when source-kernel? (setenv "JOLT_GAMBIT_YIN_SOURCE_KERNEL" "1"))
        ;; Namespace loads run under the Datomworld cwd. Restart at the
        ;; original launcher cwd, with the script and source root absolutized.
        (let* ((args (command-line))
               (child (open-process
                        (list path: gambit-yin-gsi
                              arguments: (cons gambit-yin-launcher
                                             (cons gambit-yin-datomworld (cddr args)))
                              directory: gambit-yin-runtime
                              stdin-redirection: #f stdout-redirection: #f
                              stderr-redirection: #f)))
               (status (process-status child)))
          (close-port child)
          (exit (if (= (bitwise-and status 127) 0)
                    (arithmetic-shift status -8)
                    (+ 128 (bitwise-and status 127))))))))

(define gambit-yin-runtime (current-directory))
(define gambit-yin-launcher (path-expand (car (command-line))))
(define gambit-yin-datomworld
  (and (pair? (cdr (command-line))) (path-expand (cadr (command-line)))))

(define data-readers-active #f)
(if gambit-yin-kernel
    (with-exception-catcher
      (lambda (e) (gambit-yin-restart-source e #t))
      (lambda () (load gambit-yin-kernel)))
    (load (path-expand "boot.ss" gambit-yin-host)))
(##include "yin-repl-driver.ss")

(define (gambit-yin-initializer name file)
  (let ((entry (and gambit-yin-compiled
                    (table-ref gambit-yin-compiled name #f))))
    (and entry (string=? file (car entry))
         (lambda ()
           (with-exception-catcher
             (lambda (e) (gambit-yin-restart-source e #f))
             (lambda ()
               (jolt-with-eval-source (call-with-input-file file gambit-read-all)
                 file (ls-file-name file) (cdr entry))))))))

(define (gambit-yin-launch after-load)
  (when (and gambit-yin-strict? (not gambit-yin-code))
    (gambit-yin-stderr "jolt-gambit: Compiled Yin boot required")
    (exit 1))
  (when gambit-yin-code
    (with-exception-catcher
      (lambda (e) (gambit-yin-restart-source e #f))
      (lambda () (load gambit-yin-code))))
  (if gambit-yin-code
      (gambit-yin-stderr "jolt-gambit: compiled Yin boot " gambit-yin-key)
      (gambit-yin-stderr "jolt-gambit: source Yin namespaces"))
  (gambit-yin-run gambit-load-source-file after-load gambit-yin-initializer))
