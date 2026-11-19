(##include "boot.ss")
(##include "host-apply.ss")
(##include "source-loader.ss")

(define (source-check description expected run)
  (let ((got (with-exception-catcher
               (lambda (e) (jolt-throwable-message (jolt-unwrap-throw e)))
               run)))
    (unless (equal? expected got)
      (fprintf (current-error-port) "gambitsourceload: FAIL ~a: expected ~s, got ~s\n"
               description expected got)
      (exit 1))))

(define (ce src) (jolt-pr-readable (jolt-eval-string src)))

(gambit-install-source-loader!
  '(("test/gambit/fixtures/source-load" ".jolt" ".cljc"))
  '("clojure.core" "jolt.ffi"))
(source-check "backend" ":gambit" (lambda () (ce "(jolt.backend-scheme.session/target)")))
(source-check "loaded dependency and reader feature" "42"
  (lambda () (ce "(require '[p1c.source-entry :as entry]) (entry/result)")))
(source-check "caller namespace" "user" chez-current-ns)
(source-check "reload refusal" "require option is unsupported on the gambit source loader: :reload"
  (lambda () (ce "(require 'p1c.source-entry :reload)")))
(source-check "alias-only missing source" "No source for namespace: p1c.absent"
  (lambda () (ce "(require '[p1c.absent :as-alias absent]) (require 'p1c.absent)")))
(source-check "surrogate pair str apply" "\"😀\""
  (lambda () (ce "(apply str [(char 55357) (char 56832)])")))
(source-check "long source literal through compiler" "9000"
  (lambda () (ce (string-append "(count \"" (make-string 9000 #\x) "\")"))))
(display "gambitsourceload: PASS — native source loading and compiler string emission\n")
