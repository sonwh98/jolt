;; Gambit limits the size of a Scheme argument frame. For (apply str ...), join
;; the pieces over a port without turning the list into arguments. Keep str's
;; single-argument identity and handling of adjacent UTF-16 surrogate units.
(define (gambit-str-pieces xs)
  (cond
    ((null? xs) "")
    ((null? (cdr xs)) (jolt-str (car xs)))
    (else
     (call-with-output-string
       (lambda (port)
         (let loop ((xs xs))
           (when (pair? xs)
             (if (and (jsurr-high? (car xs)) (pair? (cdr xs))
                      (jsurr-low? (cadr xs)))
                 (begin (display (jolt-str (car xs) (cadr xs)) port)
                        (loop (cddr xs)))
                 (begin (display (jolt-str-piece (car xs)) port)
                        (loop (cdr xs)))))))))))

(let ((ordinary-apply jolt-apply))
  (set! jolt-apply
    (lambda (f . args)
      (if (and (eq? f jolt-str) (pair? args))
          (let* ((r (reverse args))
                 (tail (jolt-seq (car r))))
            (gambit-str-pieces (append (reverse (cdr r)) (seq->list tail))))
          (apply ordinary-apply f args)))))
(def-var! "clojure.core" "apply" jolt-apply)
