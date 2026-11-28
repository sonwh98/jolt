(define class-statics-tbl (make-hashtable string-hash string=?))
(define (short-class-name s)
  (let loop ((i (- (string-length s) 1)))
    (cond ((< i 0) s)
          ((char=? (string-ref s i) #\.) (substring s (+ i 1) (string-length s)))
          (else (loop (- i 1))))))
(define (register-class-statics! name members)
  (let ((h (or (hashtable-ref class-statics-tbl name #f)
               (hashtable-ref class-statics-tbl (short-class-name name) #f)
               (make-hashtable string-hash string=?))))
    (hashtable-set! class-statics-tbl name h)
    (unless (string=? name (short-class-name name))
      (hashtable-set! class-statics-tbl (short-class-name name) h))
    (for-each (lambda (p) (hashtable-set! h (car p) (cdr p))) members)))
;; The two are one procedure here. On Chez they differ only in whether the class
;; is also recorded as one the RUNTIME provides (host-static.ss), and the gambit
;; boot has no provider registry to ask — records-dispatch.ss's defrecord
;; `create` takes the merge, so the name has to exist.
(define (class-statics-merge! name members) (register-class-statics! name members))
(define (make-arity-wrapper-procedure wrapper wrapped) wrapper)
(define register-class-ctor! class-ctor-set!)
(define (host-class-registered? name)
  (and (hashtable-ref class-ctors-tbl name #f) #t))
(define (host-class-has-statics? name)
  (and (hashtable-ref class-statics-tbl name #f) #t))
(define current-directory getcwd)
(define (subvector-move! from start end to offset)
  (vector-copy! to offset (vector-copy from start end)))
(define (subu8vector-move! from start end to offset)
  (r6bv:bytevector-copy! from start to offset (- end start)))
(define (joltffi-public-blocking-raise)
  (throw-jvm 'UnsupportedOperationException
    "filesystem operations on java.io.File are unsupported on the guile target"))
(%jolt-load-guile "../gambit/host-statics.ss")
(define (host-arity-like procedure wrapper) wrapper)
(define (class-statics-member-set! table member value)
  (hashtable-set! table member value))


(define class-methods-tbl (make-hashtable string-hash string=?))
(define class-methods-mu (make-mutex))
(define (register-class-methods! tag methods)
  (jolt-with-mutex class-methods-mu
    (hashtable-set! class-methods-tbl tag methods)))
