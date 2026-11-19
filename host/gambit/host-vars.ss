;; host-vars.ss — the clojure.core names host/chez/java/* binds on Chez.
;;
;; On Chez the java/ tree owns the JVM-shaped half of clojure.core: clocks, file
;; IO, the interop entry points, agents and futures, taps, the library shim
;; hooks. This target boots none of those files, so without this one every such
;; name is an UNBOUND GLOBAL: calling it raises a bare Gambit exception with no
;; jolt context and no position. `(time 1)` was exactly that — the macro expands
;; to a current-time-ms call, which crashed with an unreadable error rather than
;; reporting a missing capability.
;;
;; Every name here is either implemented on Gambit or bound to a raise that says
;; which capability is absent. Nothing stays unbound, and nothing pretends to
;; work — the same rule the sa-* capability tiers follow.
;;
;; Loaded after the prelude and post-prelude so these bindings are the last word.

;; ---- degradation -----------------------------------------------------------
;; A catchable UnsupportedOperationException naming the operation and the reason,
;; so the failure reads the same whether it reaches a REPL, a catch clause, or a
;; log line.
(define (gambit-unsupported-fn name reason)
  (lambda args
    (jolt-throw
      (jolt-host-throwable
        "java.lang.UnsupportedOperationException"
        (string-append "clojure.core/" name " is unsupported on the gambit target: "
                       reason)))))

(define (degrade-core-var! name reason)
  (def-var! "clojure.core" name (gambit-unsupported-fn name reason)))

(define (degrade-core-vars! names reason)
  (for-each (lambda (n) (degrade-core-var! n reason)) names))

;; ---- system tier: real -----------------------------------------------------

;; Epoch milliseconds, like System/currentTimeMillis — this backs `time`, and
;; user code reads it as a wall clock, so it must be epoch-based rather than the
;; process-relative (real-time) the adapter's sa-real-time-ms reports.
(define (gambit-epoch-ms)
  (inexact->exact (floor (* 1000 (time->seconds (current-time))))))
(def-var! "clojure.core" "current-time-ms" gambit-epoch-ms)

;; The monotonic nanosecond clock `time` expands to (System/nanoTime on the
;; JVM; host-static-methods.ss on Chez). real-time is Gambit's monotonic clock
;; in float seconds. Unbound, the macro's clojure.core/current-time-ns call
;; read as a static member access and (time 1) died on jolt.host/static-member.
(def-var! "clojure.core" "current-time-ns"
  (lambda () (inexact->exact (floor (* 1e9 (real-time))))))

(def-var! "clojure.core" "flush"
  (lambda args (force-output) jolt-nil))

(def-var! "clojure.core" "__stdin-read-line"
  (lambda args
    (let ((l (read-line)))
      (if (eof-object? l) jolt-nil l))))

;; ---- file IO: real on gsi ---------------------------------------------------
;; These work wherever the host has a filesystem. Under the js target the open
;; fails and Gambit's own error surfaces with its message intact (the condition
;; shims in prelude-shims.ss make it readable), which is the honest outcome for
;; a target that has no files.

(define (gambit-read-all port)
  (let ((content (read-line port #f)))
    (if (eof-object? content) "" content)))

(def-var! "clojure.core" "slurp"
  (lambda (src . opts)
    (if (string? src)
        (call-with-input-file src gambit-read-all)
        (jolt-throw
          (jolt-host-throwable "java.lang.IllegalArgumentException"
            "slurp on the gambit target takes a path string")))))

(def-var! "clojure.core" "spit"
  (lambda (dest content . opts)
    (if (string? dest)
        (begin
          (call-with-output-file dest
            (lambda (p) (display (jolt-str-render-one content) p)))
          jolt-nil)
        (jolt-throw
          (jolt-host-throwable "java.lang.IllegalArgumentException"
            "spit on the gambit target takes a path string")))))

;; file-seq's seams (clojure/core/21-coll.clj): a path string names a file; a
;; directory answers its entries as paths. No java.io.File value exists here, so
;; __file? is "is this a path string" and every walk starts from one.
(def-var! "clojure.core" "__file?" (lambda (x) (if (string? x) #t jolt-nil)))
(def-var! "clojure.core" "__dir?"
  (lambda (p) (if (and (string? p) (jolt-path-directory? p)) #t jolt-nil)))
(def-var! "clojure.core" "__list-dir"
  (lambda (p) (list->cseq (jolt-path-entries p))))

;; with-open's close seam (io.ss jolt-close on Chez), minus the arms for host
;; readers that cannot exist here: a deftype/reify with a close method closes
;; through it, a library's tagged-table stream through its registered .close,
;; a map-like value through its :close fn; nil is a no-op.
(def-var! "clojure.core" "__close"
  (lambda (x)
    (cond
      ((jolt-nil? x) jolt-nil)
      ((htable? x) (guard (e (#t jolt-nil)) (record-method-dispatch x "close" jolt-nil)) jolt-nil)
      ((iface-method x "close" #f)
       (record-method-dispatch x "close" jolt-nil) jolt-nil)
      (else
       (let ((closef (jolt-get x (keyword #f "close") jolt-nil)))
         (if (and (not (jolt-nil? closef)) (procedure? closef))
             (begin (jolt-invoke closef) jolt-nil)
             (throw-jvm (quote IllegalArgumentException) "with-open: no .close method on value")))))))

;; ---- library shim hooks: real ----------------------------------------------
;; The underlying arm registries are all present in the portable runtime, so a
;; library that models its own host values works here unchanged.
;;
;; The seam fns run inside the host's =/hash/str of any value, so a tail call in
;; one must not leave its site pair in the slot after it returns (Chez's
;; host-static-classes.ss seam-invoke1/2, which this mirrors). This boot never
;; enables tracing and renders no frames, so nothing stores or reads a pair
;; today; the restore keeps the two hosts alike if that changes.
(define (seam-invoke1 f x)
  (let* ((s (virtual-register jolt-vreg-site)) (r (jolt-invoke f x)))
    (set-virtual-register! jolt-vreg-site s)
    r))
(define (seam-invoke2 f a b)
  (let* ((s (virtual-register jolt-vreg-site)) (r (jolt-invoke f a b)))
    (set-virtual-register! jolt-vreg-site s)
    r))

(def-var! "clojure.core" "__register-eq!"
  (lambda (pred handler)
    (register-eq-arm! (lambda (a b) (jolt-truthy? (seam-invoke2 pred a b)))
                      (lambda (a b) (jolt-truthy? (seam-invoke2 handler a b))))
    jolt-nil))

(def-var! "clojure.core" "__register-hash!"
  (lambda (pred handler)
    (register-hash-arm! (lambda (x) (jolt-truthy? (seam-invoke1 pred x)))
                        (lambda (x) (seam-invoke1 handler x)))
    jolt-nil))

(def-var! "clojure.core" "__register-str!"
  (lambda (pred render)
    (register-str-render! (lambda (x) (jolt-truthy? (seam-invoke1 pred x)))
                          (lambda (x) (seam-invoke1 render x)))
    jolt-nil))

(def-var! "clojure.core" "__register-pr!"
  (lambda (pred render)
    (register-pr-arm! (lambda (x) (jolt-truthy? (seam-invoke1 pred x)))
                      (lambda (x) (seam-invoke1 render x)))
    jolt-nil))

(def-var! "clojure.core" "__register-compare!"
  (lambda (pred handler)
    (register-compare-arm! (lambda (a b) (jolt-truthy? (seam-invoke2 pred a b)))
                           (lambda (a b) (seam-invoke2 handler a b)))
    jolt-nil))

;; (class x)/(type x) and protocol dispatch for a library's own values, the same
;; contract as Chez's host-static-classes.ss: class-fn names the class, tags-fn
;; lists the class/interface names value-host-tags feeds protocol dispatch.
(define jt-user-value-tags-arms '())
(let ((prev value-host-tags))
  (set! value-host-tags
    (lambda (obj)
      (let loop ((as jt-user-value-tags-arms))
        (cond ((null? as) (prev obj))
              (((caar as) obj) ((cdar as) obj))
              (else (loop (cdr as))))))))
(define (jt-jolt-strs->list v)
  (let loop ((s (jolt-seq v)) (acc '()))
    (if (jolt-nil? s) (reverse acc) (loop (jolt-seq (jolt-rest s)) (cons (jolt-first s) acc)))))
(def-var! "clojure.core" "__register-class!"
  (lambda (pred class-fn tags-fn)
    (let ((p (lambda (x) (jolt-truthy? (seam-invoke1 pred x)))))
      (register-class-arm-checked! p (lambda (x) (seam-invoke1 class-fn x)))
      (set! jt-user-value-tags-arms
            (append jt-user-value-tags-arms
                    (list (cons p (lambda (x) (jt-jolt-strs->list (seam-invoke1 tags-fn x))))))))
    jolt-nil))

;; The library seam for instance?, the same contract as Chez's
;; (host-static-classes.ss, excluded here): each fn answers nil to pass, so ONE
;; arm asks them in order and passes when none decides. Registering each as its
;; own arm answering (jolt-truthy? …) turned a pass into a definitive false —
;; the first library to register one shadowed every arm after it — and made the
;; library's answer look like a builtin one to instance-check's verdict memo,
;; which must never cache what library code says (records-interop.ss, which also
;; holds user-instance-checks so it is bound before the seed prelude loads).
(register-instance-check-user-arm!
  (lambda (type-sym val)
    (let ((tname (symbol-t-name type-sym)))
      (let loop ((fs user-instance-checks))
        (if (null? fs)
            'pass
            (let ((r (seam-invoke2 (car fs) tname val)))
              (if (jolt-nil? r) (loop (cdr fs)) (if (jolt-truthy? r) #t #f))))))))
(def-var! "clojure.core" "__register-instance-check!"
  (lambda (f)
    (set! user-instance-checks (append user-instance-checks (list f)))
    (set! instance-arms-epoch (fx+ instance-arms-epoch 1))
    jolt-nil))

;; The class-methods half of the same seam. The table is write-only on this boot
;; (host-static-classes.ss is excluded, so no host interop reads it back), but the
;; var has to EXIST: jolt.socket and jolt/time/*.clj call it at the top level, and
;; an unbound clojure.core/__register-class-methods! fails their load outright.
(def-var! "clojure.core" "__register-class-methods!"
  (lambda (tag members)
    (register-class-methods! tag members)
    jolt-nil))

;; The ctor and statics halves (host-static-classes.ss on Chez), into the same
;; registries host-new and host-static-call read here. jolt/time/*.clj and
;; jolt.socket call them at the top level. There is no library-provider registry
;; on this boot, so a registration simply lands, as Chez's does when no provider
;; has claimed the class.
(def-var! "clojure.core" "__register-class-ctor!"
  (lambda (name proc) (register-class-ctor! name proc) jolt-nil))
(def-var! "clojure.core" "__register-class-statics!"
  (lambda (name members)
    (register-class-statics! name
      (let loop ((s (jolt-seq members)) (acc '()))
        (if (jolt-nil? s) acc
            (let ((e (jolt-first s)))
              (loop (jolt-seq (jolt-rest s)) (cons (cons (jolt-nth e 0) (jolt-nth e 1)) acc))))))
    jolt-nil))

;; ---- delay ---------------------------------------------------------------
;; One state word holds the pending thunk or the cached (success? . outcome).
;; Forcing under the object monitor serializes the first evaluation, including
;; failure, and drops the thunk once there is an outcome.
(define (gambit-force-delay delay)
  (let ((result
          (jolt-with-monitor delay
            (lambda ()
              (let ((state (jolt-delay-state delay)))
                (if (pair? state)
                    state
                    (let ((outcome (guard (e (#t (cons #f e)))
                                     (cons #t (jolt-invoke0 state)))))
                      (jolt-delay-state-set! delay outcome)
                      outcome)))))))
    (if (car result) (cdr result) (raise (cdr result)))))

(let ((previous-deref jolt-deref))
  (set! jolt-deref
    (lambda (x . opts)
      (if (jolt-delay? x)
          (gambit-force-delay x)
          (apply previous-deref x opts)))))
(def-var! "clojure.core" "deref" jolt-deref)
(def-var! "clojure.core" "make-delay" make-jolt-delay)
(def-var! "clojure.core" "delay?" jolt-delay?)
(register-class-ctor! "clojure.lang.Delay" make-jolt-delay)
(register-class-ctor! "Delay" make-jolt-delay)

;; ---- byte arrays ---------------------------------------------------------
;; Jolt sees signed byte elements, while the FFI carrier holds raw octets.
(define (gambit-signed-byte octet)
  (if (< octet 128) octet (- octet 256)))

(define (gambit-byte-octet value)
  (bitwise-and (jolt-unchecked-int (if (jfloat? value) (jfloat-fl value) value)) #xff))

(define (gambit-byte-array size-or-items . init)
  (cond
    ((or (number? size-or-items) (jfloat? size-or-items))
     (let ((size (jolt-int-cast size-or-items))
           (fill (if (null? init) 0 (car init))))
       (when (< size 0) (throw-jvm 'NegativeArraySizeException (number->string size)))
       (if (or (number? fill) (jfloat? fill))
           (make-u8vector size (gambit-byte-octet fill))
           (let ((out (make-u8vector size 0)))
             (let loop ((i 0) (items (jolt-seq fill)))
               (unless (or (= i size) (jolt-nil? items))
                 (u8vector-set! out i (gambit-byte-octet (seq-first items)))
                 (when (< (+ i 1) size)
                   (loop (+ i 1) (jolt-seq (seq-more items))))))
             out))))
    ((u8vector? size-or-items) (u8vector-copy size-or-items))
    ((string? size-or-items) (string->utf8 size-or-items))
    (else (list->u8vector
            (map gambit-byte-octet (seq->list (jolt-seq size-or-items)))))))

(define (gambit-byte-ref a i) (gambit-signed-byte (u8vector-ref a i)))

(define (gambit-byte-index a i0)
  (jolt-nth-nil-idx! i0)
  (index-int-check! i0)
  (let ((i (->idx i0)))
    (and (<= 0 i) (< i (u8vector-length a)) i)))

(register-count-arm! u8vector? u8vector-length)
(register-count-arm! jolt-obj-array? (lambda (a) (vector-length (jolt-obj-array-vec a))))

(let ((previous-nth jolt-nth))
  (set! jolt-nth
    (case-lambda
      ((a i)
       (cond
         ((u8vector? a)
          (let ((at (gambit-byte-index a i)))
            (if at (gambit-byte-ref a at) (throw-jvm 'ArrayIndexOutOfBoundsException jolt-nil))))
         ((jolt-obj-array? a)
          (let ((vec (jolt-obj-array-vec a))
                (idx (jolt-int-cast i)))
            (if (and (<= 0 idx) (< idx (vector-length vec)))
                (vector-ref vec idx)
                (throw-jvm 'ArrayIndexOutOfBoundsException (number->string idx)))))
         (else (previous-nth a i))))
      ((a i default)
       (cond
         ((u8vector? a)
          (let ((at (gambit-byte-index a i)))
            (if at (gambit-byte-ref a at) default)))
         ((jolt-obj-array? a)
          (let ((vec (jolt-obj-array-vec a))
                (idx (jolt-int-cast i)))
            (if (and (<= 0 idx) (< idx (vector-length vec)))
                (vector-ref vec idx)
                default)))
         (else (previous-nth a i default)))))))
(def-var! "clojure.core" "nth" jolt-nth)

(define (gambit-byte-seq a i)
  (let ((remaining (- (u8vector-length a) i)))
    (if (= remaining 0)
        jolt-nil
        (make-cseqn a (make-lazy-src gambit-byte-tail a i)
                    sk-array-cells-byte jolt-nil remaining))))
(define gambit-byte-tail
  (register-lazy-src! 'gambit-byte-tail (lambda (a i) (gambit-byte-seq a (+ i 1)))))
(set-array-cells-ops!
  (lambda (a remaining) (gambit-byte-ref a (- (u8vector-length a) remaining)))
  (lambda (f acc a remaining)
    (let ((end (u8vector-length a)))
      (let loop ((i (- end remaining)) (acc acc))
        (cond ((jolt-reduced? acc) (jolt-reduced-val acc))
              ((= i end) acc)
              (else (loop (+ i 1) (jolt-invoke2 f acc (gambit-byte-ref a i)))))))))
(register-seq-arm! u8vector? (lambda (a) (gambit-byte-seq a 0)))
(register-seq-arm! jolt-obj-array?
  (lambda (a)
    (let ((lst (vector->list (jolt-obj-array-vec a))))
      (if (null? lst) jolt-nil (list->cseq lst)))))

(define (jolt-aset3 a i v)
  (cond
    ((u8vector? a)
     (let ((at (gambit-byte-index a i)) (octet (gambit-byte-octet v)))
       (unless at (throw-jvm 'ArrayIndexOutOfBoundsException jolt-nil))
       (u8vector-set! a at octet)
       (gambit-signed-byte octet)))
    ((jolt-obj-array? a)
     (let ((vec (jolt-obj-array-vec a))
           (idx (jnum->exact i)))
       (unless (and (<= 0 idx) (< idx (vector-length vec)))
         (throw-jvm 'ArrayIndexOutOfBoundsException jolt-nil))
       (vector-set! vec idx v)
       v))
    (else
     (begin (jolt-ref-put! a i v) v))))

;; The numeric pass also uses these heads for inferred or hinted arrays.
(define (jolt-vaget a i) (jolt-nth a i))
(define (jolt-vaset a i v) (jolt-aset3 a i v))
(define (jolt-baset a i v) (jolt-aset3 a i v))
(def-var! "jolt.host" "ref-put!"
  (lambda (a i v)
    (if (jolt-array? a)
        (begin (jolt-aset3 a i v) a)
        (jolt-ref-put! a i v))))

(define (gambit-alength a)
  (cond
    ((jolt-nil? a) (throw-jvm 'NullPointerException "null"))
    ((jolt-obj-array? a) (vector-length (jolt-obj-array-vec a)))
    ((u8vector? a) (u8vector-length a))
    (else (jolt-count a))))
(set! jolt-alength gambit-alength)
(set! jolt-valength gambit-alength)
(def-var! "clojure.core" "alength" jolt-alength)

(define (gambit-object-array size-or-items)
  (cond
    ((or (number? size-or-items) (jfloat? size-or-items))
     (let ((size (jolt-int-cast size-or-items)))
       (when (< size 0) (throw-jvm 'NegativeArraySizeException (number->string size)))
       (make-jolt-obj-array (make-vector size jolt-nil))))
    ((jolt-obj-array? size-or-items)
     (make-jolt-obj-array (vector-copy (jolt-obj-array-vec size-or-items))))
    (else
     (make-jolt-obj-array (list->vector (seq->list (jolt-seq size-or-items)))))))

(define (gambit-aclone a)
  (cond
    ((jolt-obj-array? a) (make-jolt-obj-array (vector-copy (jolt-obj-array-vec a))))
    ((u8vector? a) (u8vector-copy a))
    (else (throw-jvm 'IllegalArgumentException "aclone: not an array"))))

(def-var! "clojure.core" "object-array" gambit-object-array)
(def-var! "clojure.core" "aclone" gambit-aclone)
(def-var! "clojure.core" "to-array"
  (lambda (coll) (gambit-object-array (jolt-seq coll))))
(def-var! "clojure.core" "byte-array" gambit-byte-array)
(def-var! "clojure.core" "bytes" (lambda (x) (if (u8vector? x) x (gambit-byte-array x))))
(def-var! "clojure.core" "bytes?" u8vector?)
(set! jolt-array? (lambda (x) (or (u8vector? x) (jolt-obj-array? x))))
(set! jolt-array-kind
  (lambda (x) (cond ((u8vector? x) 'byte) ((jolt-obj-array? x) 'object) (else #f))))
(def-var! "clojure.core" "array?" jolt-array?)

;; ---- queries answer, they do not raise -------------------------------------
(def-var! "clojure.core" "queue?" (lambda (x) #f))

;; No tap registry exists, so nothing is listening and tap> reports that.
;; Registering one, on the other hand, is a request this target cannot honor.
(def-var! "clojure.core" "tap>" (lambda (x) #f))

;; The reader consults this map; empty is the truth here, not a missing name.
;; empty-pmap is a VALUE, not a constructor — calling it applies the map
(def-var! "clojure.core" "default-data-readers" empty-pmap)

;; ---- host errors carry a class and a message --------------------------------
;; Gambit has no arity introspection (see procedure-arity-mask in
;; prelude-shims.ss), so seq.ss's structural arity pre-check always passes and
;; Gambit's own runtime raises instead. Those exception objects have no JVM class,
;; so (class e), (str e), and a catch clause all fell through to the class-model
;; default and printed "#object[:object]" — which is what `(time)` reported
;; instead of an arity error. Map Gambit's wording onto the class the equivalent
;; Chez failure carries. The wording is Gambit's own (there is no arg count or
;; callee name to recover), but the class and the message are real.

(define (gambit-msg-has? m sub)
  (let ((ml (string-length m)) (sl (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i sl) ml) #f)
            ((string=? (substring m i (+ i sl)) sub) #t)
            (else (loop (+ i 1)))))))

(define (gambit-host-error? x)
  (and (condition? x) (not (jolt-ex-info-record? x))))

(define (gambit-error-class x)
  (let ((m (or (condition-message x) "")))
    (cond
      ((gambit-msg-has? m "Wrong number of arguments") "clojure.lang.ArityException")
      ((gambit-msg-has? m "Unbound variable")          "java.lang.IllegalStateException")
      ((gambit-msg-has? m "Division by zero")          "java.lang.ArithmeticException")
      ((gambit-msg-has? m "expected")                  "java.lang.ClassCastException")
      ((gambit-msg-has? m "Operator is not a PROCEDURE") "java.lang.ClassCastException")
      (else "java.lang.RuntimeException"))))

(define (gambit-collapse-lines s)
  ;; Gambit's description runs onto further lines (the procedure and the args it
  ;; got); a message is one line everywhere else in jolt, so fold them together.
  (let ((n (string-length s)))
    (call-with-output-string
      (lambda (o)
        (let loop ((i 0) (gap #f))
          (if (>= i n)
              #t
              (let ((c (string-ref s i)))
                (cond ((memv c '(#\newline #\return #\tab)) (loop (+ i 1) #t))
                      (else (when (and gap (> i 0)) (write-char #\space o))
                            (write-char c o)
                            (loop (+ i 1) #f))))))))))

(define (gambit-error-tostring x)
  (string-append (gambit-error-class x) ": "
                 (gambit-collapse-lines (or (condition-message x) "host error"))))

(register-class-arm! gambit-host-error? gambit-error-class)
(register-str-render! gambit-host-error? gambit-error-tostring)
(register-pr-arm! gambit-host-error? gambit-error-tostring)

;; ---- host objects that cannot exist here ------------------------------------
;; The reader/stream shims built on the jhost record live in the java/ tree this
;; target does not boot, so no value here can BE one. Answering #f makes every
;; branch guarded by these predicates dead code — which is why the accessors
;; behind them need no stand-in, since Scheme resolves a global only when it is
;; actually reached. printing.ss consults jhost? on the way to a writer, which
;; is what made `(time 1)` die on an unbound name. (The jhost record itself and
;; the interop registries are host-statics.ss, which loads before the prelude:
;; its own (import …) forms intern class tokens through class-model.ss.)
(define (reader-jhost? x) #f)
;; jhost-seqable-shim? is java/jutil-colls.ss's, which this boot includes.
;; The compiler uses this predicate when dispatching array operations.
(def-var! "jolt.host" "array-value?"
  (lambda (x) (if (jolt-array? x) #t jolt-nil)))
;; concurrency.ss is not in this boot, so there are no agent threads to mark
(def-var! "jolt.host" "agent-threads-daemon!" (lambda () jolt-nil))
(def-var! "jolt.host" "callable-host?"
  (lambda (x) (if (jolt-multifn? x) #t jolt-nil)))
;; jolt.profile's host surface. Chez defines it in source-registry.ss, which
;; this boot leaves out; here it is the profile tier's degradation, so
;; instrument! throws {:host :unsupported} rather than naming an unbound var.
(def-var! "jolt.host" "profile-instrument!"
  (lambda (on?) (sa-profile-instrument! (jolt-truthy? on?))))
(def-var! "jolt.host" "profile-instrumenting?" (lambda () (sa-profile-instrumenting?)))
;; the counters never turn on here (sa-profile-instrument! refuses)
(def-var! "jolt.host" "profile-instrument-mode" (lambda () jolt-nil))
;; jolt.debug: Gambit has no inspector frames to read, so a throwable has no
;; frames here, and a break handler is never called (the body just runs).
(def-var! "jolt.host" "debug-frames" (lambda (t) (jolt-vector)))
(def-var! "jolt.host" "debug-call-with-break" (lambda (handler thunk) (jolt-invoke thunk)))
(def-var! "jolt.host" "profile-clear!" (lambda () (sa-profile-clear!) jolt-nil))
(def-var! "jolt.host" "profile-sites" (lambda () (jolt-vector)))
(def-var! "jolt.host" "profile-retired" (lambda () (jolt-vector)))
(def-var! "jolt.host" "profile-defs" (lambda (files) (jolt-vector)))
(def-var! "jolt.host" "profile-stats"
  (lambda () (apply jolt-vector (vector->list (sa-stats)))))
;; The sampler's half (sampler.ss on Chez, also left out): no timer to drive
;; it, so sample! throws {:host :unsupported} and there is nothing to read.
(def-var! "jolt.host" "sample-start!" (lambda (interval depth) #f))
(def-var! "jolt.host" "sample-stop!" (lambda () jolt-nil))
(def-var! "jolt.host" "sampling?" (lambda () #f))
(def-var! "jolt.host" "sample-read" (lambda () (jolt-vector 0 (jolt-vector))))
;; Per-object identity for the back end's constant pool (rt.ss on Chez).
(def-var! "jolt.host" "identity-hash" (lambda (x) (jolt-identity-hasheq x)))

;; ---- the streams and reader tables the printer and reader consult ----------
;; *out* / *err* hold the same default port-writer jhosts Chez binds
;; (host-static-classes.ss): the printer's jolt-write (printing.ss) treats that
;; exact value as "the fast port path" and only a REBOUND writer goes through
;; a write method. clojure.pprint (seed-embedded) reads *out* directly, so the
;; cells must be bound, not merely interned by the first read.
(def-dynvar! "clojure.core" "*out*" (make-jhost "port-writer" (vector 'out)))
(def-dynvar! "clojure.core" "*err*" (make-jhost "port-writer" (vector 'err)))
;; The reader consults *data-readers* like default-data-readers; empty is the
;; truth here (inst-time.ss binds the same default on Chez).
(def-dynvar! "clojure.core" "*data-readers*" empty-pmap)

;; ---- the image seams the analyzer asks ---------------------------------------
;; embed-plan is how a macro's live value gets rebuilt as code (analyzer.clj
;; embedded-value). state-image.ss answers with the image writer's verdict; this
;; target has no fn-form registry (rt-core's image-register-fn-form! is a no-op),
;; so the only rebuildable value is one some var roots — {:kind :var} from the
;; proc-name table — and everything else is honestly nil: the analyzer then
;; reports "cannot be rebuilt as code" instead of dying on an unbound var.
(def-var! "jolt.host" "embed-plan"
  (lambda (x)
    (let ((p (and (procedure? x) (proc-name-of x))))
      (if p
          (jolt-hash-map (keyword #f "kind") (keyword #f "var")
                         (keyword #f "ns") (car p)
                         (keyword #f "name") (cdr p))
          jolt-nil))))

;; ---- absent capabilities ---------------------------------------------------
;; The interop entry points (host-new, host-static-call / -ref, static-member)
;; and the shims behind them are host-statics.ss.
(degrade-core-vars! '("make-proxy") "there are no JVM class shims on this target")
;; the proxy macro's entry point (it passes the form's ns, for the class name)
(def-var! "jolt.host" "make-proxy-in"
  (gambit-unsupported-fn "make-proxy-in" "there are no JVM class shims on this target"))
;; The fn-form registry (fn-form-registry.ss) is the image's; the back end asks
;; it inside a try and falls back to constructing the form.
(def-var! "jolt.host" "fn-form-parse"
  (gambit-unsupported-fn "fn-form-parse" "there is no fn-form registry on this target"))

(degrade-core-vars! '("into-array" "make-array" "int-array"
                      "long-array" "double-array" "float-array" "boolean-array"
                      "char-array" "short-array")
                    "typed and multidimensional arrays are not wired up on this target (java/natives-array.ss)")

(degrade-core-vars! '("future-call" "future-cancel" "send-via" "agent-errors"
                      "clear-agent-errors" "await-for" "error-handler" "error-mode"
                      "set-error-handler!" "set-error-mode!" "release-pending-sends"
                      "set-agent-send-executor!" "set-agent-send-off-executor!"
                      "shutdown-agents")
                    "futures and agents are not wired up on this target")

(degrade-core-vars! '("clojure.lang.PersistentQueue")
                    "persistent queues are not wired up on this target")

(degrade-core-vars! '("require" "use")
                    "this target loads no source at runtime")

(degrade-core-vars! '("bigdec" "rationalize")
                    "there is no BigDecimal on this target")

(degrade-core-vars! '("add-tap" "remove-tap")
                    "there is no tap registry on this target")
