;; W10 — native compile / AOT cache witness (audit area 7).
;;
;; Rows decided:
;;   C1 compile-file to an explicit .go (manual §6.16.6: compile-file in
;;      (system base compile), "By convention, bytecode file names end in
;;      .go");
;;   C2 the compiled artifact LOADS and evaluates (load-compiled) — the
;;      AOT-cache purpose is real: the cache skips interpretation;
;;   C3 compiled-file-name maps into $XDG_CACHE_HOME/guile/ccache (the
;;      documented auto-compile cache dir);
;;   C4 the target-neutral profile maps: #:optimization-level 0..3 accepted
;;      ((optimize . N) row);
;;   C5 sa-make-boot-file: Guile has no boot-file concept — record the
;;      absence; the adapter MUST raise (contract-permitted degradation,
;;      jolt build surfaces it);
;;   C6 the auto-compile knob (%load-should-auto-compile?) is bound and
;;      settable (cache can be disabled silently).
;;
;; Negative controls:
;;   NC1 compiling a syntactically broken source RAISES (the compile step
;;      is real, not a copy);
;;   NC2 the ccache path must NOT exist before compiling and must exist
;;      after (causality, not a preexisting file).

(use-modules (system base compile)
             (srfi srfi-1))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(format #t "=== W10 native compile / AOT cache witness ===~%")

(define tmpdir (string-append "/tmp/w10-" (number->string (getpid))))
(mkdir tmpdir #o700)
(define src (string-append tmpdir "/testmod.scm"))
(call-with-output-file src
  (lambda (p)
    (format p "(define-module (w10 testmod) #:export (w10-val))~%")
    (format p "(define w10-val 4242)~%")))

;; ---- C1/C4 compile with the profile mapped -----------------------------------
(define go-explicit (string-append tmpdir "/testmod.go"))
(check "NC2 control: the explicit .go does not exist yet"
       (not (file-exists? go-explicit)))
(compile-file src #:output-file go-explicit #:optimization-level 2)
(check "C1 compile-file produced a nonempty .go"
       (and (file-exists? go-explicit)
            (> (stat:size (stat go-explicit)) 0)))
(compile-file src #:output-file (string-append tmpdir "/testmod-o0.go")
              #:optimization-level 0)
(check "C4 optimization-level 0 and 2 both accepted (profile mapping)"
       (file-exists? (string-append tmpdir "/testmod-o0.go")))

;; ---- C2 the compiled artifact loads -------------------------------------------
;; ADAPTER FACT: loading a file whose first form is (define-module ...)
;; SWITCHES the current module for the rest of the loading script — save
;; and restore it around load-compiled.
(define before (gc-stats))
(let ((cm (current-module)))
  (load-compiled go-explicit)
  (set-current-module cm))
(let ((m (resolve-interface '(w10 testmod))))
  (check "C2 load-compiled evaluates the compiled module (w10-val = 4242) \
with the current module restored"
         (and m (= (module-ref m 'w10-val) 4242))))

;; ---- C3 the auto-compile cache location ----------------------------------------
(define cached (compiled-file-name src))
(format #t "C3 compiled-file-name => ~s~%" cached)
(define xdg (or (getenv "XDG_CACHE_HOME")
                (string-append (getenv "HOME") "/.cache")))
(check "C3 compiled-file-name maps under the guile ccache dir"
       (string-prefix? (string-append xdg "/guile/ccache") cached))
(check "NC2b control: ccache entry absent before compile-file and created by \
compile-file"
       (let ((existed-before (file-exists? cached)))
         (compile-file src)
         (and (not existed-before) (file-exists? cached))))

;; ---- C5 boot-file absence --------------------------------------------------------
(let* ((m (resolve-interface '(system base compile)))
       (has-boot (module-bound? m 'make-boot-file)))
  (format #t "C5 make-boot-file bound in (system base compile): ~a~%"
          has-boot)
  (check "C5 no boot-file API exists — sa-make-boot-file must RAISE \
(contract-permitted degradation; AOT cache loads from source)"
         (not has-boot)))

;; ---- C6 auto-compile knob ---------------------------------------------------------
;; 3.0.11 spells the knob %load-should-auto-compile (no question mark); it
;; is #f here because the witnesses run under --no-auto-compile (which is
;; itself evidence the knob steers the cache).
(check "C6 %load-should-auto-compile is bound, reflects --no-auto-compile, \
and is settable"
       (let ((old %load-should-auto-compile))
         (set! %load-should-auto-compile #t)
         (let ((now %load-should-auto-compile))
           (set! %load-should-auto-compile old)
           (and (not old) now))))

;; ---- NC1 broken source must raise ---------------------------------------------------
(define broken (string-append tmpdir "/broken.scm"))
(call-with-output-file broken
  (lambda (p) (display "(define (f) ))))broken\n" p)))
(let ((r (false-if-exception
          (compile-file broken #:output-file
                        (string-append tmpdir "/broken.go")))))
  (format #t "NC1 compiling broken source => ~s~%" r)
  (check "NC1 control: compiling a broken source RAISES (compile is real)"
         (not r)))

(if (zero? fails)
    (format #t "W10-VERDICT: PASS (compile + AOT cache decided)~%")
    (format #t "W10-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
