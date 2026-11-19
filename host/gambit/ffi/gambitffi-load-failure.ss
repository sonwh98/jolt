;; gambitffi-load-failure.ss — the gambitffi-load-failure-smoke gate: missing vs
;; unloadable with the loader's reason preserved, scoped-before-global
;; isolation, duplicate-definers detection, repeat-load no-op.
;;
;; The unloadable candidate is built by the Makefile: libjoltffi-unloadable.dylib
;; is linked against libjoltffi-dep.dylib, and the DEPENDENCY is removed before
;; the gate runs — so the file is THERE but its dependency is not, the
;; present-but-unloadable case (jolt-lang/jolt#1127's reason preservation).
;;
;; Run via `make gambitffi-load-failure-smoke` (external watchdog, repo root).

(##include "ffi-harness.ss")

(printf "== missing vs unloadable, reason preserved ==\n")
(let ((missing (guard (e (#t (condition-message e)))
                 (sa-load-shared-object "/nonexistent/libjoltffi-nope.dylib")
                 "NO-RAISE"))
      (unloadable (guard (e (#t (condition-message e)))
                    (sa-load-shared-object "build/gambit-ffi/libjoltffi-unloadable.dylib")
                    "NO-RAISE")))
  (ffi-check-true "missing candidate raises" (not (string=? missing "NO-RAISE")))
  (ffi-check-true "unloadable candidate raises" (not (string=? unloadable "NO-RAISE")))
  ;; the loader's own reason rides the message
  (ffi-check-true "missing reason preserved (no such file)"
                  (string-contains missing "no such file"))
  (ffi-check-true "unloadable reason preserved (names the missing dependency)"
                  (string-contains unloadable "libjoltffi-dep.dylib"))
  (ffi-check-true "the two failures are distinguishable"
                  (not (string=? missing unloadable))))

(printf "== scoped-before-global isolation ==\n")
(ffi-check-true "fixture not loaded yet: scoped probe answers #f"
                (not (joltffi-dlsym-loaded "joltffi_fx_layout_version")))
(ffi-load-fixture!)
(ffi-check-true "after a scoped load, the scoped probe answers"
                (joltffi-dlsym-loaded "joltffi_fx_layout_version"))
;; RTLD_LOCAL: a scoped library's symbols are NOT in the global namespace
(let ((global-hit (guard (e (#t 0))
                    (joltffi-dlerror)
                    (joltffi-dlsym-global "joltffi_fx_layout_version")
                    (if (joltffi-dlerror) 0 1))))
  (ffi-check "a scoped library stays invisible to global resolution" global-hit 0))
;; ...and once loaded, the tier's own entry probe answers for it
(ffi-check-true "sa-foreign-entry? answers for the loaded fixture"
                (sa-foreign-entry? "joltffi_fx_layout_version"))

(printf "== repeat load is a no-op with the same handle ==\n")
(let ((h1 (joltffi-handle-of ffi-fixture-path))
      (h2 (begin (ffi-load-fixture!) (joltffi-handle-of ffi-fixture-path))))
  (ffi-check-true "repeat load registered exactly one handle"
                  (and h1 h2 (= h1 h2))))

(printf "== duplicate definers: two addresses, first declared resolves ==\n")
(ffi-load-fixture!)
(sa-load-shared-object ffi-fixture2-path)
(let ((defs (joltffi-definers "joltffi_fx_dup_symbol"))
      (a1 (joltffi-dlsym-loaded "joltffi_fx_dup_symbol")))
  (ffi-check "two distinct addresses across two declared libraries" (length defs) 2)
  (ffi-check-true "the addresses differ"
                  (not (= (cdar defs) (cdar (cdr defs)))))
  (ffi-check-true "the first declared library wins resolution"
                  (= a1 (cdar defs)))
  ;; the resolved value is the first library's behavior
  (ffi-check "first-declared symbol behaves like fixture 1"
             ((sa-foreign-procedure "joltffi_fx_dup_symbol" () int)) 111))

(ffi-gate-finish "gambitffi-load-failure-smoke")
