#!/usr/bin/env gsi-script
;; Load the diagnostic composition as source after the normal startup closure.
(##include "../../host/gambit/yin-repl-boot.ss")
(define probe (path-expand "fixtures/yin-dht-probe.jolt"
                          (path-directory (this-source-file))))
(gambit-yin-launch
  (lambda (load-ns args)
    (jolt-with-ns-bound
      (lambda ()
        (set-chez-ns! "jolt.gambit.yin")
        (gambit-load-source-file "jolt.gambit.yin" probe)))
    (gambit-yin-start load-ns args)))
