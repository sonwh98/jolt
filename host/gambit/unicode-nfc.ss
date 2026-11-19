;; Unicode 16.0 NFC for Scheme scalar strings. Decompose canonically,
;; stably order each sequence of combining marks, then compose where
;; the intervening classes permit. Hangul has algorithmic mappings.
(##include "unicode-nfc-data.ss")

(define (nfc-class cp)
  (table-ref nfc-classes cp 0))

(define (nfc-decompose cp tail)
  (cond
    ((<= #xac00 cp #xd7a3)
     (let* ((s (- cp #xac00))
            (l (+ #x1100 (quotient s 588)))
            (v (+ #x1161 (quotient (modulo s 588) 28)))
            (t (modulo s 28)))
       (cons l (cons v (if (= t 0) tail (cons (+ #x11a7 t) tail))))))
    ((table-ref nfc-decompositions cp #f)
     => (lambda (parts) (fold-right nfc-decompose tail parts)))
    (else (cons cp tail))))

(define (nfc-compose-pair a b)
  (cond
    ((and (<= #x1100 a #x1112) (<= #x1161 b #x1175))
     (+ #xac00 (* (- a #x1100) 588) (* (- b #x1161) 28)))
    ((and (<= #xac00 a #xd7a3) (zero? (modulo (- a #xac00) 28))
          (<= #x11a8 b #x11c2))
     (+ a (- b #x11a7)))
    (else (table-ref nfc-compositions (+ (* a #x110000) b) #f))))

(define (nfc-order cps)
  ;; The loop works right to left so equal-class marks reach the stable
  ;; sort in their original order. Each starter ends the preceding run.
  (define (flush marks tail)
    (append (list-sort (lambda (a b) (< (nfc-class a) (nfc-class b))) marks)
            tail))
  (let loop ((rest (reverse cps)) (marks '()) (tail '()))
    (if (null? rest)
        (flush marks tail)
        (let ((cp (car rest)))
          (if (zero? (nfc-class cp))
              (loop (cdr rest) '() (cons cp (flush marks tail)))
              (loop (cdr rest) (cons cp marks) tail))))))

(define (string-normalize-nfc s)
  (let* ((n (string-length s))
         (decomposed
           (let loop ((i (- n 1)) (tail '()))
             (if (< i 0) tail
                 (loop (- i 1) (nfc-decompose (char->integer (string-ref s i)) tail)))))
         (out (make-string (length decomposed))))
    (let loop ((rest (nfc-order decomposed)) (i 0) (starter #f) (last-class 0))
      (if (null? rest)
          (substring out 0 i)
          (let* ((cp (car rest))
                 (class (nfc-class cp))
                 (combined (and starter
                                (or (zero? last-class) (< last-class class))
                                (nfc-compose-pair (char->integer (string-ref out starter)) cp))))
            (if combined
                (begin
                  (string-set! out starter (integer->char combined))
                  (loop (cdr rest) i starter last-class))
                (begin
                  (string-set! out i (integer->char cp))
                  (loop (cdr rest) (+ i 1) (if (zero? class) i starter) class))))))))
