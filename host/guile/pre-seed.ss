;; Native bindings used by initializers in the generated prelude.
(define (guile-object-array size-or-items)
  (cond
    ((or (number? size-or-items) (jfloat? size-or-items))
     (let ((size (jolt-int-cast size-or-items)))
       (when (< size 0) (throw-jvm 'NegativeArraySizeException (number->string size)))
       (make-jolt-obj-array (make-vector size jolt-nil))))
    ((jolt-obj-array? size-or-items)
     (make-jolt-obj-array (vector-copy (jolt-obj-array-vec size-or-items))))
    (else
     (make-jolt-obj-array (list->vector (seq->list (jolt-seq size-or-items)))))))

(def-var! "clojure.core" "object-array" guile-object-array)

(define (jolt-str-join-var coll . opt)
  (let ((sep (if (pair? opt) (jolt-str-render-one (car opt)) "")))
    (call-with-output-string
      (lambda (out)
        (let loop ((s (jolt-seq coll)) (first? #t))
          (unless (jolt-nil? s)
            (unless first? (display sep out))
            (display (jolt-str-render-one (seq-first s)) out)
            ;; seq-more can return an empty list. Normalize it before reading.
            (loop (jolt-seq (seq-more s)) #f)))))))
(def-var! "clojure.core" "str-join" jolt-str-join-var)

(define (string-line-from s from)
  (let ((n (string-length s)))
    (if (fx>=? from n)
        jolt-nil
        (let loop ((i from))
          (cond
            ((fx=? i n) (jolt-vector (substring s from n) n))
            ((char=? (string-ref s i) #\newline) (jolt-vector (substring s from i) (fx+ i 1)))
            ((char=? (string-ref s i) #\return)
             (jolt-vector (substring s from i)
                          (if (and (fx<? (fx+ i 1) n) (char=? (string-ref s (fx+ i 1)) #\newline))
                              (fx+ i 2)
                              (fx+ i 1))))
            (else (loop (fx+ i 1))))))))
(def-var! "clojure.core" "__string-line-from"
  (lambda (s from) (string-line-from (jolt-str-render-one s) (jnum->exact from))))
