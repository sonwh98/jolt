#!no-fold-case
;; host/guile/rt-core.ss — Phase 3a minimal kernel subset for Guile 3.0.11.
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
(define (jolt-raise-thrown v) (raise (cons 'jolt-throw v)))
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
(define (jolt-set-current-ns! ns) (%current-ns-param ns))

(define-record-type jolt-var-unbound
  (fields ns name)
  (nongenerative guile-jolt-var-unbound-v1))

(define-record-type var-cell
  (fields ns name (mutable root) (mutable meta) (mutable macro?))
  (nongenerative guile-var-cell-v1))

(define var-table (make-hashtable string-hash string=?))
(define var-table-mu (make-mutex))

(define (var-cell-defined? c)
  (not (jolt-var-unbound? (var-cell-root c))))

(define (var-cell-deref c)
  (let ((r (var-cell-root c)))
    (if (jolt-var-unbound? r)
        (throw-jvm 'IllegalStateException
                   (string-append "Attempting to call unbound fn: #'"
                                  (var-cell-ns c) "/" (var-cell-name c)))
        r)))

(define (var-cell-lookup ns name)
  (sa-shared-read var-table-mu
    (hashtable-ref var-table (string-append ns "/" name) #f)))

(define (jolt-var ns name)
  (let ((full (string-append ns "/" name)))
    (sa-shared-intern var-table-mu
      (hashtable-ref var-table full #f)
      (let ((c (make-var-cell ns name (make-jolt-var-unbound ns name) jolt-nil #f)))
        (hashtable-set! var-table full c)
        c))))

(define (var-deref ns name)
  (var-cell-root (jolt-var ns name)))

(define (chez-resolve-alias _here _qns) #f)
(define (chez-resolve-refer _here _sym) #f)

(define (def-var! ns name v)
  (let ((c (jolt-var ns name)))
    (var-cell-root-set! c v)
    c))

(define (def-var-plain! ns name v) (def-var! ns name v))

(define (def-var-linked! ns name _sym v _setter m)
  (let ((c (def-var! ns name v)))
    (when m (var-cell-meta-set! c m))
    c))

(define (def-var-with-meta! ns name v m)
  (let ((c (def-var! ns name v)))
    (var-cell-meta-set! c m)
    c))

(define (def-dynvar! ns name v) (def-var! ns name v))

(define (set-var-meta! ns name m)
  (let ((c (jolt-var ns name)))
    (var-cell-meta-set! c m)
    c))

(define (mark-macro! ns name)
  (let ((c (jolt-var ns name)))
    (var-cell-macro?-set! c #t)
    c))

(define (declare-var! ns name) (jolt-var ns name))

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
         (pvec-nth f (car args))
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
(define jolt-count-arms '())
(define (register-count-arm! pred handler)
  (set! jolt-count-arms (cons (cons pred handler) jolt-count-arms)))

(define jolt-contains-arms '())
(define (register-contains-arm! pred handler)
  (set! jolt-contains-arms (cons (cons pred handler) jolt-contains-arms)))

(define jolt-empty-arms '())
(define (register-empty-arm! pred handler)
  (set! jolt-empty-arms (cons (cons pred handler) jolt-empty-arms)))

(define jolt-conj-arms '())
(define (register-conj-arm! pred handler)
  (set! jolt-conj-arms (cons (cons pred handler) jolt-conj-arms)))

(define jolt-map-pred-arms '())
(define (register-map-pred-arm! pred)
  (set! jolt-map-pred-arms (cons pred jolt-map-pred-arms)))

(define jolt-get-arms '())
(define (register-get-arm! pred handler)
  (set! jolt-get-arms (cons (cons pred handler) jolt-get-arms)))

(define jolt-compare-arms '())
(define (register-compare-arm! pred handler)
  (set! jolt-compare-arms (cons (cons pred handler) jolt-compare-arms)))

(define (jolt-empty? x)
  (cond
    ((jolt-nil? x) #t)
    ((pvec? x) (fxzero? (pvec-count x)))
    ((pmap? x) (fxzero? (pmap-count x)))
    ((pset? x) (fxzero? (pset-count x)))
    ((cseq? x) #f)
    (else
     (let loop ((as jolt-empty-arms))
       (cond ((null? as) (jolt-nil? (jolt-seq x)))
             (((caar as) x) ((cdar as) x))
             (else (loop (cdr as))))))))

(define (jolt-count x)
  (cond
    ((jolt-nil? x) 0)
    ((string? x) (string-length x))
    ((pvec? x) (pvec-count x))
    ((pmap? x) (pmap-count x))
    ((pset? x) (pset-count x))
    ((cseq? x) (cseq-count x))
    (else
     (let loop ((as jolt-count-arms))
       (cond ((null? as) 0)
             (((caar as) x) ((cdar as) x))
             (else (loop (cdr as))))))))

(define (jolt-get m k . default)
  (let ((nf (if (null? default) jolt-nil (car default))))
    (cond
      ((jolt-nil? m) nf)
      ((pmap? m) (pmap-get m k nf))
      ((pset? m) (if (pset-contains? m k) k nf))
      ((pvec? m) (if (and (exact? k) (integer? k) (>= k 0) (< k (pvec-count m)))
                     (pvec-nth m k)
                     nf))
      (else
       (let loop ((as jolt-get-arms))
         (cond ((null? as) nf)
               (((caar as) m) ((cdar as) m k nf))
               (else (loop (cdr as)))))))))

(define (jolt-assoc m . kvs)
  (let loop ((m (if (jolt-nil? m) (jolt-hash-map) m)) (xs kvs))
    (if (null? xs)
        m
        (loop (pmap-assoc m (car xs) (cadr xs)) (cddr xs)))))

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

(define (jolt-object-repr x _readable?)
  (format #f "#object[~a]" (cond ((jrec? x) (jrec-tag x))
                                 ((record? x) (record-type-name (record-rtd x)))
                                 (else x))))

(define (jolt-object-content x) (format #f "~s" x))
(define (jolt-pr-readable?) #f)
(define (jolt-bigint-print? _x) #f)

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
(define jolt-nth
  (case-lambda
    ((coll i) (if (pvec? coll) (pvec-nth coll i) (seq-nth coll i)))
    ((coll i d) (if (pvec? coll)
                    (if (and (fx>=? i 0) (fx<? i (pvec-count coll))) (pvec-nth coll i) d)
                    (let loop ((s (jolt-seq coll)) (idx i))
                      (cond ((jolt-nil? s) d)
                            ((fxzero? idx) (seq-first s))
                            (else (loop (jolt-seq (seq-more s)) (fx- idx 1)))))))))

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
(define (jolt-infer-bump!) (void))
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
(define (jolt-delay? _x) #f)
(define (jolt-vol? _x) #f)
(define (jolt-future? _x) #f)
(define (jolt-promise? _x) #f)
(define (jolt-agent? _x) #f)
(define (jolt-queue? _x) #f)
(define (jolt-file? _x) #f)
(define (jolt-bigdec? _x) #f)
(define (jinst? _x) #f)
(define (jts? _x) #f)
(define (jfloat? _x) #f)
(define (jclass? _x) #f)
(define (jclass-name _x) #f)
(define (jolt-array? _x) #f)
(define (jolt-regex? _x) #f)
(define (jolt-string-builder? _x) #f)
(define (jolt-reduced? _x) #f)
(define (jolt-volatile? _x) #f)
(define (jolt-iterable? _x) #f)
(define (jolt-map? x)
  (or (pmap? x)
      (exists (lambda (p) (p x)) jolt-map-pred-arms)))

(define (jolt-conc-realized? _x) #f)
(define (jiterator? _x) #f)
(define (jolt-transient? _x) #f)
(define (t-contains? _t _k) #f)
(define (t-count _t) 0)
(define (jolt-cons x coll) (cseq-cons x coll))
(define (deref-print-to! _port _r _state _readable?) (void))
(define (jrec-assoc-entries r _ext) r)
(define (object-instance-of-array? _t _v) #f)

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
