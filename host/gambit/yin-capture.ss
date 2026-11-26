#!/usr/bin/env gsi-script
;; Capture only emitted Scheme for the ordinary static startup namespace loads.
;; The capture process evaluates dependencies for macro expansion and exits
;; before Yin initializes a session. Every initializer runs again at launch.
(define data-readers-active #f)
(load (getenv "JOLT_GAMBIT_YIN_BOOT"))
(##include "yin-repl-driver.ss")

(define capture-directory (getenv "JOLT_GAMBIT_YIN_CAPTURE"))

(define (gambit-yin-capture-file name file)
  (let ((code (open-output-string))
        (previous (gambit-yin-gensym-counters))
        (parent (jolt-aot-capture))
        (parent-checkpoint (jolt-aot-form-checkpoint)))
    (define (checkpoint port position)
      (let ((now (gambit-yin-gensym-counters)))
        (when port
          ;; The reader/expander consumed these fresh names. Advance by the
          ;; same amount before replaying this form; its runtime work still
          ;; runs normally and accounts for its own allocations.
          (let ((delta (map - now previous)))
            (unless (equal? delta '(0 0 0))
              (write (cons 'gambit-yin-advance-gensyms! delta) port)
              (newline port)))
          (display "(jolt-site-reset!)\n" port)
          (when (pmap? position)
            (write `(jolt-set-form-position!
                      (jolt-hash-map hc-kw-file ,file
                                     hc-kw-line ,(jolt-get position hc-kw-line 0)
                                     hc-kw-column ,(jolt-get position hc-kw-column 0)))
                   port)
            (newline port)))
        (set! previous now)))
    ;; A namespace reached while reading/expanding a form also needs to be
    ;; initialized during replay. Runtime require runs with the tee off.
    (when parent
      (parent-checkpoint parent #f)
      (write `(ns-load-target! ,name #f) parent)
      (newline parent))
    (parameterize ((jolt-aot-capture code) (jolt-aot-form-checkpoint checkpoint))
      (gambit-load-source-file name file))
    (when parent (parent-checkpoint #f #f))
    (call-with-output-file (path-expand (string-append name ".ss") capture-directory)
      (lambda (out)
        (display "(gambit-yin-register! " out)
        (write name out)
        (display " " out)
        (write file out)
        (display "\n  (lambda ()\n" out)
        (display (get-output-string code) out)
        (display "\n    jolt-nil))\n" out)))))

(gambit-yin-run gambit-yin-capture-file
  (lambda (load-ns args)
    ;; open-dht requires this namespace before the first prompt. Follow the
    ;; dependency now without opening a store or taking session input.
    (load-ns "dao.space.dht" #f)))
