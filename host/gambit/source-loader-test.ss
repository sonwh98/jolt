#!/usr/bin/env gsi-script
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

(define (run-byte-rows suite)
  (let ((rows (call-with-input-file "test/gambit/unit.edn"
                (lambda (port) (jolt-read-string (gambit-read-all port))))))
    (for-each
      (lambda (row)
        (when (eq? (jolt-get row (keyword #f "suite")) suite)
          (let ((label (jolt-get row (keyword #f "label")))
                (source (jolt-get row (keyword #f "expr")))
                (expected (jolt-get row (keyword #f "expected"))))
            (source-check label expected (lambda () (ce source)))
            (printf "  ok     ~a\n" label))))
      (seq->list (jolt-seq rows)))))

(define roots '(("test/gambit/fixtures/source-load" ".jolt" ".cljc")))
(define args (cdr (command-line)))
(gambit-install-source-loader!
  (if (null? args)
      roots
      (cons (list (path-expand "src/jolt" (car args)) ".jolt") roots))
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
(run-byte-rows (keyword #f "core-bytes"))
(when (pair? args)
  (source-check "load upstream dao.host.bytes" "nil"
    (lambda () (ce "(require 'dao.host.bytes)")))
  (run-byte-rows (keyword #f "dao-host-bytes"))
  (display "gambitdaobytes: PASS — upstream Dao byte arrays on native gsi\n"))
(display "gambitsourceload: PASS — native source loading and compiler string emission\n")
