#!/usr/bin/env gsi-script
;; The gate builds the kernel with gsc. App namespaces still load from source.
;; The Gambit boot omits Chez's external data-reader loader.
(define data-readers-active #f)
(load (getenv "JOLT_GAMBIT_YIN_BOOT"))
(##include "yin-repl-driver.ss")
