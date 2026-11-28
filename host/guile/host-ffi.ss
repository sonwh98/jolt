;; Public FFI is reserved for qualification after the adapter gate slice.
(define (guile-ffi-refusal name)
  (lambda args
    (throw-jvm 'UnsupportedOperationException
      (string-append name ": user FFI is unsupported on the guile target"))))

(for-each (lambda (name)
            (def-var! "jolt.ffi" name
              (guile-ffi-refusal (string-append "jolt.ffi/" name))))
  '(
    "load-library"
    "loaded?"
    "load-system-library"
    "system-library-candidates"
    "load-failure-note"
    "find-symbol"
    "dlsym-native"
    "defining-libraries"
    "alloc"
    "free"
    "__alloc"
    "__free"
    "__calloc"
    "read"
    "write"
    "__read"
    "__write"
    "copy"
    "__copy"
    "sizeof"
    "__sizeof"
    "__size"
    "__remember-size!"
    "__forget-sizes!"
    "read-array"
    "write-array"
    "__read-array"
    "__write-array"
    "read-bytes"
    "write-bytes"
    "__read-bytes"
    "__write-bytes"
    "null?"
    "null"
    "ptr->string"
    "string->ptr"
    "__string->ptr"
    "__utf8-length"
))

;; The fixed-signature emitter probes scoped libraries before the by-name path.
;; This profile has no public loaded-library registry.
(define (jolt-ffi-dlsym-native name) #f)

(define-syntax jolt-ffi-native-error-procedure
  (syntax-rules ()
    ((_ (convention ...) name arguments result)
     (sa-foreign-procedure-native-error name arguments result))))
