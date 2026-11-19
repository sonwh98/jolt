;; host-ffi.ss — the jolt.ffi host-owned surface for the GAMBIT target
;; (P1b-stage1). On Chez these vars live in host/chez/java/ffi.ss, which the
;; gambit boot manifest excludes — without this file every jolt.ffi name was an
;; unbound global (the same shape the host-vars.ss degradation fixed for
;; clojure.core). Stage-1 binds the memory/loader/errno surface the qualified
;; tier backs (the adapter rows + the native bridge), implements what the
;; stdlib/jolt/ffi.clj public functions call into, and binds EVERYTHING ELSE to
;; a message-carrying refusal — nothing stays unbound, nothing pretends.
;;
;; Loaded after host-vars.ss, before the seed image (same rule: these bindings
;; are the last word for the names the excluded ffi.ss owned). Requires the
;; booted kernel (jolt-nil, def-var!, jolt-hash-map, make-pvec, ...) — this
;; file is boot-world only; the sa-* tier it leans on also loads standalone
;; under gambitcheck without it.

(define (joltffi-public-error thunk)
  (guard (e (#t (throw-jvm 'UnsupportedOperationException
                            (or (condition-message e) "jolt.ffi: native bridge failure"))))
    (thunk)))

(define (joltffi-public-blocking-raise)
  (joltffi-public-error sa-foreign-procedure-blocking-raise))

(define (joltffi-public-procedure args ret name variadic capture?)
  (let ((fp (joltffi-public-error
             (lambda () ((if capture? joltffi-foreign-capture-procedure joltffi-foreign-procedure)
                         args ret name variadic)))))
    (lambda args
      (joltffi-public-error (lambda () (apply fp args))))))

;; ---- emitted-text helpers the compiler's ordinary-call wrappers lean on -----
;; The :string conversions invert per direction like the Chez pair; jolt truthy
;; rule for :bool; jfloat unboxing for :float/:double. jolt-ffi-c->string maps
;; the adapter's NULL-string #f to jolt-nil (values.ss's sentinel — bound by
;; the time any of these RUN; the define only closes over it).
(define (jolt-ffi-string->c x)
  (cond ((string? x) x)
        ((jolt-nil? x) #f)                ; nil IS NULL, in both directions
        (else (throw-jvm 'IllegalArgumentException
                         (string-append "jolt.ffi: :string got " (jolt-pr-str x)
                                        " — NULL is spelled nil")))))
(define (jolt-ffi-c->string x) (if x x jolt-nil))
(define (jolt-ffi-bool->c v) (if (or (jolt-nil? v) (eq? v #f)) 0 1))
(define (jolt-ffi-c->bool raw) (not (eqv? (jnum->exact raw) 0)))
(define (jolt-ffi-float->c x) (if (jfloat? x) (jfloat-fl x) x))

;; A :string ARGUMENT travels as u8* on Chez (an immobile copy). Gambit has no
;; immobile allocation and the stage-1 bridge carries no :string-argument shape
;; (the registry has none), so this raises BEFORE the unbound-identifier fate
;; the pre-stage1 boot would have dealt: the adapter's shape validation refuses
;; :string arguments, and this helper — which the emitted wrapper evaluates
;; first — refuses for any path that might reach it out of order.
(define (jolt-ffi-string-arg x)
  (throw-jvm 'UnsupportedOperationException
             "jolt.ffi: :string arguments are unsupported on the gambit target — no immobile allocation behind the stage-1 bridge"))

;; The emitted call keeps string copies live until C returns; identity here,
;; because nothing that evaluates it can have a live foreign reference (the
;; string-arg path above refuses first). Bound so the emitted TEXT never dies
;; on an unbound identifier at load.
(define (keep-live x) x)

;; jolt-ffi-function-pointer: the pointer-call null guard (backend
;; ffi-pointer-procedure-expr emits it ahead of each call). Pointer-call
;; bindings are compile-time-refused on :gambit, so this only guards paths that
;; hand a raw address to the ordinary tier.
(define (jolt-ffi-function-pointer ptr)
  (let ((address (if (jolt-nil? ptr) 0 (jnum->exact ptr))))
    (if (eqv? address 0)
        (throw-jvm 'NullPointerException "jolt.ffi: null C function pointer")
        address)))

;; jolt-ffi-dlsym-native (the compiler's emitted scoped probe) is defined in
;; the adapter itself — it must exist in every world the emitted text loads in,
;; including the adapter-only gambitcheck unit.

;; ---- foreign memory over the adapter tier -------------------------------------
;; alloc returns the ADDRESS (an exact integer); read/write take the type
;; keyword and the offset LAST (the babashka.ffi order the stdlib wrapper
;; keeps). Type keywords arrive as jolt keywords; the stdlib resolves layouts
;; and places before calling, so these see scalars only.
(define (joltffi-keyword-name kw)
  (if (keyword-t? kw) (keyword-t-name kw) kw))

(define (joltffi-type->chez kw)
  (let ((n (joltffi-keyword-name kw)))
    (cond
      ((string=? n "int") 'int)
      ((string=? n "uint") 'unsigned-int)
      ((or (string=? n "int8") (string=? n "i8")) 'integer-8)
      ((or (string=? n "uint8") (string=? n "u8") (string=? n "byte")) 'unsigned-8)
      ((or (string=? n "int16") (string=? n "short")) 'integer-16)
      ((or (string=? n "uint16") (string=? n "ushort")) 'unsigned-16)
      ((string=? n "int32") 'integer-32)
      ((string=? n "uint32") 'unsigned-32)
      ((string=? n "long") 'long)
      ((string=? n "ulong") 'unsigned-long)
      ((string=? n "int64") 'integer-64)
      ((string=? n "uint64") 'unsigned-64)
      ((string=? n "size_t") 'size_t)
      ((string=? n "ssize_t") 'ssize_t)
      ((string=? n "iptr") 'iptr)
      ((string=? n "uptr") 'uptr)
      ((string=? n "double") 'double)
      ((string=? n "float") 'float)
      ((or (string=? n "pointer") (string=? n "void*")) 'void*)
      ((string=? n "char") 'char)
      ((string=? n "bool") 'jolt-bool)   ; one byte wide; converted at the boundary
      ((string=? n "string") 'string)
      ((string=? n "void") 'void)
      (else (error #f (string-append "jolt.ffi: unknown foreign type :" n))))))

(define (joltffi-sizeof-chez ct) (sa-foreign-sizeof (if (eq? ct 'jolt-bool) 'unsigned-8 ct)))

(define (joltffi-read ptr ty off)
  (let ((ct (joltffi-type->chez ty)))
    (cond
      ((eq? ct 'jolt-bool)
       (jolt-ffi-c->bool (sa-foreign-ref 'unsigned-8 (jnum->exact ptr) (jnum->exact off))))
      ((eq? ct 'float)
       (make-jfloat (sa-foreign-ref 'float (jnum->exact ptr) (jnum->exact off))))
      ((eq? ct 'string)
       (jolt-ffi-c->string (joltffi-read-string (jnum->exact ptr) (jnum->exact off))))
      (else (sa-foreign-ref ct (jnum->exact ptr) (jnum->exact off))))))

;; a NUL-terminated C string at ptr -> string (adapter-level #f for a NULL
;; first byte means the caller spelled NULL with 0 — see ptr->string). One bulk
;; move of the whole window, then a Scheme-side scan; the stdlib's ptr->string
;; and the :string __read ride on this.
(define (joltffi-read-string ptr off)
  (let ((p (+ (jnum->exact ptr) (jnum->exact off))))
    (if (= p 0) #f
        (let scan ((n 0) (bytes '()))
          (let ((v (sa-foreign-ref 'unsigned-8 p n)))
            (if (= v 0)
                (utf8->string (list->u8vector (reverse bytes)))
                (scan (+ n 1) (cons v bytes))))))))

(define (joltffi-write ptr ty val off)
  (let ((ct (joltffi-type->chez ty)))
    (cond
      ((eq? ct 'jolt-bool)
       (sa-foreign-set! 'unsigned-8 (jnum->exact ptr) (jnum->exact off) (jolt-ffi-bool->c val)))
      ((memq ct '(float double))
       (sa-foreign-set! ct (jnum->exact ptr) (jnum->exact off) (jolt-ffi-float->c val)))
      ((eq? ct 'string)
       (let ((s (jolt-ffi-string->c val)))
         (if s
             (let ((bv (string->utf8 s)))
               (sa-foreign-bytes-set! (+ (jnum->exact ptr) (jnum->exact off)) bv (bytevector-length bv))
               (let ((z (make-bytevector 1 0)))
                 (sa-foreign-bytes-set! (+ (jnum->exact ptr) (jnum->exact off) (bytevector-length bv)) z 1))
               jolt-nil)
             jolt-nil)))
      (else (sa-foreign-set! ct (jnum->exact ptr) (jnum->exact off) val)))
    jolt-nil))

;; ---- the size bookkeeping ------------------------------------------------------
;; jolt.ffi/size answers what jolt was TOLD — arena allocations, segments. One
;; table, address -> size, guarded by the adapter's loader mutex's sibling.
(define joltffi-sizes-mu (make-mutex))
(define joltffi-sizes (make-eqv-hashtable))
(define (joltffi-remember-size! ptr n)
  (jwm-call joltffi-sizes-mu (lambda () (hashtable-set! joltffi-sizes (jnum->exact ptr) (jnum->exact n))))
  jolt-nil)
(define (joltffi-forget-sizes! ps)
  (jwm-call joltffi-sizes-mu
    (lambda ()
      (for-each (lambda (p) (hashtable-delete! joltffi-sizes (jnum->exact p)))
                (seq->list (jolt-seq ps)))))
  jolt-nil)
(define (joltffi-recorded-size ptr)
  (jwm-call joltffi-sizes-mu (lambda () (hashtable-ref joltffi-sizes (jnum->exact ptr) 0))))

;; ---- alloc/free ------------------------------------------------------------------
(define (joltffi-alloc nbytes)
  (let* ((n (jnum->exact nbytes))
         (p (sa-foreign-alloc n)))
    (when (> n 0) (joltffi-remember-size! p n))
    p))
(define (joltffi-calloc nbytes)
  (let* ((n (jnum->exact nbytes))
         (p (sa-foreign-alloc n)))
    (when (> n 0)
      (sa-foreign-zero! p n)
      (joltffi-remember-size! p n))
    p))
(define (joltffi-host-free ptr)
  (sa-foreign-free (jnum->exact ptr))
  (jwm-call joltffi-sizes-mu
    (lambda () (hashtable-delete! joltffi-sizes (jnum->exact ptr))))
  jolt-nil)
(define (joltffi-copy src dst n)
  (let* ((n (jnum->exact n)) (bv (make-bytevector n)))
    (when (> n 0)
      (sa-foreign-bytes-ref! (jnum->exact src) bv n)
      (sa-foreign-bytes-set! (jnum->exact dst) bv n))
    jolt-nil))
(define (joltffi-null? ptr) (and (number? ptr) (= (jnum->exact ptr) 0)))
(define joltffi-null 0)

;; read/write take (ptr ty [off]) — the babashka.ffi offset-last order
(define joltffi-read-fn
  (case-lambda ((ptr ty) (joltffi-read ptr ty 0))
               ((ptr ty off) (joltffi-read ptr ty off))))
(define joltffi-write-fn
  (case-lambda ((ptr ty val) (joltffi-write ptr ty val 0))
               ((ptr ty val off) (joltffi-write ptr ty val off))))

;; ---- buffer I/O (known length) ---------------------------------------------------
(define (joltffi-read-bytes ptr n)
  (let* ((n (jnum->exact n)) (p (jnum->exact ptr)) (bv (make-bytevector n)))
    (sa-foreign-bytes-ref! p bv n)
    (guard (e (#t (list->string (map integer->char (bytevector->u8-list bv)))))
      (utf8->string bv))))
(define (joltffi-write-bytes ptr s)
  (let* ((bv (string->utf8 s)) (n (bytevector-length bv)) (p (jnum->exact ptr)))
    (sa-foreign-bytes-set! p bv n)
    n))

;; ptr->string: NUL-terminated C string at ptr (NULL/0 -> nil)
(define joltffi-ptr->string
  (case-lambda
    ((p) (joltffi-ptr->string* p #f))
    ((p limit) (joltffi-ptr->string* p (if (jolt-nil? limit) #f (jnum->exact limit))))))
(define (joltffi-ptr->string* ptr limit)
  (if (joltffi-null? ptr) jolt-nil
      (let ((p (jnum->exact ptr)))
        (let scan ((n 0) (bytes '()))
          (when (and limit (>= n limit))
            (throw-jvm 'IllegalArgumentException "jolt.ffi/ptr->string: no NUL byte within the limit"))
          (let ((v (sa-foreign-ref 'unsigned-8 p n)))
            (if (= v 0) (utf8->string (list->u8vector (reverse bytes)))
                (scan (+ n 1) (cons v bytes))))))))
(define (joltffi-string->ptr s)
  (if (jolt-nil? s) 0
      (let* ((bv (string->utf8 (jolt-str-render-one s)))
             (n (bytevector-length bv))
             (p (sa-foreign-alloc (+ n 1))))
        (guard (e (#t (sa-foreign-free p) (raise e)))
          (sa-foreign-bytes-set! p bv n)
          (sa-foreign-set! 'unsigned-8 p n 0)
          (joltffi-remember-size! p (+ n 1))
          p))))
(define (joltffi-utf8-length s)
  (if (jolt-nil? s) 0 (bytevector-length (string->utf8 (jolt-str-render-one s)))))

;; ---- loader surface ---------------------------------------------------------------
;; load-library: the Chez semantics minus Windows/Termux arms — nil keeps the
;; boot's process handle; a per-OS map selects this platform's entry; anything
;; else is one name or an ORDERED candidate list, tried in order, with the
;; loader's own reason preserved on failure. Answers {:path "<loaded>"} or nil.
(define (joltffi-library-map path)
  (jolt-hash-map (keyword #f "path") path))

(define (joltffi-candidate-list name)
  (if (or (pvec? name) (jolt-seq? name) (jolt-lazyseq? name))
      (map (lambda (c) (if (string? c) c (jolt-str-render-one c))) (seq->list (jolt-seq name)))
      (list (jolt-str-render-one name))))

(define (joltffi-load-failure-note cands)
  (let loop ((cs cands) (acc '()))
    (if (null? cs)
        (and (pair? acc)
             (let join ((xs (reverse acc)) (out ""))
               (if (null? xs)
                   out
                   (join (cdr xs) (if (string=? out "") (car xs)
                                      (string-append out "; " (car xs)))))))
        (let* ((cand (car cs))
               (exists (guard (e (#t #f)) (file-exists? cand)))
               (why (jwm-call joltffi-native-mu
                      (lambda () (hashtable-ref joltffi-native-failures cand #f)))))
          (loop (cdr cs)
                (if exists
                    (cons (string-append cand " is there but did not load"
                                         (if why (string-append ": " why) ""))
                          acc)
                    acc))))))

(define (joltffi-join-candidates cands sep)
  (let loop ((cs cands) (out ""))
    (cond ((null? cs) out)
          ((null? (cdr cs)) (string-append out (car cs)))
          (else (loop (cdr cs) (string-append out (car cs) sep))))))

(define (joltffi-load-candidates cands)
  (joltffi-ensure-bridge! 'jolt.ffi/load-library)
  (let loop ((cs cands))
    (cond
      ((null? cs)
       (jolt-throw (jolt-ex-info
                     (string-append "jolt.ffi/load-library: cannot load "
                                    (if (or (null? cands) (null? (cdr cands))) "" "any of ")
                                    (joltffi-join-candidates cands ", ")
                                    (let ((note (joltffi-load-failure-note cands)))
                                      (if note (string-append " — " note) "")))
                     (jolt-hash-map (keyword #f "candidates")
                                    (make-pvec (list->vector cands))))))
      ((joltffi-load-native (car cs)) (car cs))
      (else (loop (cdr cs))))))

(define (joltffi-load-library . args)
  (cond
    ((or (null? args) (jolt-nil? (car args)))
     jolt-nil)
    ((jolt-map? (car args))
     (let* ((spec (car args))
            (key (begin (joltffi-ensure-bridge! 'jolt.ffi/load-library) (joltffi-platform-key)))
            (name (jolt-get-dispatch spec (keyword #f key) jolt-nil))
            (name (if (and (jolt-nil? name) (string=? key "darwin"))
                      (jolt-get-dispatch spec (keyword #f "mac") jolt-nil) name)))
       (when (jolt-nil? name)
         (jolt-throw (jolt-ex-info
                       (string-append "jolt.ffi/load-library: no :" key " entry in the per-OS spec") spec)))
       (joltffi-library-map (joltffi-load-candidates (joltffi-candidate-list name)))))
    (else (joltffi-library-map (joltffi-load-candidates (joltffi-candidate-list (car args)))))))

(define (joltffi-loaded? name)
  (joltffi-ensure-bridge! 'jolt.ffi/loaded?)
  (if (joltffi-load-native name) #t #f))

(define (joltffi-system-library-candidates n)
  (list (string-append "lib" n ".dylib") (string-append n ".dylib")))

(define (joltffi-load-system-library name)
  (joltffi-library-map
   (joltffi-load-candidates
    (joltffi-system-library-candidates (if (string? name) name (jolt-str-render-one name))))))

(define joltffi-find-symbol
  (case-lambda
    ((sym)
     (joltffi-ensure-bridge! 'jolt.ffi/find-symbol)
     (let* ((n (if (string? sym) sym (jolt-str-render-one sym)))
            (a (joltffi-dlsym-loaded n)))
       (cond (a a)
             ((guard (e (#t #f)) (sa-foreign-entry? n)) (sa-foreign-entry-address n))
             (else jolt-nil))))
    ((lib sym)
     (if (jolt-nil? lib)
         (joltffi-find-symbol sym)
         (let* ((n (if (string? sym) sym (jolt-str-render-one sym)))
                (path (and (jolt-map? lib)
                           (jolt-get-dispatch lib (keyword #f "path") jolt-nil)))
                (h (and (string? path) (joltffi-library-handle path))))
           (unless h
             (jolt-throw (jolt-ex-info
                           "jolt.ffi/find-symbol: no handle for this library — pass the map load-library answered for it"
                           (jolt-hash-map (keyword #f "library") lib))))
           (let ((a (joltffi-dlsym h n)))
             (if (and a (not (= a 0))) a jolt-nil)))))))

;; the dlopen handle a load-library of PATH registered, or #f
(define (joltffi-library-handle path)
  (let loop ((hs joltffi-native-handles))
    (cond ((null? hs) #f)
          ((string=? (caar hs) path) (cdar hs))
          (else (loop (cdr hs))))))

(define (joltffi-defining-libraries sym)
  (joltffi-ensure-bridge! 'jolt.ffi/defining-libraries)
  (make-pvec
   (list->vector
    (map car (joltffi-definers (if (string? sym) sym (jolt-str-render-one sym)))))))

(define (joltffi-load-failure-note-var cands)
  (joltffi-load-failure-note (if (list? cands) cands (list cands))))

;; ---- refusing rows (message-carrying; the capability stays unqualified) -------
(define (joltffi-refuse-fn name reason)
  (lambda args
    (jolt-throw
     (jolt-host-throwable
      "java.lang.UnsupportedOperationException"
      (string-append "jolt.ffi/" name " is unsupported on the gambit target: " reason)))))

(define (joltffi-refuse-var! name reason)
  (def-var! "jolt.ffi" name (joltffi-refuse-fn name reason)))

;; byte-array moves need the jolt-array runtime (natives-array.ss is excluded
;; from this boot's manifest) — the SA tier's bulk copies ARE qualified; this
;; row is the jolt-array half.
(joltffi-refuse-var! "read-array" "byte-array moves need the jolt-array runtime, which this boot's manifest excludes")
(joltffi-refuse-var! "read-into!" "byte-array moves need the jolt-array runtime, which this boot's manifest excludes")
(joltffi-refuse-var! "write-array" "byte-array moves need the jolt-array runtime, which this boot's manifest excludes")
(joltffi-refuse-var! "__read-array" "byte-array moves need the jolt-array runtime, which this boot's manifest excludes")
(joltffi-refuse-var! "__write-array" "byte-array moves need the jolt-array runtime, which this boot's manifest excludes")
(joltffi-refuse-var! "__read-into!" "byte-array moves need the jolt-array runtime, which this boot's manifest excludes")
(joltffi-refuse-var! "__read-into-typed!" "typed-array views over foreign memory are not in the stage-1 registry")
(joltffi-refuse-var! "__write-array-typed" "typed-array views over foreign memory are not in the stage-1 registry")
(joltffi-refuse-var! "__byte-buffer" "direct ByteBuffers over foreign memory are not in the stage-1 registry")
(joltffi-refuse-var! "free-callable" "foreign callables are unqualified (no arm64/x86_64 trampoline generator in stock Gambit 4.9.8)")
(joltffi-refuse-var! "register-export" "foreign callables and AOT are unqualified on the gambit target")
(joltffi-refuse-var! "__arena-callback" "foreign callables are unqualified (no arm64/x86_64 trampoline generator in stock Gambit 4.9.8)")
(joltffi-refuse-var! "__auto-guard!" "auto arenas (collector-reclaimed) need guardians over foreign memory, unqualified in stage-1")
(joltffi-refuse-var! "__auto-reclaimed" "auto arenas (collector-reclaimed) need guardians over foreign memory, unqualified in stage-1")
(joltffi-refuse-var! "__gc-stall-reporter!" "the GC stall watch has no hook on this target (sa-gc-install-stall-watch! answers #f)")
(joltffi-refuse-var! "stack-args-correct?" "the Chez #1091 stack-args probe is Chez-ABI-only and is not re-probed under the Gambit ABI in stage-1")
(joltffi-refuse-var! "load-native" "superseded by load-library on this target (the adapter's scoped loader is the single dlopen path)")

;; ---- implemented rows -----------------------------------------------------------
(def-var! "jolt.ffi" "load-library" joltffi-load-library)
(def-var! "jolt.ffi" "loaded?" joltffi-loaded?)
(def-var! "jolt.ffi" "load-system-library" joltffi-load-system-library)
(def-var! "jolt.ffi" "system-library-candidates"
  (lambda (n) (make-pvec (list->vector (joltffi-system-library-candidates n)))))
(def-var! "jolt.ffi" "load-failure-note" joltffi-load-failure-note-var)
(def-var! "jolt.ffi" "find-symbol" joltffi-find-symbol)
(def-var! "jolt.ffi" "dlsym-native" jolt-ffi-dlsym-native)
(def-var! "jolt.ffi" "defining-libraries" joltffi-defining-libraries)
(def-var! "jolt.ffi" "alloc" joltffi-alloc)
(def-var! "jolt.ffi" "free" joltffi-host-free)
(def-var! "jolt.ffi" "__alloc" joltffi-alloc)
(def-var! "jolt.ffi" "__free" joltffi-host-free)
(def-var! "jolt.ffi" "__calloc" joltffi-calloc)
(def-var! "jolt.ffi" "read" joltffi-read-fn)
(def-var! "jolt.ffi" "write" joltffi-write-fn)
(def-var! "jolt.ffi" "__read" joltffi-read-fn)
(def-var! "jolt.ffi" "__write" joltffi-write-fn)
(def-var! "jolt.ffi" "copy" joltffi-copy)
(def-var! "jolt.ffi" "__copy" joltffi-copy)
(def-var! "jolt.ffi" "sizeof" (lambda (ty) (joltffi-sizeof-chez (joltffi-type->chez ty))))
(def-var! "jolt.ffi" "__sizeof" (lambda (ty) (joltffi-sizeof-chez (joltffi-type->chez ty))))
(def-var! "jolt.ffi" "__size" joltffi-recorded-size)
(def-var! "jolt.ffi" "__remember-size!" joltffi-remember-size!)
(def-var! "jolt.ffi" "__forget-sizes!" joltffi-forget-sizes!)
(def-var! "jolt.ffi" "read-bytes" joltffi-read-bytes)
(def-var! "jolt.ffi" "write-bytes" joltffi-write-bytes)
(def-var! "jolt.ffi" "__read-bytes" joltffi-read-bytes)
(def-var! "jolt.ffi" "__write-bytes" joltffi-write-bytes)
(def-var! "jolt.ffi" "null?" (lambda (p) (if (joltffi-null? p) #t #f)))
(def-var! "jolt.ffi" "null" joltffi-null)
(def-var! "jolt.ffi" "ptr->string" joltffi-ptr->string)
(def-var! "jolt.ffi" "string->ptr" joltffi-string->ptr)
(def-var! "jolt.ffi" "__string->ptr" joltffi-string->ptr)
(def-var! "jolt.ffi" "__utf8-length" joltffi-utf8-length)
