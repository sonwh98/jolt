;; Compatibility entry point for make gambitgen and GEN_RECORDS_OUT.
(import (chezscheme))
(command-line (cons (car (command-line)) '("gambit")))
(load "host/chez/gen-records.ss")
