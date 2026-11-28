;; Each process loads one ordered manifest in its captured runtime module.
(define (%jolt-profile-load path)
  (if (char=? (string-ref path 0) #\@)
      (%jolt-load-guile (substring path 1))
      (%jolt-load-chez path)))

(define (%jolt-select-target!)
  ((var-deref "jolt.backend-scheme" "set-target!") (keyword #f "guile")))

(define (%jolt-reset-compiler!)
  ((var-deref "jolt.backend-scheme" "set-emit-unit!")
   ((var-deref "jolt.passes.types" "new-unit")))
  ((var-deref "jolt.backend-scheme" "set-prelude-mode!") #t)
  (%jolt-select-target!))

(if (string=? %jolt-profile "kernel")
    (begin
      ;; The shared string renderer can test a regex value. The kernel never
      ;; constructs one, so the predicate is false in that profile.
      (module-define! (jolt-boot-module) 'regex-t? (lambda (value) #f))
      (for-each %jolt-profile-load
                '("converters.ss" "@records-guile.ss" "java/records-interop.ss"
                  "natives-meta.ss" "lazy-bridge.ss")))
    (begin
      (for-each %jolt-profile-load
        '(
      "number-print.ss"
      "java/regex-translate.ss"
      "regex.ss"
      "atoms.ss"
      "refs.ss"
      "predicates.ss"
      "converters.ss"
      "transients.ss"
      "natives-seq.ss"
      "printing.ss"
      "natives-coll.ss"
      "natives-num.ss"
      "multimethods.ss"
      "java/jdk-interfaces.ss"
      "java/class-hierarchy.ss"
      "@records-guile.ss"
      "java/records-interop.ss"
      "natives-meta.ss"
      "java/host-class.ss"
      "dynamic-var-defaults.ss"
      "host-table.ss"
      "lazy-bridge.ss"
      "natives-transduce.ss"
      "vars.ss"
      "natives-misc.ss"
      "natives-format.ss"
      "extensions.ss"
      "ns.ss"
      "dyn-binding.ss"
      "natives-reader.ss"
      "reader.ss"
      "syntax-quote.ss"
      "host-contract.ss"
      "java/java-parse.ss"
      "@host-statics.ss"
      "java/math.ss"
      "java/class-model.ss"
      "java/string-builder.ss"
      "java/dot-forms.ss"
      "java/jutil-colls.ss"
      "java/tree-map.ss"
      "java/byte-buffer.ss"
      "float.ss"
      "surrogates.ss"))
      (set! rdr-features (cons "guile" rdr-features))
      (%jolt-load-guile "pre-seed.ss")
      (set-chez-ns! "clojure.core")
      (%jolt-load-guile "seed/prelude.ss")
      (%jolt-load-chez "post-prelude.ss")
      (%jolt-load-guile "host-vars.ss")
      (%jolt-load-guile "host-ffi.ss")
      (when (string=? %jolt-profile "repl")
        (degrade-core-vars! '("re-pattern" "re-matches" "re-find" "re-seq" "re-matcher" "re-groups")
                            "regex is unavailable in the repl profile"))
      (set-chez-ns! "user")
      (%jolt-load-guile "seed/image.ss")
      (%jolt-load-chez "compile-eval.ss")
      (%jolt-select-target!)))
