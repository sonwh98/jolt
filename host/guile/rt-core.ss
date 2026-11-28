#!no-fold-case
;; host/guile/rt-core.ss — kernel and compiler runtime for Guile 3.0.11.
;; Provides vars, namespaces, exceptions, invocation, printing, and kernel
;; registry hooks needed to load and test the shared host/chez concurrency modules.

(define (jolt-current-fiber) #f)
(define (jolt-fiber? _x) #f)
(define (jolt-fiber-carrier _f) #f)
(define (jolt-fiber-wait-turn! _spins) #f)

(define jolt-tick-sampling? #f)
(define (jolt-tick-join-sampling!) (void))
(define (jolt-tick-watch!) (void))
(define *txn* (make-thread-parameter #f))
(define (rdr-default-modes!) (void))
(define jolt-boot-output-port (current-output-port))
(define jolt-boot-error-port (current-error-port))
(define (console-output-port) jolt-boot-output-port)
(define (console-error-port) jolt-boot-error-port)

(set! %jolt-on-fork-thread jolt-mark-mt!)

;; ---- Virtual register indices ----------------------------------------------
(define jolt-vreg-site 2)
(define jolt-vreg-catch-line 3)
(define jolt-vreg-print-readably 4)
(define jolt-vreg-outer-site 12)

;; ---- Small string / arity helpers ------------------------------------------
(define (dotted-name? s)
  (and (string? s)
       (let ((n (string-length s)))
         (let loop ((i 0))
           (and (fx<? i n)
                (or (char=? (string-ref s i) #\.)
                    (loop (fx+ i 1))))))))

(define (last-dot s)
  (let loop ((i (fx- (string-length s) 1)))
    (cond ((fx<? i 0) s)
          ((char=? (string-ref s i) #\.) (substring s (fx+ i 1) (string-length s)))
          (else (loop (fx- i 1))))))

(define (jolt-str-join-sep strs sep)
  (cond
    ((null? strs) "")
    ((null? (cdr strs)) (car strs))
    (else
     (let loop ((xs (cdr strs)) (acc (list (car strs))))
       (if (null? xs)
           (apply string-append (reverse acc))
           (loop (cdr xs) (cons (car xs) (cons sep acc))))))))

(define (jolt-str-join strs) (jolt-str-join-sep strs " "))
(define (jolt-str-join-comma strs) (jolt-str-join-sep strs ", "))

(define (jvm-arity-count n) (number->string n))

(define (proc-accepts? p nargs)
  ;; Conservative check on Guile: let procedure-minimum-arity / exact arity inspect
  ;; when available via procedure-property or arity; fall back to #t.
  (or (not (procedure? p))
      (let ((req (car (procedure-minimum-arity p)))
            (opt (cadr (procedure-minimum-arity p)))
            (rest? (caddr (procedure-minimum-arity p))))
        (and (fx>=? nargs req)
             (or rest? (fx<=? nargs (fx+ req opt)))))))

(define (jolt-need-num x)
  (if (number? x) x (throw-jvm 'ClassCastException "expected number")))

(define (jolt-need-string x)
  (if (string? x) x (throw-jvm 'ClassCastException "expected string")))

;; ---- Exception / throw mechanism -------------------------------------------
(define-record-type jolt-ex-info-record
  (fields class-name message cause data (mutable error-offset))
  (nongenerative guile-jolt-ex-info-record-v1))

(define (jolt-throw-condition? x) (and (pair? x) (eq? (car x) 'jolt-throw)))
(define (jolt-throw-condition-value x) (cdr x))
(define (jolt-unwrap-throw x)
  (if (jolt-throw-condition? x) (jolt-throw-condition-value x) x))
(define (jolt-catch-complete!) (jolt-throw-sitep #f))
(define jolt-throw-sitep (make-thread-parameter #f))
(define (jolt-raise-thrown v)
  (jolt-throw-sitep (jolt-site-snapshot))
  (raise (cons 'jolt-throw v)))
(define (jolt-throw v) (jolt-raise-thrown v))

(define jvm-throwable-fqn-fallback (lambda (sym) (symbol->string sym)))
(define (jvm-throwable-fqn type)
  (cond
    ((symbol? type) (jvm-throwable-fqn-fallback type))
    ((string? type) type)
    (else "java.lang.RuntimeException")))

(define (jolt-host-throwable class-name msg . more)
  (let ((cause (if (null? more) jolt-nil (car more))))
    (make-jolt-ex-info-record class-name msg cause jolt-nil #f)))

(define (throw-jvm type msg)
  (jolt-throw (jolt-host-throwable (jvm-throwable-fqn type) msg)))

(define (jolt-ex-info msg data . more)
  (let ((cause (if (null? more) jolt-nil (car more))))
    (make-jolt-ex-info-record "clojure.lang.ExceptionInfo" msg cause data #f)))

(define (ex-info-map? x)
  (or (jolt-ex-info-record? x)
      (and (pmap? x)
           (not (jolt-nil? (pmap-get x (keyword "jolt" "type") jolt-nil)))
           (jolt= (pmap-get x (keyword "jolt" "type") jolt-nil)
                  (keyword "jolt" "ex-info")))))

(define (ex-info-class x)
  (if (jolt-ex-info-record? x)
      (jolt-ex-info-record-class-name x)
      (let ((c (pmap-get x (keyword "jolt" "class") jolt-nil)))
        (if (jolt-nil? c) "clojure.lang.ExceptionInfo" c))))

(define (exception-isa? child target)
  (or (string=? child target)
      (string=? target "Object")
      (string=? target "Throwable")
      (string=? target "Exception")
      (string=? target "RuntimeException")))

;; ---- Vars and namespaces ---------------------------------------------------
(define %current-ns-param (make-thread-parameter "user"))
(define (chez-current-ns) (%current-ns-param))

(define-record-type jolt-var-unbound (fields ns name) (nongenerative jolt-var-unbound-v1))
;; `defined?` distinguishes a genuinely interned var (def / declare / a native-op
;; cell) from a cell lazily materialised by a forward `var-deref` / `(var x)` on a
;; not-yet-defined name — `resolve` returns the cell iff defined?.
;; ns-unmap clears it. Avoids the (def x nil) edge of probing the root.
;; Mirrors host/chez/rt.ss var-cell-v4 field for field: shared chez files
;; (ns.ss meta/macro?, dyn-binding.ss dyn-bound?) read these accessors, so the
;; two hosts' cells must not drift (this one sat at v2 while chez moved twice).
(define-record-type var-cell
  (fields ns name (mutable root) (mutable defined?) (mutable meta) (mutable macro?)
          (mutable dyn-bound?) (mutable dynamic?))
  (nongenerative var-cell-v5))
(define var-table (make-hashtable string-hash string=?))
;; The whole-table snapshots host-contract.ss's completion scan reads (mirrors
;; host/chez/rt.ss: a locked copy, iterated by the caller outside the lock).
(define var-table-mu (make-mutex))
;; ns -> hashtable(name -> cell): the per-namespace index of var-table that
;; ns.ss's refer / ns-publics / ns-map / all-ns answer from (see host/chez/rt.ss
;; ns-cells-index). Kept in lockstep with var-table at both insert sites below,
;; exactly as Chez does — the shared ns.ss reads it, so without it every
;; namespace looked empty here.
(define ns-cells-index (make-hashtable string-hash string=?))
(define (ns-cells-add! c)                ; caller holds var-table-mu
  (let* ((ns (var-cell-ns c))
         (b (or (hashtable-ref ns-cells-index ns #f)
                (let ((b (make-hashtable string-hash string=?)))
                  (hashtable-set! ns-cells-index ns b)
                  b))))
    (hashtable-set! b (var-cell-name c) c)))
(define (ns-cells-list ns)
  (jolt-with-mutex var-table-mu
    (let ((b (hashtable-ref ns-cells-index ns #f)))
      (if b (vector->list (hashtable-values b)) '()))))
(define (ns-index-names)
  (jolt-with-mutex var-table-mu (hashtable-keys ns-cells-index)))
(define (rebuild-ns-cells-index!)
  (jolt-with-mutex var-table-mu
    (hashtable-clear! ns-cells-index)
    (vector-for-each ns-cells-add! (hashtable-values var-table))))
(define (var-table-cells) (jolt-with-mutex var-table-mu (hashtable-values var-table)))
(define (var-table-entries)
  (jolt-with-mutex var-table-mu
    (let-values (((ks vs) (hashtable-entries var-table))) (cons ks vs))))
(define (jolt-var ns name)
  (let ((key (string-append ns "/" name)))
    (sa-shared-intern var-table-mu
      (hashtable-ref var-table key #f)
      (let ((cell (make-var-cell ns name (make-jolt-var-unbound ns name)
                                 #f #f #f #f #f)))
        (hashtable-set! var-table key cell)
        (ns-cells-add! cell)
        cell))))
(define (var-cell-lookup ns name)
  (sa-shared-read var-table-mu
    (hashtable-ref var-table (string-append ns "/" name) #f)))
(define (var-deref ns name) (var-cell-root (jolt-var ns name)))
;; def-var! / declare-var! return the VAR CELL, not the value — Clojure's `def`
;; evaluates to #'ns/name (a first-class var), so (var? (def x 1)) is true and
;; (pr-str (def x 1)) is "#'ns/x". The prelude's def-var! forms discard the
;; return, so this is transparent there.
;; proc -> (ns . name) for the var it was def'd into, so (class a-fn) can report a
;; JVM-style class name and clojure.spec.alpha's fn-sym can recover the symbol of a
;; bare-fn predicate. Weak so GC'd fns drop out. Last def of a given proc wins.
(define proc-name-tbl (make-weak-eq-hashtable))
;; The READS take the table's mutex through proc-name-of, as on Chez (rt.ss):
;; seq.ss prints a fn's name with it and host-class.ss's class arm reads it for
;; (class a-fn) — both shared files, both unbound here until this mirror.
(define proc-name-mu (make-mutex))
(define (proc-name-of v) (jolt-with-mutex proc-name-mu (hashtable-ref proc-name-tbl v #f)))
(define var-redefined-set (make-hashtable string-hash string=?))
(define (var-redefined? ns name)
  (jolt-with-mutex var-table-mu
    (hashtable-contains? var-redefined-set (string-append ns "/" name))))
;; host-contract.ss (shared) calls this from hc-runtime-image-booted!; no boot
;; here reaches that seam, so it clears nothing that matters.
(define (var-redefined-clear!)
  (jolt-with-mutex var-table-mu (hashtable-clear! var-redefined-set)))
(define (def-var! ns name v)
  ;; first def of a given proc wins, so an alias like (def inc' inc) — which binds
  ;; the SAME proc to a second var — doesn't rename inc.
  (when (procedure? v)
    (jolt-with-mutex proc-name-mu
      (unless (hashtable-contains? proc-name-tbl v)
        (hashtable-set! proc-name-tbl v (cons ns name)))))
  (jolt-with-mutex var-table-mu (hashtable-set! ns-has-vars-set ns #t))
  (let ((c (jolt-var ns name)))
    ;; see host/chez/rt.ss def-var! -- a var defined more than once with a value
    ;; may not have its body spliced (jolt-rtjm). (declare x) emits declare-var!,
    ;; so a forward declaration is not a redefinition.
    (unless (jolt-var-unbound? (var-cell-root c))
      (jolt-with-mutex var-table-mu
        (hashtable-set! var-redefined-set (string-append ns "/" name) #t)))
    (var-root-set! c v) (var-cell-defined?-set! c #t) c))
;; Linked vars — see host/chez/rt.ss var-root-set!. The Gambit seed is minted
;; var-routed (gen-seed.ss sets no mint flags), so nothing links here yet; the
;; funnel is mirrored so a def-var-linked! form loads if one ever arrives.
;; One object per literal site across spliced copies (chez rt.ss jolt-site-const).
(define site-const-tbl (make-hashtable string-hash string=?))
(define site-const-mu (make-mutex))
(define (jolt-site-const id make)
  (or (sa-shared-read site-const-mu (hashtable-ref site-const-tbl id #f))
      (let ((v (make)))
        (sa-shared-intern site-const-mu
          (hashtable-ref site-const-tbl id #f)
          (begin (hashtable-set! site-const-tbl id v) v)))))
(define var-linked-tbl (make-eq-hashtable))
(define var-linked-mu (make-mutex))      ; ns.ss's remove-ns sweep takes it
;; the root-write hook host-contract.ss installs (chez rt.ss var-root-write-hook)
(define var-root-write-hook #f)
(define (set-var-root-write-hook! f) (set! var-root-write-hook f))
(define (var-root-set! c v)
  (if var-root-write-hook (var-root-write-hook c))
  (var-cell-root-set! c v)
  (let ((l (sa-shared-read var-linked-mu (hashtable-ref var-linked-tbl c #f))))
    (when l ((cdr l) v))))
(define (var-linked-symbol c)
  (let ((l (sa-shared-read var-linked-mu (hashtable-ref var-linked-tbl c #f))))
    (and l (car l))))
(define (def-var-linked! ns name sym v setter m)
  (let ((c (if m (def-var-with-meta! ns name v m) (def-var-plain! ns name v))))
    (jolt-with-mutex var-linked-mu (hashtable-set! var-linked-tbl c (cons sym setter)))
    c))
;; A def whose form declared NO metadata — see host/chez/rt.ss def-var-plain!.
(define (def-var-plain! ns name v)
  (let ((c (def-var! ns name v))) (var-cell-dynamic?-set! c #f) c))
;; Value-position comparison references compile to the seq.ss chain singletons
;; (jolt-lt/gt/le/ge), not to the clojure.core var roots — the roots were later
;; re-bound by the checked numeric layer, so def-var! never saw these procs.
;; Register them so a stored comparator like (sorted-map-by >) travels as a
;; fn-ref (by name) like any other named core fn.
(hashtable-set! proc-name-tbl jolt-lt (cons "clojure.core" "<"))
(hashtable-set! proc-name-tbl jolt-gt (cons "clojure.core" ">"))
(hashtable-set! proc-name-tbl jolt-le (cons "clojure.core" "<="))
(hashtable-set! proc-name-tbl jolt-ge (cons "clojure.core" ">="))
;; Set of ns-name strings that have at least one var — makes ns-has-vars? O(1)
;; instead of scanning the entire var-table per require-miss. Updated in def-var!
;; (and wherever vars are removed, though removal is rare).
(define ns-has-vars-set (make-hashtable string-hash string=?))
;; jolt.host/throwable — build a typed throwable a library can throw so (class …),
;; instance?, .getMessage and ex-message all reflect the named JVM class (e.g. an
;; http client throwing java.net.ConnectException). Strictly better than a
;; hand-rolled :jolt/ex-info table, which carries only the class.
(def-var! "jolt.host" "throwable" jolt-host-throwable)
;; jolt.host/available-processors — the host's usable CPU count (see above). The
;; JVM spelling of the same question, Runtime.availableProcessors, is mapped in
;; the java layer (java/process.ss); clojure.core reaches it through here.
(def-var! "jolt.host" "available-processors" current-processor-count)
;; jolt.host/getenv — the process environment. Mirrors rt.ss, and for the reason
;; given there: the compiler image reads it in a top-level def as it LOADS, so it
;; has to exist before the seed (jolt#879). Gambit's NATIVE getenv raises on an
;; unset name where Chez's returns #f, but prelude-shims.ss already Chez-shapes
;; the bare one-argument form (its getenv CONTRACT note) by catching that raise,
;; which is why the bare (getenv "JOLT_VERSION") above works — so either spelling
;; would do here. The default is passed explicitly rather than leaning on the
;; shim's guard, which catches EVERY error and so cannot tell "unset" from a real
;; failure; that is the one distinction a var handed to user code should keep.
(def-var! "jolt.host" "getenv" (lambda (n) (let ((v (getenv n))) (if v v jolt-nil))))

;; SKIPPED on the gambit target: the telemetry primitives region (wall/mono
;; clocks, sa-stats counters, thread-id, machine-type/scheme-version) — Chez
;; time objects and Chez-shipped statistics; no manifest consumer needs them
;; (see port-log). jolt.host/throwable + available-processors above are kept.

;; var def-time metadata: the :def emit passes the def's reader meta
;; (^:private / ^Type tag / docstring -> {:doc}) here, stored in an eq side-table
;; keyed by the cell. jolt-meta (natives-meta.ss) merges it onto {:ns :name},
;; which it derives from the cell — so EVERY var (plain def, native-op, declare)
;; reports {:ns :name} like Clojure, with the user meta layered on when present.
;; Meta, the macro flag and the dynamic flag live IN the cell (var-cell-v5
;; fields), matching chez: the shared files read and write the fields directly
;; (dyn-binding.ss's dynamic check reads dynamic?, ns.ss's alter-meta! sync
;; writes macro?), so the
;; eq-side-tables this file used to keep were invisible to them — a var defined
;; ^:dynamic through the seed still threw "non-dynamic" at the first binding.
(define jolt-kw-var-ns (keyword #f "ns"))
(define jolt-kw-var-name (keyword #f "name"))
(define jolt-kw-var-macro (keyword #f "macro"))
(define (def-var-with-meta! ns name v m)
  (let ((c (def-var! ns name v)))
    (var-cell-meta-set! c m)
    (var-cell-dynamic?-set! c (var-meta-dynamic? m))
    c))
(define (var-meta-dynamic? m)
  (and m (not (jolt-nil? m))
       (jolt-truthy? (jolt-get m (keyword #f "dynamic")))))
;; A runtime-defined DYNAMIC var (the *earmuffed* core vars): tagged :dynamic so
;; push-thread-bindings accepts it — with no meta entry a var is non-dynamic and
;; binding throws, like the JVM.
(define (def-dynvar! ns name v)
  (def-var-with-meta! ns name v
    (jolt-hash-map (keyword #f "dynamic") #t)))
;; Attach meta to an already-interned var (the declare/no-init emission path:
;; (def ^:dynamic *x*) must be bindable before its root is set).
(define (set-var-meta! ns name m)
  (let ((c (jolt-var ns name)))
    (var-cell-meta-set! c m)
    (var-cell-dynamic?-set! c (var-meta-dynamic? m))))
;; runtime-macro flag: a var whose root holds a macro expander fn, so the
;; analyzer's form-macro?/form-expand-1 (host-contract.ss) expand it. The
;; prelude emits each core/stdlib defmacro as a def-var! of its expander
;; followed by (mark-macro! ns name). The flag is the cell's macro? FIELD —
;; shared ns.ss (alter-meta! :macro sync) writes it directly, so a side table
;; here would miss those writes. The field survives a later (def name ...) that
;; replaces the expander but keeps the same cell, matching Clojure.
(define (mark-macro! ns name)
  (let ((c (jolt-var ns name))) (var-cell-macro?-set! c #t) c))
(define (macro-var? cell) (and cell (var-cell-macro? cell) #t))
;; declare / (def name) with no init: reserve the cell ONLY if absent. An
;; existing root is left intact — Clojure's (def x) with no init does not clobber
;; a prior binding (do (def x 7) (def x) x) => 7. Returns the cell either way.
(define (var-cell-deref c)
  (let ((root (var-cell-root c)))
    (if (jolt-var-unbound? root)
        (throw-jvm 'IllegalStateException
                   (string-append "Attempting to call unbound fn: #'"
                                  (var-cell-ns c) "/" (var-cell-name c)))
        root)))

(define (declare-var! ns name)
  (let ((cell (jolt-var ns name)))
    (var-cell-defined?-set! cell #t)
    cell))

(define (chez-resolve-alias _here _qns) #f)
(define (chez-resolve-refer _here _sym) #f)

;; ---- Invocation & seams ----------------------------------------------------
(define jolt-invoke-prefix-arms '())
(define (register-invoke-prefix-arm! pred handler)
  (set! jolt-invoke-prefix-arms (cons (cons pred handler) jolt-invoke-prefix-arms)))

(define (jolt-invoke f . args)
  (cond
    ((procedure? f) (apply f args))
    ((keyword? f)
     (let ((n (length args)))
       (cond
         ((fx=? n 1) (jolt-get (car args) f jolt-nil))
         ((fx=? n 2) (jolt-get (car args) f (cadr args)))
         (else (throw-jvm 'ArityException (string-append "Wrong number of args (" (number->string n) ")"))))))
    ((pmap? f)
     (let ((n (length args)))
       (cond
         ((fx=? n 1) (pmap-get f (car args) jolt-nil))
         ((fx=? n 2) (pmap-get f (car args) (cadr args)))
         (else (throw-jvm 'ArityException (string-append "Wrong number of args (" (number->string n) ")"))))))
    ((pset? f)
     (if (fx=? (length args) 1)
         (if (pset-contains? f (car args)) (car args) jolt-nil)
         (throw-jvm 'ArityException "Wrong number of args")))
    ((pvec? f)
     (if (fx=? (length args) 1)
         (pvec-nth! f (car args))
         (throw-jvm 'ArityException "Wrong number of args")))
    ((var-cell? f) (apply jolt-invoke (var-cell-deref f) args))
    (else
     (let loop ((as jolt-invoke-prefix-arms))
       (cond
         ((null? as) (throw-jvm 'ClassCastException "value is not IFn"))
         (((caar as) f) (apply (cdar as) f args))
         (else (loop (cdr as))))))))

(define (jolt-invoke0 f) (jolt-invoke f))
(define (jolt-invoke1 f a) (if (procedure? f) (f a) (jolt-invoke f a)))
(define (jolt-invoke2 f a b) (if (procedure? f) (f a b) (jolt-invoke f a b)))
(define (jolt-invoke3 f a b c) (if (procedure? f) (f a b c) (jolt-invoke f a b c)))

(define (seam-invoke1 f x) (jolt-invoke1 f x))
(define (seam-invoke2 f x y) (jolt-invoke2 f x y))

;; ---- Minimal collection / string / printing / registry arms ----------------
(define jolt-map-pred-arms '())
(define (register-map-pred-arm! pred)
  (set! jolt-map-pred-arms (cons pred jolt-map-pred-arms)))

(define jolt-meta-fallback (lambda (_x) jolt-nil))
(define jolt-with-meta-fallback (lambda (x _m) x))
(define (jolt-meta x) (jolt-meta-fallback x))
(define (jolt-with-meta x m) (jolt-with-meta-fallback x m))

(define jolt-pr-str-arms '())
(define jolt-pr-readable-arms '())
(define (register-pr-str-arm! pred render)
  (set! jolt-pr-str-arms (cons (cons pred render) jolt-pr-str-arms)))
(define (register-pr-readable-arm! pred render)
  (set! jolt-pr-readable-arms (cons (cons pred render) jolt-pr-readable-arms)))
(define (register-pr-arm! pred render)
  (register-pr-str-arm! pred render)
  (register-pr-readable-arm! pred render))

(define (register-str-render! pred render)
  ;; Used by records-dispatch.ss / multimethods / lazy-bridge.
  (register-pr-str-arm! pred render))

(define (jolt-object-content x) (format #f "~s" x))
(define (jolt-pr-readable?)
  (let ((cell (var-cell-lookup "clojure.core" "*print-readably*")))
    (or (not cell) (jolt-truthy? (jolt-var-get cell)))))
(define (jolt-bigint-print? value)
  (and (exact-integer? value)
       (or (< value -9223372036854775808) (> value 9223372036854775807))))

(define (jolt-pr-str/readable x readable?)
  (cond
    ((jolt-nil? x) "nil")
    ((boolean? x) (if x "true" "false"))
    ((string? x) (if readable? (format #f "~s" x) x))
    ((keyword? x)
     (if (keyword-t-ns x)
         (string-append ":" (keyword-t-ns x) "/" (keyword-t-name x))
         (string-append ":" (keyword-t-name x))))
    ((jolt-symbol? x)
     (if (symbol-t-ns x)
         (string-append (symbol-t-ns x) "/" (symbol-t-name x))
         (symbol-t-name x)))
    ((number? x) (number->string x))
    (else
     (let loop ((as (if readable? jolt-pr-readable-arms jolt-pr-str-arms)))
       (cond ((null? as) (format #f "~s" x))
             (((caar as) x) ((cdar as) x))
             (else (loop (cdr as))))))))

(define str-tostring-hook #f)
(define (set-str-tostring-hook! f) (set! str-tostring-hook f))

(define (jolt-pr-str x) (jolt-pr-str/readable x #f))
(define (jolt-pr-readable x) (jolt-pr-str/readable x #t))
(define (jolt-str-render-one x) (jolt-final-str x))
(define (jolt-final-str x)
  (cond
    ((jolt-nil? x) "")
    ((and str-tostring-hook (or (jrec? x) (jreify? x)))
     (or (str-tostring-hook x) (jolt-pr-str x)))
    (else (jolt-pr-str x))))
(define (jolt-str . xs) (apply string-append (map jolt-final-str xs)))
(define (jolt-seq? x) (cseq? x))
;; ---- Hooks expected by class-hierarchy / records / protocols / interop -----
(define class-ctors-tbl (make-hashtable string-hash string=?))
(define class-ctors-mu (make-mutex))
(define (class-ctor-set! tag ctor)
  (jolt-with-mutex class-ctors-mu (hashtable-set! class-ctors-tbl tag ctor)))

(define (jolt-register-source! . _args) #f)
(define (image-register-fn-form! . _args) #f)
(define (image-fn-form-maker! . _args) #f)
(define (image-fn-form-src s) s)
(define (register-code-value! . _args) #f)
(define (register-proc-name! v . _args) v)
(define (code-value? _x) #f)

(define (lazy-shims-provides? _nm) #f)
(define (chez-infer-registry-bump!) (void))
(define jolt-class-arms '())
(define jolt-class-name-last (sa-site-cell-make (cons #f #f)))
(define (register-class-arm! pred handler)
  (set! jolt-class-arms (cons (cons pred handler) jolt-class-arms))
  (memory-order-release)
  (sa-site-cell-set! jolt-class-name-last (cons #f #f))
  (sa-epoch-bump! instance-arms-epoch-cell instance-arms-epoch))

(define (jolt-class-base x)
  (cond
    ((jolt-nil? x) jolt-nil)
    ((boolean? x) "java.lang.Boolean")
    ((and (number? x) (flonum? x)) "java.lang.Double")
    ((and (number? x) (exact? x) (integer? x))
     (if (jolt-bigint-print? x) "clojure.lang.BigInt" "java.lang.Long"))
    ((and (number? x) (exact? x) (rational? x)) "clojure.lang.Ratio")
    ((number? x) "java.lang.Number")
    ((string? x) "java.lang.String")
    ((keyword? x) "clojure.lang.Keyword")
    ((symbol-t? x) "clojure.lang.Symbol")
    ((char? x) "java.lang.Character")
    ((procedure? x) "clojure.lang.AFunction$fn__0")
    ((jolt-map-entry? x) "clojure.lang.MapEntry")
    ((jolt-subvec-view? x) "clojure.lang.APersistentVector$SubVector")
    ((pvec? x) "clojure.lang.PersistentVector")
    ((pset? x) "clojure.lang.PersistentHashSet")
    ((pmap? x)
     (if (pmap-array? x)
         "clojure.lang.PersistentArrayMap"
         "clojure.lang.PersistentHashMap"))
    ((jolt-lazyseq? x) "clojure.lang.LazySeq")
    ((empty-list-t? x) "clojure.lang.PersistentList$EmptyList")
    ((cseq? x) "clojure.lang.PersistentList")
    (else "java.lang.Object")))

(define (class-fast-name x)
  (cond
    ((or (jolt-nil? x) (boolean? x) (number? x) (string? x) (keyword? x)
         (symbol-t? x) (char? x) (pvec? x) (pmap? x) (pset? x) (cseq? x)
         (empty-list-t? x) (jolt-lazyseq? x))
     (jolt-class-base x))
    ((jrec? x) (jrec-tag x))
    ((and (jreify? x) (not (jreify-delegate x)))
     (or (reify-class-name x) "clojure.lang.IObj$reify__0"))
    (else #f)))

(define (jolt-class-name x)
  (or (class-fast-name x)
      (if (jolt-nil? x) "nil" "java.lang.Object")))
(define (class-munge-name s) s)
(define (user-instance-checks-empty?) #t)
(define (root-object-type? ts)
  (and (symbol-t? ts)
       (or (string=? (symbol-t-name ts) "java.lang.Object")
           (string=? (symbol-t-name ts) "Object"))))
(define (ref-kind-extra-hook _x) #f)
(define (jolt-atom? _x) #f)
(define (jolt-atom-val _x) jolt-nil)
(define (jolt-ref? _x) #f)
(define (jolt-ref-val _x) jolt-nil)
(define-record-type jolt-delay
  (fields (mutable state))
  (nongenerative guile-jolt-delay-v1))
(define (jolt-future? _x) #f)
(define (jolt-promise? _x) #f)
(define (jolt-agent? _x) #f)
(define (jolt-queue? _x) #f)
(define (jolt-file? _x) #f)
(define (jinst? _x) #f)
(define (jts? _x) #f)
(define (jfloat? _x) #f)
(define (jclass? _x) #f)
(define (jclass-name _x) #f)
(define (jolt-array? _x) #f)
(define (jolt-array-kind _x) #f)
(define (jolt-regex? _x) #f)
(define (jolt-map? x)
  (or (pmap? x)
      (exists (lambda (p) (p x)) jolt-map-pred-arms)))

(define (jolt-conc-realized? x)
  (and (jolt-delay? x) (pair? (jolt-delay-state x))))
(define (jiterator? _x) #f)
(define (jolt-transient? _x) #f)
(define (t-contains? _t _k) #f)
(define (t-count _t) 0)
(define (deref-print-to! _port _r _state _readable?) (void))
(define (jrec-assoc-entries r _ext) r)

;; Seed clojure.core/global-hierarchy and isa?/parents stubs so multimethods and
;; core protocol helpers can run before the full clojure.core prelude loads in 3b.
(def-var! "clojure.core" "global-hierarchy" (jolt-hash-map))
(def-var! "clojure.core" "parents"
  (case-lambda
    ((tag) (let ((h (var-deref "clojure.core" "global-hierarchy")))
             (jolt-get (jolt-get h (keyword #f "parents") jolt-nil) tag jolt-nil)))
    ((h tag) (jolt-get (jolt-get h (keyword #f "parents") jolt-nil) tag jolt-nil))))
(def-var! "clojure.core" "isa?"
  (letrec ((isa2 (lambda (h child parent)
                   (or (jolt= child parent)
                       (let ((ps (jolt-get (jolt-get h (keyword #f "parents") jolt-nil) child jolt-nil)))
                         (and (not (jolt-nil? ps))
                              (or (jolt-truthy? (jolt-get ps parent #f))
                                  (let loop ((s (jolt-seq ps)))
                                    (and (not (jolt-nil? s))
                                         (or (isa2 h (seq-first s) parent)
                                             (loop (jolt-seq (seq-more s)))))))))))))
    (case-lambda
      ((child parent) (isa2 (var-deref "clojure.core" "global-hierarchy") child parent))
      ((h child parent) (isa2 h child parent)))))

(define pr-fast-probes
  (list 0 (expt 2 70) 1/2 1.5 "s" jolt-nil #t #f #\a
        (keyword #f "k") (jolt-symbol #f "s")))
;; Shares reject-fast-type-claim! (values.ss) with the eq and hash registries,
;; which enforce the same invariant over their own — narrower — fast paths.
(define (pr-arm-reject-fast-type! who pred)
  (reject-fast-type-claim! who pred pr-fast-probes
                           "the printer fast path (see pr-fast-type? in rt.ss)"))

(define (jolt-version-string)
  (or (sa-baked-global 'jolt-baked-version-early)
      (let ((version (getenv "JOLT_VERSION")))
        (and version (not (string-null? version)) version))
      "dev"))

(define (jolt-host-call method target . args)
  (record-method-dispatch target method (apply jolt-vector args)))

(define (jolt-inc x) (+ (jolt-need-num x) 1))

(define (jolt-dec x) (- (jolt-need-num x) 1))
;; longCast/doubleCast coerce a primitive-hinted parameter or return: ^long
;; truncates a flonum toward zero and passes an exact integer through, ^double
;; widens any number. The hint is a promise the body's fx*/fl* ops rely on, so a
;; value outside the tower is the JVM's cast failure (ClassCastException, or NPE
;; for nil) — a raw host error would escape with no class for a catch to select.
;; A ^long is a 64-bit value; a Chez fixnum is only 61-bit, so a value that
;; overflows the fixnum range (a full-width long, e.g. from unchecked / wrapping
;; arithmetic) passes through as an exact integer rather than erroring. fx ops in
;; the body still require fixnums (they raise on a bignum), but generic /
;; unchecked-* ops handle it.

(define (jolt->fx x)
  (cond ((fixnum? x) x)
        ((and (number? x) (exact? x) (integer? x)) x)
        ((flonum? x) (exact (truncate x)))
        ((rational? x) (exact (truncate x)))
        (else (jolt-num-cast-throw x))))

(define (jolt->fl x)
  (cond ((flonum? x) x)
        ((number? x) (exact->inexact x))
        ((jfloat? x) (jfloat-fl x))
        (else (jolt-num-cast-throw x))))
;; jolt `not`: only nil and false are falsey.
;; Mirrors rt.ss's spliced jolt-not (see values.ss jolt-nil? for why these are
;; macros); rt-core.ss is the Gambit port of rt.ss's kernel, so the shape has to
;; match or the Gambit host keeps paying the call.

(define (jolt-not-fn x) (if (jolt-truthy? x) #f #t))

(define-syntax jolt-not
  (syntax-rules ()
    ((_ e) (if (jolt-truthy? e) #f #t))
    ((_ e ...) (jolt-not-fn e ...))))

(define jolt-form-ordinal (make-parameter #f))
(define (var-def-ordinal ns name) 0)
(define (var-def-visible-in-outer-frames? ns name) #t)

;; A file path the way a report shows it (compile-eval.ss's diagnostics);
;; mirrors host/chez/rt.ss jolt-display-path.
;; Where the source a position NAMES can be opened (host/chez/rt.ss). Gambit has
;; no loader to install the classpath lookup, so a name is its own location.
(define jolt-source-location (lambda (name) name))
(define (set-jolt-source-location! proc) (set! jolt-source-location proc))

(define (jolt-display-path name)
  (define p (if (string? name) (jolt-source-location name) name))
  (define (under? p dir)
    (and (string? dir) (> (string-length dir) 0)
         (> (string-length p) (string-length dir))
         (string=? (substring p 0 (string-length dir)) dir)
         (char=? (string-ref p (string-length dir)) #\/)))
  (define (strip-dot p)
    (let loop ((p p))
      (if (and (> (string-length p) 2) (string=? (substring p 0 2) "./"))
          (loop (substring p 2 (string-length p)))
          p)))
  (cond
    ((not (string? p)) p)
    ((and (> (string-length p) 0) (char=? (string-ref p 0) #\/))
     (let ((cwd (or (getenv "JOLT_PWD") (guard (_ (#t #f)) (getcwd))))
           (home (getenv "HOME")))
       (cond ((under? p cwd) (string-append "./" (substring p (+ 1 (string-length cwd)) (string-length p))))
             ((under? p home) (string-append "~/" (substring p (+ 1 (string-length home)) (string-length p))))
             (else p))))
    ((and (> (string-length p) 1) (string=? (substring p 0 2) "./"))
     (string-append "./" (strip-dot p)))
    (else p)))


(define %monitor-tbl (make-weak-eq-hashtable))
(define %monitor-mu (make-mutex))
(define (object-monitor obj)
  (jolt-with-mutex %monitor-mu
    (or (hashtable-ref %monitor-tbl obj #f)
        (let ((m ((@ (ice-9 threads) make-mutex) 'recursive)))
          (hashtable-set! %monitor-tbl obj m)
          m))))
(define (jolt-call-with-monitor m thunk) (with-mutex m (thunk)))
(define (jolt-with-monitor obj thunk) (jolt-call-with-monitor (object-monitor obj) thunk))
(def-var! "jolt.host" "with-monitor" jolt-with-monitor)

;; This profile walks the print arms directly and has no class-based cache.
(define (print-arms-invalidate!) (void))
(define (print-arms-for kind arms value) arms)

;; The kernel has no native future objects. Public construction is refused.
(define (jolt-native-future-done? value) #f)
(define (jolt-native-future-cancelled? value) #f)

(define (jolt-conc-unsupported who)
  (lambda _ (throw-jvm 'UnsupportedOperationException
    (string-append (symbol->string who) ": futures/promises/agents are unsupported in the Guile profile"))))
(define (jolt-any-future? x) #f)
(define (jolt-java-future? x) #f)
(define jolt-agent-new (jolt-conc-unsupported 'agent))
(define jolt-agent-send (jolt-conc-unsupported 'send))
(define jolt-agent-send-off (jolt-conc-unsupported 'send-off))
(define jolt-agent-await (jolt-conc-unsupported 'await))
(define jolt-agent-error (jolt-conc-unsupported 'agent-error))
(define jolt-agent-restart (jolt-conc-unsupported 'restart-agent))
(define jolt-promise-new (jolt-conc-unsupported 'promise))
(define jolt-deliver (jolt-conc-unsupported 'deliver))


(define (jolt-alength a)
  (if (jolt-nil? a) (error 'alength "null") (jolt-count a)))
;; the hinted alength the numeric pass emits (natives-array.ss)
(define (jolt-valength a) (jolt-alength a))
;; natives-array.ss's typed reference array, for the shared interop files that
;; answer one (records-interop, dot-forms, class-model). No arrays on this
;; target, so it is the vector those answered before.
(define (jolt-ref-array xs cls)
  (apply jolt-vector (if (list? xs) xs (seq->list xs))))
;; Every value printed this way carries its identity hash, as the JVM's
;; print-object writes (System/identityHashCode o) for any object (jolt-28we).
(define (jolt-object-repr x readable?)
  (let* ((cls (guard (e (#t #f)) (jolt-class-name x)))
         (content (guard (e (#t #f)) (jolt-object-content x)))
         (head (and (string? cls)
                    (string-append "#object[" cls " 0x" (jolt-identity-hex x)))))
    (cond ((not head) (format "~a" x))
          ((not (string? content)) (string-append head "]"))
          ((and readable? (jolt-pr-readable?))
           (string-append head " \"" (jolt-str-escape content) "\"]"))
          (else (string-append head " " content "]")))))

(define jolt-trace-on? #f)
;; Per-thread trace state lives in Chez VIRTUAL REGISTERS, not thread parameters:
;; a thread-parameter WRITE costs ~32ns against ~1ns for a virtual-register write
;; (measured, Chez 10.4 arm64), and jolt-site! sits on the hot path. Reads are
;; ~2.4ns vs ~3.3ns, a smaller but free win.
;;
;; --- Clojure fn identity ----------------------------------------------------
;; The back end gives every non-capturing lambda one free variable to capture so
;; two evaluations of (fn [x] x) are two objects (see host/chez/rt.ss for why —
;; Chez shares one static closure otherwise). The emission is not target-gated,
;; so the two names it references must be bound here too; both are ASSIGNED so
;; no compiler can fold the capture away, exactly as on Chez.

(define jolt-fn-identity-seed 0)

(define jolt-fn-identity-probe #f)
;; A ^:once fn's box of captures (backend emit-fn), as rt.ss.

(define jolt-once-tag (list 'jolt-once))

(define (jolt-once-clear! env)
  (let loop ((i (fx- (vector-length env) 1)))
    (when (fx>? i 0) (vector-set! env i jolt-nil) (loop (fx- i 1)))))
(set! jolt-fn-identity-seed 1)
(set! jolt-fn-identity-probe #f)

;; Virtual registers are a fixed global resource: (virtual-register-count) slots for
;; the whole process (16 on every platform jolt targets). jolt claims three, allocated
;; here so the assignment is in one place; nothing else in the runtime uses them.
;; A freshly forked thread starts every slot at fixnum 0, NOT #f, so "unset" means
;; fixnum 0 (the site slots hold a site pair or 0). Slots 0 and 1 are FREE since
;; R3 (jolt-230w) removed the R1 ring/mark vregs — the tail marks live on the
;; continuation, not in a vreg — so new virtual-register users should claim them
;; before renumbering anything. The surviving slots keep their R2 numbers.

(define pr-readably-cell #f)

(define (jolt-trace-enable!) (set! jolt-trace-on? #t))

;; TAIL call emissions store their static ('ns/fn' . line) pair here right
;; before the call (sited-tail-call / the :throw case), and a non-tail call puts
;; it back when it returns (backend_scheme site-restore), so a pair in the slot is a
;; tail call whose chain is still running. Consumers read the THROW-TIME snapshot
;; (jolt-throw-sitep), and the reporter still validates it against the callsite
;; table before splicing: code compiled untraced (the seed) restores nothing.

(define (jolt-site! p) (set-virtual-register! jolt-vreg-site p))
;; A non-tail call moves the slot's pair to jolt-vreg-outer-site and clears the
;; slot while it runs (backend_scheme site-restore); a throw keeps the slot's
;; pair, else that outer pair wrapped as an outer-site (rt.ss on Chez, whose
;; reporter is the one that reads it).

(define-record-type outer-site (fields pair) (nongenerative jolt-outer-site-v1))

(define (jolt-site-snapshot)
  (let ((s (virtual-register jolt-vreg-site)))
    (if (pair? s)
        s
        (let ((o (virtual-register jolt-vreg-outer-site)))
          (and (pair? o) (make-outer-site o))))))
;; A top-level form is a root: nothing tail-called it, so whatever the slot holds
;; when one starts is a returned call's residue — the reporter's validator cannot
;; tell it from a live pair when the innermost live frame is a host fn (the
;; loader, the eval loop), which registers no callees. compile-eval.ss clears the
;; slot when a form starts to compile and again when its compiled code starts to
;; run, since macroexpansion runs user code in between.

(define (jolt-site-reset!)
  (set-virtual-register! jolt-vreg-site 0)
  (set-virtual-register! jolt-vreg-outer-site 0))
;; The site pair ('ns/fn' . line) of the innermost call at the throw — the
;; catch-line snapshot when a handler is running, else the raise-time stash.
;; #f when unset. The reporter must validate this against the callsite table
;; (jolt-callsite-callee) before trusting the name.

(define (jolt-throw-site)
  (let ((c (virtual-register jolt-vreg-catch-line)))
    (if (pair? c)
        c
        (let ((s (jolt-throw-sitep)))
          (and (or (pair? s) (outer-site? s)) s)))))
;; Emitted around a catch clause's body: snapshot the throwing site and return the
;; previous snapshot, which the paired leave restores. Save/restore rather than a
;; bare set so a nested catch cannot leave an inner throw's site behind for an
;; outer handler that runs afterwards. Reads the raise-time stash, not the live
;; vreg — by handler time the handler's context is what the vreg describes.

(define (jolt-catch-enter!)
  (let ((prev (virtual-register jolt-vreg-catch-line))
        (cur (jolt-throw-sitep)))
    (set-virtual-register! jolt-vreg-catch-line (if (pair? cur) cur 0))
    prev))


(define (jolt-catch-leave! previous)
  (set-virtual-register! jolt-vreg-catch-line (if (pair? previous) previous 0)))

(define jolt-load-wrap (make-thread-parameter #f))
(define jolt-load-wrap-origins (make-weak-eq-hashtable))
(define jolt-load-wrap-mutex (make-mutex))
(define (jolt-load-wrap-origin raw)
  (let ((v (jolt-unwrap-throw raw)))
    (or (and (jolt-ex-info-record? v)
             (equal? (jolt-ex-info-record-class-name v) "clojure.lang.Compiler$CompilerException")
             (jolt-with-mutex jolt-load-wrap-mutex
               (hashtable-ref jolt-load-wrap-origins v #f)))
        raw)))
;; ...and of its per-path evaluated text, which a diagnostic snippet reads.
(define jolt-eval-source-texts (make-hashtable string-hash string=?))
(define jolt-eval-text-mutex (make-mutex))
(define (jolt-eval-source-text-set! path text)
  (jolt-with-mutex jolt-eval-text-mutex (hashtable-set! jolt-eval-source-texts path text)))

(define plevel-cell #f)
(define plength-cell #f)
(define (jolt-print-level)
  (unless plevel-cell (set! plevel-cell (jolt-var "clojure.core" "*print-level*")))
  (let ((v (jolt-var-get plevel-cell))) (and (number? v) v)))
(define (jolt-print-length)
  (unless plength-cell (set! plength-cell (jolt-var "clojure.core" "*print-length*")))
  (let ((v (jolt-var-get plength-cell))) (and (number? v) v)))
(define jolt-print-depth (make-thread-parameter 0))
;; A collection at depth >= *print-level* renders as "#". The top-level collection
;; is depth 0, so *print-level* 0 collapses any collection, 1 keeps the outermost.
(define (jolt-print-hash?)
  (let ((lvl (jolt-print-level))) (and lvl (fx>=? (jolt-print-depth) lvl))))
;; Rendered element strings of a vector (by index), honoring *print-length*: at
;; most N, then "...". render-one runs at the current (already bumped) depth.
(define (jolt-limited-vec-strs x render-one)
  (let ((len (pvec-count x)) (lim (jolt-print-length)))
    (let loop ((i 0) (acc '()))
      (cond ((fx>=? i len) (reverse acc))
            ((and lim (fx>=? i lim)) (reverse (cons "..." acc)))
            (else (loop (fx+ i 1) (cons (render-one (pvec-nth-d x i jolt-nil)) acc)))))))
;; Rendered element strings of a seq, walked lazily so an infinite seq is realized
;; only up to *print-length*.
(define (jolt-limited-seq-strs s render-one)
  (let ((lim (jolt-print-length)))
    (let loop ((s s) (i 0) (acc '()))
      (cond ((jolt-nil? s) (reverse acc))
            ((and lim (fx>=? i lim)) (reverse (cons "..." acc)))
            (else (loop (jolt-seq (seq-more s)) (fx+ i 1) (cons (render-one (seq-first s)) acc)))))))
;; Truncate an already-collected element-string list (set / map, finite) to
;; *print-length*, appending "..." when more remain.
(define (jolt-limited-list-strs strs)
  (let ((lim (jolt-print-length)))
    (if (not lim) strs
        (let loop ((s strs) (i 0) (acc '()))
          (cond ((null? s) (reverse acc))
                ((fx>=? i lim) (reverse (cons "..." acc)))
                (else (loop (cdr s) (fx+ i 1) (cons (car s) acc))))))))
;; bump the print depth around a collection's element rendering — but only when
;; *print-level* is set, since depth is consulted only to enforce it. With the
;; common nil default this is a plain begin, so printing pays no parameterize.
(define-syntax with-deeper-print
  (syntax-rules ()
    ((_ body ...) (if (jolt-print-level)
                      (parameterize ((jolt-print-depth (fx+ (jolt-print-depth) 1))) body ...)
                      (begin body ...)))))

;; The value types the runtime itself owns: Chez immediates plus the two value
;; records (keyword, symbol) no host shim can model. Every printer base case
;; renders these directly, so walking the arm registries for one is dead work —
;; and in print-heavy code they are nearly every value. Both printers and the str
;; renderer skip straight to their base case for a value that answers true here.
;;
;; The correctness condition is that NO registered arm may match one of these, or
;; the fast path would silently bypass it. That is enforced at registration
;; (pr-arm-reject-fast-type!) rather than left to a comment, so a library shim
;; registering through __register-pr! / __register-str! cannot introduce an arm
;; the fast path would skip: it fails loudly at the point of registration instead
;; of rendering wrongly at some later print.
(define (pr-fast-type? x)
  (or (number? x)
      (string? x)
      (jolt-nil? x)
      (eq? x #t)
      (eq? x #f)
      (char? x)
      (keyword? x)
      (jolt-symbol? x)))


(define (jolt-string-method method s rest)
  (define (arg n) (list-ref rest n))
  (define (arg-idx n)
    (let ((v (arg n))) (if (integer? v) v (exact (truncate v)))))
  (cond
    ((string=? method "toString") s)
    ((string=? method "length") (string-length s))
    ((string=? method "charAt") (string-ref s (arg-idx 0)))
    ;; the kernel's own searches below: string-index / string-rindex are Chez
    ;; spellings Gambit does not bind, so (.indexOf s x) died on an unbound
    ;; global. A char or a code point needle (String.indexOf(int)) is searched
    ;; as its one-char string, like natives-str.ss.
    ((string=? method "indexOf")
     (str-index-of s (str-needle (arg 0)) (if (fx>? (length rest) 1) (arg-idx 1) 0)))
    ((string=? method "lastIndexOf")
     (str-last-index-of s (str-needle (arg 0))))
    ((string=? method "hashCode") (java-string-hash s))   ; natives-misc.ss, shared
    ((string=? method "startsWith") (string-prefix? (jolt-need-str (arg 0)) s))
    ((string=? method "endsWith") (string-suffix? (jolt-need-str (arg 0)) s))
    ((string=? method "substring")
     (substring s (arg-idx 0)
                (if (fx>? (length rest) 1) (arg-idx 1) (string-length s))))
    ;; the rest of the surface the seed's own sources call: cl-format's case
    ;; directives, clojure.main's argument parsing, the printer's checks
    ((string=? method "toLowerCase") (string-downcase s))
    ((string=? method "toUpperCase") (string-upcase s))
    ((string=? method "trim") (str-trim s))
    ((string=? method "isEmpty") (fx=? (string-length s) 0))
    ((string=? method "contains") (fx>=? (str-index-of s (str-needle (arg 0)) 0) 0))
    ((string=? method "concat") (string-append s (jolt-need-str (arg 0))))
    ((string=? method "equals") (let ((o (arg 0))) (and (string? o) (string=? s o))))
    (else (error 'jolt-string-method "unhandled string method on Guile" method))))

;; ---- clojure.core/str-* natives ---------------------------------------------
;; chez defines these in java/natives-str.ss (excluded, G2 java/ cut); the
;; prelude's clojure.string overlay and the compiler image var-deref them at
;; runtime. Self-contained ports on Gambit primitives. Regex branches raise a
;; clear error — the compiler path only passes literal needles.
(define (jolt-char-by-char-match? s si needle nlen)
  (let loop ((j 0))
    (cond ((fx=? j nlen) #t)
          ((char=? (string-ref s (fx+ si j)) (string-ref needle j)) (loop (fx+ j 1)))
          (else #f))))
(define (str-index-of s needle from)
  (let ((nlen (string-length needle)) (slen (string-length s)))
    (let loop ((i (max 0 from)))
      (cond ((fx>? (fx+ i nlen) slen) -1)
            ((jolt-char-by-char-match? s i needle nlen) i)
            (else (loop (fx+ i 1)))))))
(define (str-last-index-of s needle)
  (let ((nlen (string-length needle)) (slen (string-length s)))
    (let loop ((i (fx- slen nlen)) (found -1))
      (cond ((fx<? i 0) found)
            ((jolt-char-by-char-match? s i needle nlen) i)
            (else (loop (fx- i 1) found))))))
(define (str-needle x)
  (cond ((char? x) (string x))
        ((number? x) (string (integer->char (exact (truncate x)))))
        ((string? x) x)
        (else (jolt-str-render-one x))))
(define (str-replace-literal s a b)
  (let ((alen (string-length a)) (slen (string-length s)))
    (if (fx=? alen 0)
        ;; JVM String.replace with an empty match inserts the replacement at
        ;; every position 0..slen: "" -> "b", "aaa" -> "bababab".
        (let ((op (open-output-string)))
          (let loop ((i 0))
            (if (fx>? i slen)
                (get-output-string op)
                (begin (display b op)
                       (if (fx<? i slen) (write-char (string-ref s i) op))
                       (loop (fx+ i 1))))))
        (let ((op (open-output-string)))
          (let loop ((i 0))
            (if (fx>? (fx+ i alen) slen)
                (begin (display (substring s i slen) op) (get-output-string op))
                (if (jolt-char-by-char-match? s i a alen)
                    (begin (display b op) (loop (fx+ i alen)))
                    (begin (display (string-ref s i) op) (loop (fx+ i 1))))))))))
(define (str-replace-literal-first s a b)
  (let ((alen (string-length a)) (i (str-index-of s a 0)))
    (if (fx<? i 0) s
        (string-append (substring s 0 i) b (substring s (fx+ i alen) (string-length s))))))
(define (str-triml s)
  (let ((len (string-length s)))
    (let loop ((i 0))
      (cond ((fx=? i len) "")
            ((char<=? (string-ref s i) #\space) (loop (fx+ i 1)))
            (else (substring s i len))))))
(define (str-trimr s)
  (let loop ((j (fx- (string-length s) 1)))
    (cond ((fx<? j 0) "")
          ((char<=? (string-ref s j) #\space) (loop (fx- j 1)))
          (else (substring s 0 (fx+ j 1))))))
(define (str-trim s) (str-triml (str-trimr s)))
(define (str-upper s) (string-upcase s))
(define (str-lower s) (string-downcase s))
(define (str-reverse-b s) (list->string (reverse (string->list s))))
(define (str-find needle s . opt)
  (let ((i (str-index-of s needle (if (pair? opt) (car opt) 0))))
    (if (fx<? i 0) jolt-nil i)))
;; The Chez twin (java/natives-str.ss str-last-find): String.lastIndexOf(str,
;; from) — the last occurrence that STARTS at or before FROM, or nil; a negative
;; FROM is nil, one past the end clamps, an empty needle answers min(from, len).
(define (str-last-find needle s from)
  (let* ((needle (str-needle needle))
         (nlen (string-length needle)) (slen (string-length s)))
    (cond
      ((fx<? from 0) jolt-nil)
      ((fx=? nlen 0) (fxmin from slen))
      (else
       (let loop ((i (fxmin from (fx- slen nlen))))
         (cond ((fx<? i 0) jolt-nil)
               ((jolt-char-by-char-match? s i needle nlen) i)
               (else (loop (fx- i 1)))))))))
(define (str-literal-split s sep)
  (let ((slen (string-length (jolt-need-str s))) (plen (string-length sep)))
    (if (fx=? plen 0)
        (map (lambda (c) (list->string (list c))) (string->list s))
        (let loop ((i 0) (start 0) (acc '()))
          (cond ((fx>? (fx+ i plen) slen)
                 (reverse (cons (substring s start slen) acc)))
                ((string=? (substring s i (fx+ i plen)) sep)
                 (loop (fx+ i plen) (fx+ i plen) (cons (substring s start i) acc)))
                (else (loop (fx+ i 1) start acc)))))))
(define (jolt-str-join-strs strs sep)
  (let loop ((xs strs) (first #t) (acc '()))
    (cond ((null? xs) (apply string-append (reverse acc)))
          (first (loop (cdr xs) #f (cons (car xs) acc)))
          (else (loop (cdr xs) #f (cons (car xs) (cons sep acc)))))))
(define (str-split pat s . opt)
  (let ((limit (if (and (pair? opt) (not (jolt-nil? (car opt)))) (jolt->idx (car opt)) #f)))
    (define (literal-parts sep)
      (let ((parts (str-literal-split s sep)))
        (if (and limit (fx>? limit 0) (fx>? (length parts) limit))
            (append ((@ (srfi srfi-1) take) parts (fx- limit 1))
                    (list (jolt-str-join-strs (list-tail parts (fx- limit 1)) sep)))
            parts)))
    (apply jolt-vector
      (if (jolt-regex? pat)
          ;; a pattern that matches exactly one string splits on that text
          ;; (#"\n" is pprint's line splitter); anything with regex structure
          ;; runs the engine — regex-literal-text and re-split are regex.ss's,
          ;; the same two natives-str.ss splits with on Chez
          (let ((lit (regex-literal-text (regex-t-source pat))))
            (if lit (literal-parts lit) (re-split (regex-t-irx pat) s limit)))
          (literal-parts pat)))))
;; Regex or literal, the natives-str.ss shape: a regex that is really a literal
;; replaced by a string that is really a literal is a plain search-and-replace,
;; anything else runs the engine (re-replace, regex.ss — $N expansion and fn
;; replacements included). The regex? test comes first: under a profile
;; without the regex group every regex.ss name but the predicates is bound to
;; a raise, and no regex value exists to take that branch.
(define (str-replace-all pat repl s)
  (if (jolt-regex? pat)
      (let ((lit (literal-replace-text pat repl)))
        (if lit
            (str-replace-literal s lit repl)
            (re-replace (regex-t-irx pat) s repl #t)))
      (str-replace-literal s (str-needle pat) (str-needle repl))))
(define (str-replace pat repl s)
  (if (jolt-regex? pat)
      (let ((lit (literal-replace-text pat repl)))
        (if lit
            (str-replace-literal-first s lit repl)
            (re-replace (regex-t-irx pat) s repl #f)))
      (str-replace-literal-first s (str-needle pat) (str-needle repl))))
(def-var! "clojure.core" "str-upper" str-upper)
(def-var! "clojure.core" "str-lower" str-lower)
(def-var! "clojure.core" "str-trim" str-trim)
(def-var! "clojure.core" "str-triml" str-triml)
(def-var! "clojure.core" "str-trimr" str-trimr)
(def-var! "clojure.core" "str-find" str-find)
(def-var! "clojure.core" "str-last-find" str-last-find)
(def-var! "clojure.core" "str-reverse-b" str-reverse-b)
(def-var! "clojure.core" "str-split" str-split)
(def-var! "clojure.core" "str-replace" str-replace)
(def-var! "clojure.core" "str-replace-all" str-replace-all)


(define (jolt-host-throwable/detail class-name msg detail)
  (let ((t (jolt-host-throwable class-name msg)))
    (jolt-ex-info-record-error-offset-set! t detail)
    t))
(define (jolt-capture-throwable! value)
  (jolt-throw-sitep (jolt-site-snapshot))
  value)
(define (jolt-throwable-stack-trace value) (jolt-vector))
(define (jolt-throwable-backtrace-string value) #f)
(define (jolt-random n)
  (if (exact-integer? n) (random n) (* n (random:uniform))))
(define (jolt-random-bytes n)
  (call-with-port (open-file "/dev/urandom" "rb")
    (lambda (port)
      (let ((bytes (get-bytevector-n port n)))
        (unless (and (bytevector? bytes) (= (bytevector-length bytes) n))
          (error 'jolt-random-bytes "could not read system entropy" n))
        bytes))))

(define (nb-host-bytes a) #f)
(define (nb-host-new-bytes n) #f)
(define (nb-host-array? a kind) #f)
(define (nb-no-arrays who)
  (jolt-throw (jolt-host-throwable "java.lang.UnsupportedOperationException"
                                   (string-append who ": arrays are not wired up on this target"))))
(define (nb-host-array-len a) (nb-no-arrays "java.nio buffer array length"))
(define (nb-host-array-ref a i) (nb-no-arrays "java.nio buffer array read"))
(define (nb-host-array-set! a i v) (nb-no-arrays "java.nio buffer array write"))
(define (nb-host-new-array kind n) (nb-no-arrays "java.nio typed buffer allocate"))
(define (nb-host-chars->string a from to) (nb-no-arrays "java.nio CharBuffer array read"))
(define (nb-host-char-string a) #f)
(define (nb-host-char-ref a i) (nb-no-arrays "java.nio CharBuffer array read"))
(define (nb-host-char-set! a i c) (nb-no-arrays "java.nio CharBuffer array write"))
(define (jts? x) #f)
(define (jfile? x) #f)
(define (jbigdec? x) #f)


(define (jolt-path-directory? path)
  (and (file-exists? path) (eq? (stat:type (stat path)) 'directory)))
(define (jolt-path-entries path)
  (map (lambda (entry) (string-append path "/" entry))
       ((@ (ice-9 ftw) scandir) path
        (lambda (entry) (not (member entry '("." "..")))))))

;; Source readers are installed by the source-loader slice.
(define data-readers-active #f)
(define (ldr-apply-readers value) value)


(define (jolt-register-eval-marker-table! scheme position written namespace)
  (let ((file (and (pmap? position) (jolt-get position (keyword #f "file")))))
    (if (string? file) file (string-append "<jolt:" namespace ">"))))

(define (jolt-bigdec-from-string text)
  (throw-jvm 'UnsupportedOperationException "BigDecimal literals are unsupported on the guile target"))
(define (jbigdec-scale value)
  (throw-jvm 'UnsupportedOperationException "BigDecimal scale is unsupported on the guile target"))
(define (jbigdec-unscaled value)
  (throw-jvm 'UnsupportedOperationException "BigDecimal unscaled values are unsupported on the guile target"))
(define (jbigdec->string value)
  (throw-jvm 'UnsupportedOperationException "BigDecimal conversion is unsupported on the guile target"))
(define (jolt-inst-from-string text)
  (throw-jvm 'UnsupportedOperationException "#inst is unsupported on the guile target"))
(define (inst-rfc3339 value)
  (throw-jvm 'UnsupportedOperationException "#inst formatting is unsupported on the guile target"))


(define jolt-guile-callsites (make-hashtable string-hash string=?))
(define jolt-guile-callsites-mu (make-mutex))
(define (jolt-register-callsite! function line callee tail?)
  (jolt-with-mutex jolt-guile-callsites-mu
    (let* ((sites (hashtable-ref jolt-guile-callsites function '()))
           (site (list line callee tail?)))
      (unless (member site sites)
        (hashtable-set! jolt-guile-callsites function (cons site sites)))))
  jolt-nil)


(define (jrec-tag-desc-ref tag)
  (sa-shared-read rec-tbl-mu (hashtable-ref chez-tag-desc tag #f)))
