#!no-fold-case
;; host/guile/hasheq.ss — Checked 32-bit Clojure-parity hasheq engine for Guile 3.0.11.
;; Produces bit-exact JVM Murmur3/hashCombine/double/BigInteger/coll hashes while
;; keeping identity & seq hash caches thread-safe under Guile's weak-key tables.

;; 32-bit signed/unsigned fixnum helpers (safe in Guile 64-bit 62-bit fixnums).
(define (u32 x)
  (if (fixnum? x)
      (fxand x #xffffffff)
      (bitwise-and x #xffffffff)))

(define (i32 x)
  (let ((u (u32 x)))
    (if (fx>=? u #x80000000)
        (fx- u #x100000000)
        u)))

(define-syntax mulu32
  (syntax-rules ()
    ((_ a b)
     (let ((a* (u32 a)) (b* (u32 b)))
       (u32 (fx+ (fxsll (fxand (fx* a* (fxarithmetic-shift-right b* 16)) #xFFFF) 16)
                 (fx* a* (fxand b* #xFFFF))))))))

(define-syntax mul32
  (syntax-rules ()
    ((_ a b) (i32 (mulu32 a b)))))

(define-syntax add32
  (syntax-rules ()
    ((_ a b) (i32 (fx+ (u32 a) (u32 b))))))

(define-syntax addu32
  (syntax-rules ()
    ((_ a b) (u32 (fx+ (u32 a) (u32 b))))))

(define-syntax urs32
  (syntax-rules ()
    ((_ x n) (i32 (fxarithmetic-shift-right (u32 x) n)))))

(define-syntax rotlu32
  (syntax-rules ()
    ((_ x n)
     (let ((x* (u32 x)))
       (u32 (fxior (fxsll (fxand x* (fxarithmetic-shift-right #xffffffff n)) n)
                   (fxarithmetic-shift-right x* (fx- 32 n))))))))

(define-syntax rotl32
  (syntax-rules ()
    ((_ x n) (i32 (rotlu32 x n)))))

(define murmur3-seed 0)
(define murmur3-C1 #xcc9e2d51)
(define murmur3-C2 #x1b873593)

(define (murmur3-mix-k1 k1)
  (let* ((k1 (mul32 k1 murmur3-C1))
         (k1 (rotl32 k1 15)))
    (mul32 k1 murmur3-C2)))

(define (murmur3-mix-h1 h1 k1)
  (let* ((h1 (fxxor h1 k1))
         (h1 (rotl32 h1 13)))
    (add32 (mul32 h1 5) #xe6546b64)))

(define (murmur3-fmix h1 len)
  (let* ((h1 (fxxor h1 len))
         (h1 (fxxor h1 (urs32 h1 16)))
         (h1 (mul32 h1 #x85ebca6b))
         (h1 (fxxor h1 (urs32 h1 13)))
         (h1 (mul32 h1 #xc2b2ae35))
         (h1 (fxxor h1 (urs32 h1 16))))
    h1))

(define-syntax murmur3-mix-k1-flat
  (syntax-rules ()
    ((_ k)
     (let* ((k1 (mul32 k murmur3-C1))
            (k1 (rotl32 k1 15)))
       (mul32 k1 murmur3-C2)))))

(define-syntax murmur3-mix-h1-flat
  (syntax-rules ()
    ((_ h k)
     (let* ((h1 (fxxor h k))
            (h1 (rotl32 h1 13)))
       (add32 (mul32 h1 5) #xe6546b64)))))

(define-syntax murmur3-fmix-flat
  (syntax-rules ()
    ((_ h len)
     (let* ((h1 (fxxor h len))
            (h1 (fxxor h1 (urs32 h1 16)))
            (h1 (mul32 h1 #x85ebca6b))
            (h1 (fxxor h1 (urs32 h1 13)))
            (h1 (mul32 h1 #xc2b2ae35)))
       (fxxor h1 (urs32 h1 16))))))

(define murmur3-mixed-high-minus-one
  (mulu32 (rotlu32 (mulu32 #xffffffff murmur3-C1) 15) murmur3-C2))

(define (murmur3-hash-fixnum-u32 input)
  (if (fx=? input 0)
      0
      (let* ((low (u32 input))
             (high (fxsra input 32))
             (k1 (mulu32 (rotlu32 (mulu32 low murmur3-C1) 15) murmur3-C2))
             (h1 (addu32 (mulu32 (rotlu32 k1 13) 5) #xe6546b64))
             (k1 (cond ((fx=? high 0) 0)
                       ((fx=? high -1) murmur3-mixed-high-minus-one)
                       (else (mulu32 (rotlu32 (mulu32 (u32 high) murmur3-C1) 15) murmur3-C2))))
             (h1 (addu32 (mulu32 (rotlu32 (fxxor (u32 h1) k1) 13) 5) #xe6546b64))
             (h1 (fxxor h1 8))
             (h1 (fxxor h1 (fxarithmetic-shift-right h1 16)))
             (h1 (mulu32 h1 #x85ebca6b))
             (h1 (fxxor h1 (fxarithmetic-shift-right h1 13)))
             (h1 (mulu32 h1 #xc2b2ae35)))
        (fxxor h1 (fxarithmetic-shift-right h1 16)))))

(define (murmur3-hash-long-flat input)
  (i32 (murmur3-hash-fixnum-u32 input)))

(define (murmur3-hash-int input)
  (if (fx=? (i32 input) 0)
      0
      (let* ((k1 (murmur3-mix-k1 (i32 input)))
             (h1 (murmur3-mix-h1 murmur3-seed k1)))
        (murmur3-fmix h1 4))))

(define (murmur3-hash-long input)
  (if (= input 0)
      0
      (if (fixnum? input)
          (murmur3-hash-long-flat input)
          (let* ((u64 (bitwise-and input #xFFFFFFFFFFFFFFFF))
                 (low (i32 u64))
                 (high (i32 (bitwise-arithmetic-shift-right u64 32)))
                 (k1 (murmur3-mix-k1 low))
                 (h1 (murmur3-mix-h1 murmur3-seed k1))
                 (k1 (murmur3-mix-k1 high))
                 (h1 (murmur3-mix-h1 h1 k1)))
            (murmur3-fmix h1 8)))))

;; ---- Strings (Java String.hashCode & Murmur3.hashUnencodedChars) -----------
(define (java-string-hashcode s)
  (let ((len (string-length s)))
    (let loop ((i 0) (h 0))
      (if (fx>=? i len)
          (i32 h)
          (let ((cp (char->integer (string-ref s i))))
            (if (fx<? cp #x10000)
                (loop (fx+ i 1) (i32 (fx+ (fx* 31 h) cp)))
                (let* ((cp2 (fx- cp #x10000))
                       (high (fxior #xD800 (fxsra cp2 10)))
                       (low  (fxior #xDC00 (fxand cp2 #x3FF)))
                       (h* (i32 (fx+ (fx* 31 h) high))))
                  (loop (fx+ i 1) (i32 (fx+ (fx* 31 h*) low))))))))))

(define (murmur3-hash-unencoded-chars s)
  (let ((len (string-length s)))
    (let loop ((i 0) (h1 murmur3-seed) (pending #f) (count 0))
      (if (fx>=? i len)
          (if pending
              (let* ((k1 (murmur3-mix-k1-flat pending))
                     (h1 (fxxor h1 k1)))
                (murmur3-fmix-flat h1 (fx* 2 (fx+ count 1))))
              (murmur3-fmix-flat h1 (fx* 2 count)))
          (let ((cp (char->integer (string-ref s i))))
            (if (fx<? cp #x10000)
                (if pending
                    (let* ((k1 (murmur3-mix-k1-flat (fxior pending (fxsll cp 16))))
                           (h1 (murmur3-mix-h1-flat h1 k1)))
                      (loop (fx+ i 1) h1 #f (fx+ count 2)))
                    (loop (fx+ i 1) h1 cp count))
                (let* ((cp2 (fx- cp #x10000))
                       (high (fxior #xD800 (fxsra cp2 10)))
                       (low  (fxior #xDC00 (fxand cp2 #x3FF))))
                  (if pending
                      (let* ((k1 (murmur3-mix-k1-flat (fxior pending (fxsll high 16))))
                             (h1 (murmur3-mix-h1-flat h1 k1)))
                        (loop (fx+ i 1) h1 low (fx+ count 2)))
                      (let* ((k1 (murmur3-mix-k1-flat (fxior high (fxsll low 16))))
                             (h1 (murmur3-mix-h1-flat h1 k1)))
                        (loop (fx+ i 1) h1 #f (fx+ count 2)))))))))))

;; ---- BigInteger / Double / Collection mixers / hashCombine -----------------
(define (big-integer-hashcode x)
  (let* ((signum (cond ((< x 0) -1) ((= x 0) 0) (else 1)))
         (mag (abs x)))
    (if (= mag 0)
        0
        (let* ((nbits (bitwise-length mag))
               (nlimbs (fx+ (fxquotient (fx- nbits 1) 32) 1))
               (shift0 (fx* (fx- nlimbs 1) 32)))
          (let loop ((i 0) (h 0) (shift shift0))
            (if (fx>=? i nlimbs)
                (i32 (* signum h))
                (let ((limb (u32 (bitwise-arithmetic-shift-right mag shift))))
                  (loop (fx+ i 1)
                        (i32 (+ (* 31 h) limb))
                        (fx- shift 32)))))))))

(define (double-to-raw-bits x)
  (sa-flonum->bits x))

(define (double-hasheq x)
  ;; -0.0 -> 0; else (int)(bits ^ (bits >>> 32))
  (if (and (flonum? x) (fl=? x 0.0) (fl=? (fl/ x 1.0) -0.0))
      0
      (let ((bits (double-to-raw-bits x)))
        (i32 (bitwise-xor bits (bitwise-arithmetic-shift-right bits 32))))))

(define (mix-coll-hash hash count)
  (let* ((k1 (murmur3-mix-k1 (i32 hash)))
         (h1 (murmur3-mix-h1 murmur3-seed k1)))
    (murmur3-fmix h1 count)))

(define (hash-ordered xs)
  (let loop ((xs xs) (n 0) (h 1))
    (if (jolt-nil? xs)
        (mix-coll-hash h n)
        (loop (jolt-seq (seq-more xs))
              (fx+ n 1)
              (i32 (fx+ (fx* 31 h) (jolt-hasheq (seq-first xs))))))))

(define (entry-hasheq k v)
  (let* ((h1 (i32 (fx+ 31 (jolt-hasheq k))))
         (h2 (i32 (fx+ (fx* 31 h1) (jolt-hasheq v)))))
    (mix-coll-hash h2 2)))

(define (hash-unordered xs)
  (let loop ((xs xs) (n 0) (h 0))
    (if (jolt-nil? xs)
        (mix-coll-hash h n)
        (let ((e (seq-first xs)))
          (loop (jolt-seq (seq-more xs))
                (fx+ n 1)
                (add32 h (if (pair? e)
                             (entry-hasheq (car e) (cdr e))
                             (jolt-hasheq e))))))))

(define (hash-combine seed hash)
  (let* ((seed (i32 seed))
         (hash (i32 hash))
         (sl (i32 (fxsll seed 6)))
         (sr (fxsra seed 2))
         (sum (i32 (fx+ (i32 (fx+ hash #x9e3779b9)) (i32 (fx+ sl sr))))))
    (i32 (fxxor seed sum))))

;; ---- Keyword / Symbol / String / Identity / Seq hasheq caches --------------
(define (compute-keyword-hasheq ns name)
  (let ((ns-hash (if (or (not ns) (eq? ns '()))
                     0
                     (java-string-hashcode ns))))
    (i32 (+ (hash-combine (murmur3-hash-unencoded-chars name) ns-hash)
            #x9e3779b9))))

(define (compute-symbol-hasheq ns name)
  (let ((ns-hash (if (or (jolt-nil? ns) (not ns) (eq? ns '()))
                     0
                     (java-string-hashcode ns))))
    (hash-combine (murmur3-hash-unencoded-chars name) ns-hash)))

(define (symstr-mhash! c)
  (or (symstr-mhash c)
      (let ((h (murmur3-hash-unencoded-chars (symstr-str c))))
        (symstr-mhash-set! c h)
        h)))

(define (symbol-hasheq sym)
  (or (symbol-t-khash sym)
      (let* ((c (symbol-t-ncell sym))
             (ns (symbol-t-ns sym))
             (h (if c
                    (hash-combine (symstr-mhash! c)
                                  (if (string? ns) (java-string-hashcode ns) 0))
                    (compute-symbol-hasheq ns (symbol-t-name sym)))))
        (symbol-t-khash-set! sym h)
        h)))

;; Per-thread weak string-hasheq cache stored in vreg 5 (fork-isolated).
(define jolt-vreg-hasheq-caches 5)

(define (hasheq-caches)
  (let ((c (virtual-register jolt-vreg-hasheq-caches)))
    (if (pair? c)
        c
        (let ((v (cons #f (make-weak-eq-hashtable 8192))))
          (set-virtual-register! jolt-vreg-hasheq-caches v)
          v))))

(define (compute-string-hasheq s)
  (murmur3-hash-int (java-string-hashcode s)))

(define (string-hasheq s)
  (let ((tbl (cdr (hasheq-caches))))
    (or (hashtable-ref tbl s #f)
        (let ((h (compute-string-hasheq s)))
          (hashtable-set! tbl s h)
          h))))

(define jolt-hasheq-arms '())

(define proc-hasheq-tbl (make-weak-eq-hashtable))
(define proc-hasheq-mu (make-mutex))
(define proc-hasheq-counter 0)

(define (identity-hash-id n)
  (fxand (murmur3-hash-long-flat n) #x7fffffff))

(define (jolt-identity-hasheq p)
  (jolt-with-mutex proc-hasheq-mu
    (or (hashtable-ref proc-hasheq-tbl p #f)
        (let* ((n (fx+ proc-hasheq-counter 1))
               (_ (set! proc-hasheq-counter n))
               (h (identity-hash-id n)))
          (hashtable-set! proc-hasheq-tbl p h)
          h))))

(define (procedure-hasheq p) (jolt-identity-hasheq p))

(define (jolt-identity-hasheq-seed! p h)
  (jolt-with-mutex proc-hasheq-mu
    (hashtable-set! proc-hasheq-tbl p h)))

(define (pvec-hasheq-cached p)
  (let ((c (pvec-hasheq p)))
    (if (and (fixnum? c) (not (fx=? c 0)))
        c
        (let ((n (pvec-count p)))
          (let loop ((i 0) (h 1))
            (if (fx=? i n)
                (let ((r (mix-coll-hash h n)))
                  (pvec-hasheq-set! p r)
                  r)
                (let-values (((leaf off) (pv-leaf-for p i)))
                  (let ((run (fxmin (fx- (vector-length leaf) off) (fx- n i))))
                    (let cloop ((j 0) (h h))
                      (if (fx>=? j run)
                          (loop (fx+ i run) h)
                          (cloop (fx+ j 1)
                                 (i32 (fx+ (fx* 31 h)
                                           (jolt-hasheq (vector-ref leaf (fx+ off j))))))))))))))))

(define seq-hasheq-tbl (make-weak-eq-hashtable))
(define seq-hasheq-mu (make-mutex))

(define (seq-hasheq-cached x)
  (if (or (cseq? x) (jolt-lazyseq? x))
      (or (jolt-with-mutex seq-hasheq-mu (hashtable-ref seq-hasheq-tbl x #f))
          (let ((h (let ((s (jolt-seq x)))
                     (seq-hash-refuse-unbounded! s)
                     (hash-ordered s))))
            (jolt-with-mutex seq-hasheq-mu (hashtable-set! seq-hasheq-tbl x h))
            h))
      (hash-ordered (jolt-seq x))))

(define (jolt-hasheq x)
  (cond
    ((jolt-nil? x) 0)
    ((keyword? x) (keyword-t-khash x))
    ((jolt-symbol? x) (symbol-hasheq x))
    ((fixnum? x) (murmur3-hash-long-flat x))
    ((string? x) (string-hasheq x))
    ((char? x) (char->integer x))
    ((pvec? x) (pvec-hasheq-cached x))
    ((jolt-sequential? x) (seq-hasheq-cached x))
    ((pmap? x) (jolt-hasheq-fallback x))
    ((pset? x) (jolt-hasheq-fallback x))
    ((jrec? x) (jrec-hasheq-fast x))
    ((procedure? x) (procedure-hasheq x))
    (else
     (let loop ((as jolt-hasheq-arms))
       (cond ((null? as)
              (let loop2 ((bs jolt-hash-arms))
                (cond ((null? bs) (jolt-hasheq-fallback x))
                      (((caar bs) x) (i32 ((cdar bs) x)))
                      (else (loop2 (cdr bs))))))
             (((caar as) x) ((cdar as) x))
             (else (loop (cdr as))))))))

(define (jolt-hasheq-fallback x)
  (cond
    ((number? x)
     (cond
       ((flonum? x) (double-hasheq x))
       ((and (exact? x) (not (integer? x)))
        (i32 (bitwise-xor (big-integer-hashcode (numerator x))
                          (big-integer-hashcode (denominator x)))))
       ((and (exact? x) (integer? x)
             (>= x -9223372036854775808) (<= x 9223372036854775807))
        (murmur3-hash-long x))
       (else (big-integer-hashcode x))))
    ((boolean? x) (if x 1231 1237))
    ((char? x) (char->integer x))
    ((jolt-symbol? x) (symbol-hasheq x))
    ((jolt-sequential? x) (seq-hasheq-cached x))
    ((pmap? x)
     (or (and (not (= 0 (pmap-hasheq x))) (pmap-hasheq x))
         (let* ((result (pmap-fold x
                          (lambda (k v acc)
                            (cons (add32 (car acc) (entry-hasheq k v))
                                  (fx+ (cdr acc) 1)))
                          (cons 0 0)))
                (h (mix-coll-hash (car result) (cdr result))))
           (pmap-hasheq-set! x h)
           h)))
    ((pset? x)
     (or (and (not (= 0 (pset-hasheq x))) (pset-hasheq x))
         (let* ((result (pset-fold x
                          (lambda (e acc) (cons (add32 (car acc) (jolt-hasheq e)) (fx+ (cdr acc) 1)))
                          (cons 0 0)))
                (h (mix-coll-hash (car result) (cdr result))))
           (pset-hasheq-set! x h)
           h)))
    ((procedure? x) (procedure-hasheq x))
    ((and (record? x) (not (eq-arm-claims? x))) (jolt-identity-hasheq x))
    (else (i32 (equal-hash x)))))

(define (declared-hash-int v)
  (cond ((and (number? v) (exact? v) (integer? v)) (i32 v))
        ((and (flonum? v) (finite? v)) (i32 (exact (truncate v))))
        (else v)))

(define (call-declared-hash m x) (declared-hash-int (jolt-invoke m x)))

(define (jolt-identity-hashed? x)
  (and (record? x)
       (not (or (jolt-nil? x) (keyword? x) (jolt-symbol? x) (pvec? x) (pmap? x) (pset? x)
                (jolt-sequential? x) (jrec? x)))
       (not (exists (lambda (a) ((car a) x)) jolt-hasheq-arms))
       (not (exists (lambda (a) ((car a) x)) jolt-hash-arms))
       (not (eq-arm-claims? x))))

(define (eq-arm-claims? x) (exists (lambda (a) ((car a) x x)) jolt-eq-arms))
