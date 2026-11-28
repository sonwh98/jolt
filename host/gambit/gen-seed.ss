;; Legacy direct Chez entry point. Make and remint stage through gen-seed.sh.
(import (chezscheme))
(command-line (list (car (command-line)) "gambit"
                    (or (getenv "GEN_SEED_OUT_DIR") "host/gambit/seed")))
(load "host/chez/gen-seed.ss")
