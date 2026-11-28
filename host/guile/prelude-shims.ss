#!no-fold-case
;; host/guile/prelude-shims.ss — R6RS / Chez compatibility surface on Guile 3.0.11.
;; Loaded inside (jolt runtime) before scheme-adapter-runtime.ss and shared runtime files.

;; ---- Reader & evaluation environment ---------------------------------------
;; Capture Guile's native eval and the dedicated (jolt runtime) module at load time
;; so 1-arg eval and (interaction-environment) always target the Jolt runtime module
;; regardless of any module switch in callers or worker threads.
;; The evaluator reports only the first clause of an interpreted case-lambda.
;; Attach the exact positional arity mask when expanding in the Jolt module.
(define-syntax case-lambda
  (lambda (stx)
    (define (clause-mask formals)
      (let loop ((tail formals) (count 0))
        (cond ((pair? tail) (loop (cdr tail) (+ count 1)))
              ((null? tail) (ash 1 count))
              (else (- (ash 1 count))))))
    (syntax-case stx ()
      ((_ (formals body ...) ...)
       (with-syntax ((mask
                       (datum->syntax stx
                         (apply logior (map clause-mask (syntax->datum #'(formals ...)))))))
         #'(let ((proc ((@ (guile) case-lambda) (formals body ...) ...)))
             (set-procedure-property! proc 'jolt-arity-mask mask)
             proc))))))

(define (procedure-arity-mask proc)
  (or (procedure-property proc 'jolt-arity-mask)
      (apply
        (lambda (required optional rest?)
          (let ((first (ash 1 required))
                (limit (ash 1 (+ required optional 1))))
            (if rest? (- first) (- limit first))))
        (procedure-minimum-arity proc))))

(define %jolt-native-eval eval)
(define %jolt-boot-module (current-module))

(define (jolt-boot-module) %jolt-boot-module)
(define (interaction-environment) %jolt-boot-module)

(define eval
  (case-lambda
    ((expr) (%jolt-native-eval expr %jolt-boot-module))
    ((expr env) (%jolt-native-eval expr env))))

(define (void) (if #f #f))

;; ---- Atomic boxes ----------------------------------------------------------
(define box make-atomic-box)
(define unbox atomic-box-ref)
(define set-box! atomic-box-set!)
(define box? atomic-box?)

(define (sa-box-cas! b old new)
  (eq? (atomic-box-compare-and-swap! b old new) old))

;; ---- Virtual registers (per-thread, fork-safe) -----------------------------
;; Each OS thread gets its own 32-slot vector lazily on first access; checking
;; (eq? (car pair) (current-thread)) prevents a forked child from mutating its
;; parent's inherited fluid pair.
(define %jolt-vreg-fluid (make-fluid #f))

(define (%jolt-vreg-vec)
  (let ((me (current-thread))
        (pair (fluid-ref %jolt-vreg-fluid)))
    (if (and pair (eq? (car pair) me))
        (cdr pair)
        (let ((v (make-vector 32 0)))
          (fluid-set! %jolt-vreg-fluid (cons me v))
          v))))

(define (virtual-register i) (vector-ref (%jolt-vreg-vec) i))
(define (set-virtual-register! i v) (vector-set! (%jolt-vreg-vec) i v))

;; ---- Arithmetic / fixnum / flonum / bitwise shims --------------------------
(define (add1 n) (+ n 1))
(define (sub1 n) (- n 1))

(define fx= fx=?)
(define fx< fx<?)
(define fx<= fx<=?)
(define fx> fx>?)
(define fx>= fx>=?)
(define (fx1+ x) (fx+ x 1))
(define (fx1- x) (fx- x 1))
(define fxquotient quotient)
(define fxremainder remainder)
(define fxmodulo modulo)
(define fxsll fxarithmetic-shift-left)
(define fxsra fxarithmetic-shift-right)
(define (fxsrl n k)
  (cond
    ((fxzero? k) n)
    ((fx>=? n 0) (fxarithmetic-shift-right n k))
    (else
     (let ((width (fixnum-width)))
       (if (>= k width)
           0
           (ash (+ n (ash 1 width)) (- k)))))))
(define fxlogand fxand)
(define fxlogor fxior)
(define fxlogxor fxxor)
(define fxlognot fxnot)
(define (fxlogbit? index value) (logbit? index value))
(define (fxabs n) (if (fx<? n 0) (fx- n) n))

(define (fl= a b . rest) (apply fl=? a b rest))
(define (fl< a b . rest) (apply fl<? a b rest))
(define (fl<= a b . rest) (apply fl<=? a b rest))
(define (fl> a b . rest) (apply fl>? a b rest))
(define (fl>= a b . rest) (apply fl>=? a b rest))

(define (flvector? x) (f64vector? x))
(define make-flvector
  (case-lambda
    ((n) (make-f64vector n 0.0))
    ((n fill) (make-f64vector n (exact->inexact fill)))))
(define flvector f64vector)
(define flvector-length f64vector-length)
(define flvector-ref f64vector-ref)
(define flvector-set! f64vector-set!)
(define (fxvector? x) (vector? x))
(define make-fxvector
  (case-lambda
    ((n) (make-vector n 0))
    ((n fill) (make-vector n fill))))
(define fxvector vector)
(define fxvector-length vector-length)
(define fxvector-ref vector-ref)
(define fxvector-set! vector-set!)

(define ash-alias ash)

(define-syntax define-width-op
  (lambda (stx)
    (syntax-case stx ()
      ((_ name fx-op wide-op)
       (if (> (fixnum-width) 35)
           #'(define name fx-op)
           #'(define name wide-op))))))

;; ---- List / vector / string / printing helpers -----------------------------
(define (vector-for-each proc . vecs)
  (if (null? (cdr vecs))
      (let* ((v (car vecs)) (n (vector-length v)))
        (let loop ((i 0))
          (when (fx<? i n)
            (proc (vector-ref v i))
            (loop (fx+ i 1)))))
      (let ((n (apply min (map vector-length vecs))))
        (let loop ((i 0))
          (when (fx<? i n)
            (apply proc (map (lambda (v) (vector-ref v i)) vecs))
            (loop (fx+ i 1)))))))

(define (vector-map proc . vecs)
  (if (null? (cdr vecs))
      (let* ((v (car vecs)) (n (vector-length v)) (out (make-vector n)))
        (let loop ((i 0))
          (if (fx<? i n)
              (begin (vector-set! out i (proc (vector-ref v i)))
                     (loop (fx+ i 1)))
              out)))
      (let* ((n (apply min (map vector-length vecs))) (out (make-vector n)))
        (let loop ((i 0))
          (if (fx<? i n)
              (begin (vector-set! out i (apply proc (map (lambda (v) (vector-ref v i)) vecs)))
                     (loop (fx+ i 1)))
              out)))))

(define list-sort r6sort:list-sort)
(define vector-sort r6sort:vector-sort)
(define vector-sort! r6sort:vector-sort!)

(define (printf fmt . args) (apply format #t fmt args))
(define (fprintf port fmt . args) (apply format port fmt args))

(define (subvector v start end)
  (let* ((len (fx- end start))
         (out (make-vector len)))
    (let loop ((i 0))
      (if (fx<? i len)
          (begin (vector-set! out i (vector-ref v (fx+ start i)))
                 (loop (fx+ i 1)))
          out))))

(define (vector-append . vecs)
  (let* ((total (apply + (map vector-length vecs)))
         (out (make-vector total)))
    (let vloop ((vs vecs) (dst 0))
      (if (null? vs)
          out
          (let* ((v (car vs))
                 (len (vector-length v)))
            (let iloop ((i 0))
              (if (fx<? i len)
                  (begin (vector-set! out (fx+ dst i) (vector-ref v i))
                         (iloop (fx+ i 1)))
                  (vloop (cdr vs) (fx+ dst len)))))))))

;; ---- Bytevectors & I/O ports -----------------------------------------------
(define make-bytevector r6bv:make-bytevector)
(define bytevector? r6bv:bytevector?)
(define bytevector-length r6bv:bytevector-length)
(define bytevector-u8-ref r6bv:bytevector-u8-ref)
(define bytevector-u8-set! r6bv:bytevector-u8-set!)
(define bytevector-s8-ref r6bv:bytevector-s8-ref)
(define bytevector-s8-set! r6bv:bytevector-s8-set!)
(define bytevector-u16-ref r6bv:bytevector-u16-ref)
(define bytevector-u16-set! r6bv:bytevector-u16-set!)
(define bytevector-u32-ref r6bv:bytevector-u32-ref)
(define bytevector-u32-set! r6bv:bytevector-u32-set!)
(define bytevector-u32-native-ref r6bv:bytevector-u32-native-ref)
(define bytevector-u32-native-set! r6bv:bytevector-u32-native-set!)
(define bytevector-u64-ref r6bv:bytevector-u64-ref)
(define bytevector-u64-set! r6bv:bytevector-u64-set!)
(define bytevector-u64-native-ref r6bv:bytevector-u64-native-ref)
(define bytevector-u64-native-set! r6bv:bytevector-u64-native-set!)
(define bytevector-s64-native-ref r6bv:bytevector-s64-native-ref)
(define bytevector-s64-native-set! r6bv:bytevector-s64-native-set!)
(define bytevector-ieee-single-native-ref r6bv:bytevector-ieee-single-native-ref)
(define bytevector-ieee-single-native-set! r6bv:bytevector-ieee-single-native-set!)
(define bytevector-ieee-double-native-ref r6bv:bytevector-ieee-double-native-ref)
(define bytevector-ieee-double-native-set! r6bv:bytevector-ieee-double-native-set!)
(define bytevector-ieee-single-ref r6bv:bytevector-ieee-single-ref)
(define bytevector-ieee-single-set! r6bv:bytevector-ieee-single-set!)
(define bytevector-ieee-double-ref r6bv:bytevector-ieee-double-ref)
(define bytevector-ieee-double-set! r6bv:bytevector-ieee-double-set!)
(define bytevector-copy r6bv:bytevector-copy)
(define bytevector-copy! r6bv:bytevector-copy!)
(define bytevector=? r6bv:bytevector=?)
(define bytevector->u8-list r6bv:bytevector->u8-list)
(define u8-list->bytevector r6bv:u8-list->bytevector)
(define string->utf8 r6bv:string->utf8)
(define utf8->string r6bv:utf8->string)
(define native-endianness r6bv:native-endianness)
(define-syntax endianness
  (syntax-rules ()
    ((_ e) (r6bv:endianness e))))

(define get-line r6io:get-line)
(define get-string-all r6io:get-string-all)
(define get-string-n r6io:get-string-n)
(define get-bytevector-all r6io:get-bytevector-all)
(define get-bytevector-n r6io:get-bytevector-n)
(define put-string r6io:put-string)
(define put-char r6io:put-char)
(define put-bytevector r6io:put-bytevector)
(define native-transcoder r6io:native-transcoder)
(define make-transcoder r6io:make-transcoder)
(define utf-8-codec r6io:utf-8-codec)
(define transcoded-port r6io:transcoded-port)
(define open-bytevector-input-port r6io:open-bytevector-input-port)
(define open-bytevector-output-port r6io:open-bytevector-output-port)
(define open-string-input-port r6io:open-string-input-port)
(define open-string-output-port r6io:open-string-output-port)
(define open-file-input-port r6io:open-file-input-port)
(define open-file-output-port r6io:open-file-output-port)
(define-syntax buffer-mode
  (syntax-rules ()
    ((_ m) (r6io:buffer-mode m))))
(define-syntax file-options
  (syntax-rules ()
    ((_ o ...) (r6io:file-options o ...))))

;; ---- Conditions & Exceptions (R6RS over Guile) -----------------------------
(define error
  (case-lambda
    ((msg) (r6base:error #f msg))
    ((who msg . irritants)
     (if (string? who)
         (r6base:error #f who msg irritants)
         (r6base:error who msg irritants)))))

;; ---- R6RS Hashtables + Guile Weak-Key Tables -------------------------------
;; Guile's (rnrs hashtables) does not support weak keys, and R6RS hashtable-*
;; procedures do not accept Guile's native make-weak-key-hash-table. Unify both
;; behind the R6RS surface while keeping every weak table a native weak-key table
;; (using an object property to distinguish weak eqv? vs weak eq? tables).
(define %ht-miss (list 'jolt-ht-miss))
(define %weak-ht-eqv? (make-object-property))

(define (make-weak-eq-hashtable . rest)
  (if (null? rest)
      (make-weak-key-hash-table)
      (make-weak-key-hash-table (car rest))))

(define (make-weak-eqv-hashtable . rest)
  (let ((t (if (null? rest)
               (make-weak-key-hash-table)
               (make-weak-key-hash-table (car rest)))))
    (set! (%weak-ht-eqv? t) #t)
    t))

(define (hashtable? obj)
  (or (r6ht:hashtable? obj) (weak-key-hash-table? obj)))

(define (make-eq-hashtable . rest) (apply r6ht:make-eq-hashtable rest))
(define (make-eqv-hashtable . rest) (apply r6ht:make-eqv-hashtable rest))
(define (make-hashtable h e . rest) (apply r6ht:make-hashtable h e rest))
(define equal-hash r6ht:equal-hash)
(define string-hash r6ht:string-hash)
(define string-ci-hash r6ht:string-ci-hash)
(define symbol-hash r6ht:symbol-hash)

(define (hashtable-ref ht k default)
  (cond
    ((r6ht:hashtable? ht) (r6ht:hashtable-ref ht k default))
    ((weak-key-hash-table? ht)
     (let ((v (if (%weak-ht-eqv? ht)
                  (hashv-ref ht k %ht-miss)
                  (hashq-ref ht k %ht-miss))))
       (if (eq? v %ht-miss) default v)))
    (else (error 'hashtable-ref "expected hashtable" ht))))

(define (hashtable-set! ht k v)
  (cond
    ((r6ht:hashtable? ht) (r6ht:hashtable-set! ht k v))
    ((weak-key-hash-table? ht)
     (if (%weak-ht-eqv? ht)
         (hashv-set! ht k v)
         (hashq-set! ht k v)))
    (else (error 'hashtable-set! "expected hashtable" ht))))

(define (hashtable-delete! ht k)
  (cond
    ((r6ht:hashtable? ht) (r6ht:hashtable-delete! ht k))
    ((weak-key-hash-table? ht)
     (if (%weak-ht-eqv? ht)
         (hashv-remove! ht k)
         (hashq-remove! ht k)))
    (else (error 'hashtable-delete! "expected hashtable" ht))))

(define (hashtable-contains? ht k)
  (cond
    ((r6ht:hashtable? ht) (r6ht:hashtable-contains? ht k))
    ((weak-key-hash-table? ht)
     (not (eq? (if (%weak-ht-eqv? ht)
                   (hashv-ref ht k %ht-miss)
                   (hashq-ref ht k %ht-miss))
               %ht-miss)))
    (else (error 'hashtable-contains? "expected hashtable" ht))))

(define (hashtable-update! ht k proc default)
  (if (r6ht:hashtable? ht)
      (r6ht:hashtable-update! ht k proc default)
      (hashtable-set! ht k (proc (hashtable-ref ht k default)))))

(define (hashtable-size ht)
  (cond
    ((r6ht:hashtable? ht) (r6ht:hashtable-size ht))
    ((weak-key-hash-table? ht) (hash-fold (lambda (key value count) (+ count 1)) 0 ht))
    (else (error 'hashtable-size "expected hashtable" ht))))

(define (hashtable-clear! ht . rest)
  (cond
    ((r6ht:hashtable? ht) (apply r6ht:hashtable-clear! ht rest))
    ((weak-key-hash-table? ht) (hash-clear! ht))
    (else (error 'hashtable-clear! "expected hashtable" ht))))

(define (hashtable-keys ht)
  (cond
    ((r6ht:hashtable? ht) (r6ht:hashtable-keys ht))
    ((weak-key-hash-table? ht)
     (list->vector (hash-map->list (lambda (k _v) k) ht)))
    (else (error 'hashtable-keys "expected hashtable" ht))))

(define (hashtable-entries ht)
  (cond
    ((r6ht:hashtable? ht) (r6ht:hashtable-entries ht))
    ((weak-key-hash-table? ht)
     (let* ((pairs (hash-map->list cons ht))
            (n (length pairs))
            (ks (make-vector n))
            (vs (make-vector n)))
       (let loop ((ps pairs) (i 0))
         (if (null? ps)
             (values ks vs)
             (begin
               (vector-set! ks i (caar ps))
               (vector-set! vs i (cdar ps))
               (loop (cdr ps) (fx+ i 1)))))))
    (else (error 'hashtable-entries "expected hashtable" ht))))

(define hashtable-copy
  (case-lambda
    ((ht) (hashtable-copy ht #f))
    ((ht mutable?)
     (if (r6ht:hashtable? ht)
         (r6ht:hashtable-copy ht mutable?)
         (let* ((eqv? (%weak-ht-eqv? ht))
                (copy (if eqv? (make-weak-eqv-hashtable) (make-weak-eq-hashtable))))
           (hash-for-each (lambda (k v) (hashtable-set! copy k v)) ht)
           copy)))))

(define (hashtable-equivalence-function ht)
  (cond
    ((r6ht:hashtable? ht) (r6ht:hashtable-equivalence-function ht))
    ((weak-key-hash-table? ht) (if (%weak-ht-eqv? ht) eqv? eq?))
    (else (error 'hashtable-equivalence-function "expected hashtable" ht))))

(define (hashtable-hash-function ht)
  (cond
    ((r6ht:hashtable? ht) (r6ht:hashtable-hash-function ht))
    ((weak-key-hash-table? ht) #f)
    (else (error 'hashtable-hash-function "expected hashtable" ht))))

(define (hashtable-mutable? ht)
  (cond
    ((r6ht:hashtable? ht) (r6ht:hashtable-mutable? ht))
    ((weak-key-hash-table? ht) #t)
    (else (error 'hashtable-mutable? "expected hashtable" ht))))

;; ---- R6RS Records with (ice-9 atomic) Mutable Field Boxes ------------------
;; Guile's core (record? x) returns #t on R6RS hashtables, so replace it with
;; (rnrs records inspection)'s record?. Mutable fields generated via
;; define-record-type are stored as (make-atomic-box init) in underlying R6RS
;; slots so sa-record-cas! operates on the exact same cell as generated
;; accessors and mutators.
(define record? r6i:record?)
(define record-rtd r6i:record-rtd)
(define record-type-descriptor? r6p:record-type-descriptor?)
(define record-type-name r6i:record-type-name)
(define record-type-parent r6i:record-type-parent)
(define record-type-uid r6i:record-type-uid)
(define record-type-generative? r6i:record-type-generative?)
(define record-type-sealed? r6i:record-type-sealed?)
(define record-type-opaque? r6i:record-type-opaque?)
(define record-type-field-names r6i:record-type-field-names)
(define record-predicate r6p:record-predicate)

(define %rtd-meta-mu (make-mutex 'allow-external-unlock))
;; rtd -> #(parent-rtd own-n total-n own-mut-vec flat-raw-acc-vec default-rcd wrapped-boxes?)
(define %rtd-meta-tbl (make-weak-key-hash-table))

(define (%rtd-meta-ref rtd)
  (dynamic-wind
    (lambda () (lock-mutex %rtd-meta-mu))
    (lambda () (hashq-ref %rtd-meta-tbl rtd #f))
    (lambda () (unlock-mutex %rtd-meta-mu))))

(define (%rtd-meta-set! rtd entry)
  (dynamic-wind
    (lambda () (lock-mutex %rtd-meta-mu))
    (lambda () (hashq-set! %rtd-meta-tbl rtd entry))
    (lambda () (unlock-mutex %rtd-meta-mu))))

(define (%rtd-build-meta rtd own-mut-vec default-rcd wrapped?)
  (let* ((parent (r6i:record-type-parent rtd))
         (pmeta (and parent (%rtd-meta-ref parent)))
         (p-accs (if pmeta
                     (vector-ref pmeta 4)
                     (if parent
                         (error 'define-record-type "parent rtd missing metadata" parent)
                         '#())))
         (p-n (vector-length p-accs))
         (own-n (vector-length own-mut-vec))
         (total-n (fx+ p-n own-n))
         (flat (make-vector total-n)))
    (let loop ((i 0))
      (when (fx<? i p-n)
        (vector-set! flat i (vector-ref p-accs i))
        (loop (fx+ i 1))))
    (let loop ((i 0))
      (when (fx<? i own-n)
        (vector-set! flat (fx+ p-n i) (r6p:record-accessor rtd i))
        (loop (fx+ i 1))))
    (let ((entry (vector parent own-n total-n own-mut-vec flat default-rcd wrapped?)))
      (%rtd-meta-set! rtd entry)
      entry)))

(define (%wrap-mutable-args args mut-list)
  (let loop ((as args) (ms mut-list) (acc '()))
    (if (null? as)
        (reverse acc)
        (loop (cdr as) (cdr ms)
              (cons (if (car ms) (make-atomic-box (car as)) (car as)) acc)))))

(define (%split-list-at lst n)
  (let loop ((xs lst) (k n) (acc '()))
    (if (zero? k)
        (values (reverse acc) xs)
        (loop (cdr xs) (fx- k 1) (cons (car xs) acc)))))

(define (%make-default-wrapping-protocol has-parent? own-n mut-list)
  (if has-parent?
      (lambda (n)
        (lambda all-args
          (let* ((total (length all-args))
                 (p-n (fx- total own-n)))
            (call-with-values
              (lambda () (%split-list-at all-args p-n))
              (lambda (p-args own-args)
                (apply (apply n p-args) (%wrap-mutable-args own-args mut-list)))))))
      (lambda (n)
        (lambda own-args
          (apply n (%wrap-mutable-args own-args mut-list))))))

(define (%wrap-user-protocol has-parent? mut-list user-proto)
  (lambda (raw-n)
    (let ((wrapped-n
            (if has-parent?
                (lambda p-args
                  (let ((ctor-for-own (apply raw-n p-args)))
                    (lambda own-args
                      (apply ctor-for-own (%wrap-mutable-args own-args mut-list)))))
                (lambda own-args
                  (apply raw-n (%wrap-mutable-args own-args mut-list))))))
      (user-proto wrapped-n))))

(define (%rtd-register-synthetic! name parent-rtd parent-rcd uid sealed? opaque? own-mut-list field-specs proto-or-false)
  (let* ((mut-vec (list->vector own-mut-list))
         (rtd (r6p:make-record-type-descriptor
                name parent-rtd uid sealed? opaque? (list->vector field-specs)))
         (has-parent? (and parent-rtd #t))
         (own-n (vector-length mut-vec))
         (proto (if proto-or-false
                    (%wrap-user-protocol has-parent? own-mut-list proto-or-false)
                    (%make-default-wrapping-protocol has-parent? own-n own-mut-list)))
         (rcd (r6p:make-record-constructor-descriptor rtd parent-rcd proto)))
    (%rtd-build-meta rtd mut-vec rcd #t)
    (values rtd rcd)))

(define (%wrapped-accessor rtd idx)
  (let ((raw (r6p:record-accessor rtd idx))
        (meta (%rtd-meta-ref rtd)))
    (if (and meta (vector-ref meta 6) (vector-ref (vector-ref meta 3) idx))
        (lambda (r) (atomic-box-ref (raw r)))
        raw)))

(define (%wrapped-mutator rtd idx)
  (let ((meta (%rtd-meta-ref rtd)))
    (if (and meta (vector-ref meta 6))
        (if (vector-ref (vector-ref meta 3) idx)
            (let ((raw (r6p:record-accessor rtd idx)))
              (lambda (r v) (atomic-box-set! (raw r) v)))
            (error 'record-mutator "record field is immutable" rtd idx))
        (r6p:record-mutator rtd idx))))

(define (make-record-constructor-descriptor rtd parent-rcd proto)
  (r6p:make-record-constructor-descriptor rtd parent-rcd proto))

(define (record-constructor x)
  (if (r6p:record-type-descriptor? x)
      (let ((meta (%rtd-meta-ref x)))
        (r6p:record-constructor
          (if meta (vector-ref meta 5) (r6p:make-record-constructor-descriptor x #f #f))))
      (r6p:record-constructor x)))

(define (record-accessor rtd k) (%wrapped-accessor rtd k))
(define (record-mutator rtd k) (%wrapped-mutator rtd k))

(define (record-field-mutable? rtd k)
  (let ((meta (%rtd-meta-ref rtd)))
    (if meta
        (vector-ref (vector-ref meta 3) k)
        (r6i:record-field-mutable? rtd k))))

(define-syntax record-type-descriptor
  (lambda (stx)
    (syntax-case stx ()
      ((_ name)
       (datum->syntax #'name
         (string->symbol
           (string-append "%jolt-rtd:" (symbol->string (syntax->datum #'name)))))))))

(define-syntax record-constructor-descriptor
  (lambda (stx)
    (syntax-case stx ()
      ((_ name)
       (datum->syntax #'name
         (string->symbol
           (string-append "%jolt-rcd:" (symbol->string (syntax->datum #'name)))))))))

(define (syntax->list x)
  (syntax-case x ()
    (() '())
    ((a . d) (cons #'a (syntax->list #'d)))))

(define-syntax define-record-type
  (lambda (stx)
    (define (sym . parts)
      (string->symbol
        (apply string-append
               (map (lambda (p) (if (symbol? p) (symbol->string p) p)) parts))))
    (define (stx->list x)
      (syntax-case x ()
        (() '())
        ((a . d) (cons #'a (stx->list #'d)))))
    (define (parse-header hdr)
      (syntax-case hdr ()
        ((name ctor pred)
         (and (identifier? #'name) (identifier? #'ctor) (identifier? #'pred))
         (values #'name #'ctor #'pred))
        (name
         (identifier? #'name)
         (let ((n (syntax->datum #'name)))
           (values #'name
                   (datum->syntax #'name (sym "make-" n))
                   (datum->syntax #'name (sym n "?")))))))
    (define (parse-fields rname-sym specs)
      (let loop ((ss specs) (i 0) (raw-specs '()) (muts '()) (defs '()))
        (if (null? ss)
            (values (reverse raw-specs) (reverse muts) (reverse defs))
            (syntax-case (car ss) (immutable mutable)
              ((immutable f acc)
               (loop (cdr ss) (fx+ i 1)
                     (cons `(immutable ,(syntax->datum #'f)) raw-specs)
                     (cons #f muts)
                     (cons (list #'acc i #f) defs)))
              ((immutable f)
               (let ((acc (datum->syntax #'f (sym rname-sym "-" (syntax->datum #'f)))))
                 (loop (cdr ss) (fx+ i 1)
                       (cons `(immutable ,(syntax->datum #'f)) raw-specs)
                       (cons #f muts)
                       (cons (list acc i #f) defs))))
              ((mutable f acc mut)
               (loop (cdr ss) (fx+ i 1)
                     ;; Store atomic-box in an immutable underlying R6RS slot.
                     (cons `(immutable ,(syntax->datum #'f)) raw-specs)
                     (cons #t muts)
                     (cons (list #'acc i #'mut) defs)))
              ((mutable f)
               (let ((fn (syntax->datum #'f)))
                 (loop (cdr ss) (fx+ i 1)
                       (cons `(immutable ,fn) raw-specs)
                       (cons #t muts)
                       (cons (list (datum->syntax #'f (sym rname-sym "-" fn))
                                   i
                                   (datum->syntax #'f (sym rname-sym "-" fn "-set!")))
                             defs))))
              (f
               (identifier? #'f)
               (let ((acc (datum->syntax #'f (sym rname-sym "-" (syntax->datum #'f)))))
                 (loop (cdr ss) (fx+ i 1)
                       (cons `(immutable ,(syntax->datum #'f)) raw-specs)
                       (cons #f muts)
                       (cons (list acc i #f) defs))))))))
    (syntax-case stx ()
      ((_ hdr clause ...)
       (let-values (((rname-stx ctor-stx pred-stx) (parse-header #'hdr)))
         (let ((parent-rtd-expr #'#f)
               (parent-rcd-expr #'#f)
               (uid-expr #'#f)
               (sealed-expr #'#f)
               (opaque-expr #'#f)
               (proto-expr #'#f)
               (fields-list '()))
           (for-each
             (lambda (cl)
               (syntax-case cl (fields parent parent-rtd protocol sealed opaque nongenerative)
                 ((fields sp ...)
                  (set! fields-list (append fields-list (stx->list #'(sp ...)))))
                 ((parent pname)
                  (begin
                    (set! parent-rtd-expr #'(record-type-descriptor pname))
                    (set! parent-rcd-expr #'(record-constructor-descriptor pname))))
                 ((parent-rtd prtd prcd)
                  (begin
                    (set! parent-rtd-expr #'prtd)
                    (set! parent-rcd-expr #'prcd)))
                 ((protocol p) (set! proto-expr #'p))
                 ((sealed b) (set! sealed-expr #'b))
                 ((opaque b) (set! opaque-expr #'b))
                 ((nongenerative uid)
                  (with-syntax ((u #'uid))
                    (set! uid-expr #'(quote u))))
                 ((nongenerative)
                  (with-syntax ((u (datum->syntax rname-stx
                                     (gensym (symbol->string (syntax->datum rname-stx))))))
                    (set! uid-expr #'(quote u))))))
             (stx->list #'(clause ...)))
           (let ((rname-sym (syntax->datum rname-stx)))
             (let-values (((raw-specs muts accessor-specs) (parse-fields rname-sym fields-list)))
               (with-syntax
                 ((rtd-id (datum->syntax rname-stx (sym "%jolt-rtd:" rname-sym)))
                  (rcd-id (datum->syntax rname-stx (sym "%jolt-rcd:" rname-sym)))
                  (init-id (datum->syntax rname-stx (sym "%jolt-rec-init:" rname-sym)))
                  (rname-lit rname-stx)
                  (prtd parent-rtd-expr)
                  (prcd parent-rcd-expr)
                  (uid-ex uid-expr)
                  (sealed-ex sealed-expr)
                  (opaque-ex opaque-expr)
                  (proto-ex proto-expr)
                  (ctor ctor-stx)
                  (pred pred-stx)
                  (muts-lit (datum->syntax rname-stx muts))
                  (fspecs-lit (datum->syntax rname-stx raw-specs)))
                 (with-syntax
                   (((acc-def ...)
                     (apply append
                            (map (lambda (spec)
                                   (with-syntax ((acc (car spec))
                                                 (idx (datum->syntax rname-stx (cadr spec))))
                                     (if (caddr spec)
                                         (with-syntax ((mut (caddr spec)))
                                           (list #'(define acc (%wrapped-accessor rtd-id idx))
                                                 #'(define mut (%wrapped-mutator rtd-id idx))))
                                         (list #'(define acc (%wrapped-accessor rtd-id idx))))))
                                 accessor-specs))))
                   #'(begin
                       (define rtd-id #f)
                       (define rcd-id #f)
                       (define init-id
                         (call-with-values
                           (lambda ()
                             (%rtd-register-synthetic!
                               (quote rname-lit) prtd prcd uid-ex sealed-ex opaque-ex
                               (quote muts-lit) (quote fspecs-lit) proto-ex))
                           (lambda (r c) (set! rtd-id r) (set! rcd-id c))))
                       (define ctor (record-constructor rcd-id))
                       (define pred (record-predicate rtd-id))
                       acc-def ...)))))))))))

;; ---- Counting lock shims needed by values.ss and shared runtime ------------
(define jolt-mutex-allocations (box 0))
(define (jolt-count-mutex!)
  (let retry ()
    (let ((n (unbox jolt-mutex-allocations)))
      (unless (sa-box-cas! jolt-mutex-allocations n (fx+ n 1))
        (retry)))))

(define-syntax jolt-locks-held
  (syntax-rules ()
    ((_) (virtual-register 7))))

(define (jolt-locks-enter!)
  (set-virtual-register! 7 (fx+ (jolt-locks-held) 1)))

(define (jolt-locks-exit!)
  (set-virtual-register! 7 (fx- (jolt-locks-held) 1)))

(define (jolt-locks-assert-none! who)
  (let ((n (jolt-locks-held)))
    (when (fx>? n 0)
      (error who "lock count nonzero while parking" n))))

(define-syntax jolt-masked-body
  (syntax-rules ()
    ((_ thunk)
     (lambda () (jolt-locks-exit!) (let ((r (thunk))) (jolt-locks-enter!) r)))))

(define-syntax jolt-masked-after
  (syntax-rules ()
    ((_ lv e ...)
     (lambda () e ... (when (fx>? (jolt-locks-held) lv) (jolt-locks-exit!))))))

(define-syntax jolt-masked-cleanup
  (syntax-rules ()
    ((_ lv e ...)
     (lambda ()
       (if (fx>? (jolt-locks-held) lv)
           (dynamic-wind void (lambda () e ...) (lambda () (jolt-locks-exit!)))
           (begin e ...))))))

(define (jolt-lock! mu . rest)
  (let ((block? (if (null? rest) #t (car rest))))
    (jolt-locks-enter!)
    (if block?
        (begin (lock-mutex mu) #t)
        (let ((got (try-mutex mu)))
          (unless got (jolt-locks-exit!))
          got))))

(define (jolt-unlock! mu)
  (unlock-mutex mu)
  (jolt-locks-exit!))

(define-syntax jolt-with-mutex
  (syntax-rules ()
    ((_ mu b0 b ...)
     (let ((m mu))
       (dynamic-wind
         (lambda () (jolt-lock! m))
         (lambda () b0 b ...)
         (lambda () (jolt-unlock! m)))))))

;; The portable collection registry uses identity keys.
(define (make-ephemeron-eq-hashtable) (make-weak-eq-hashtable))

(define-syntax jolt-site-kept
  (syntax-rules ()
    ((_ expression)
     (let* ((site (virtual-register 2))
            (result expression))
       (set-virtual-register! 2 site)
       result))))

(define-syntax jolt-wind*
  (syntax-rules ()
    ((_ before setup body after)
     (let ((lv (jolt-locks-held)))
       (jolt-locks-enter!)
       setup
       (dynamic-wind before (jolt-masked-body body) (jolt-masked-cleanup lv after))))))


(define exact inexact->exact)
(define inexact exact->inexact)
(define infinite? inf?)
(define (bignum? value) (and (exact-integer? value) (not (fixnum? value))))
(define (flush-output-port port) (force-output port))
(define (display-condition condition port)
  (if (message-condition? condition)
      (display (condition-message condition) port)
      (write condition port)))
(define (flsingle value)
  (let ((bytes (make-bytevector 4)))
    (bytevector-ieee-single-native-set! bytes 0 value)
    (bytevector-ieee-single-native-ref bytes 0)))
(define jolt-s64-add-wrap #f)
(define jolt-s64-sub-wrap #f)
(define jolt-s64-mul-wrap #f)


;; Guile attaches locations while reading from a named port.
(define (make-source-file-descriptor name bytes)
  (close-port bytes)
  name)
(define (get-datum/annotations port source offset)
  (call-with-port port
    (lambda (input)
      (set-port-filename! input source)
      ;; The transcoded port provides syntax locations, but is not seekable.
      (values (read-syntax input) #f))))
