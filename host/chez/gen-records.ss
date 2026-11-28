;; Expand the shared record families on Chez before loading them on each target.
(import (chezscheme))

;; Emit portable parentheses for both targets.
(print-brackets #f)

;; The records subsystem is four chez files, concatenated here in their rt.ss
;; load order. The generated file preserves the total form order.
(define srcs '("host/chez/records.ss"
               "host/chez/records-coll.ss"
               "host/chez/protocols.ss"
               "host/chez/records-dispatch.ss"))
;; GEN_RECORDS_OUT redirects the write, which is what `make gambitgencheck` uses
;; to generate into a temp file and diff against the committed one.
(define target
  (let ((args (cdr (command-line))))
    (unless (and (= (length args) 1) (member (car args) '("gambit" "guile")))
      (error 'gen-records "expected target gambit or guile" args))
    (car args)))
(define out
  (or (getenv "GEN_RECORDS_OUT")
      (string-append "host/" target "/records-" target ".ss")))

(define (read-all f)
  (with-input-from-file f
    (lambda ()
      (let loop ((acc '()))
        (let ((x (read)))
          (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

(define forms (apply append (map read-all srcs)))
(define last-form (car (reverse forms)))

;; the transformer lambda from (define-syntax define-jrec-family (lambda (x) ...))
(define transformer
  (let loop ((fs forms))
    (cond
      ((null? fs) (error 'gen-records "define-jrec-family not found in" srcs))
      ((and (pair? (car fs))
            (eq? (caar fs) 'define-syntax)
            (eq? (cadar fs) 'define-jrec-family))
       (eval (caddar fs)))
      (else (loop (cdr fs))))))

(define (expand-use form)
  ;; apply the transformer to the use as a syntax object; syntax->datum of the
  ;; result is the clean (begin (define-record-type ...) ...) — no lowering.
  (syntax->datum (transformer (datum->syntax #'here form))))

(define port (open-output-file out 'replace))
(if (string=? target "gambit")
    (begin
      (put-string port ";; records-gambit.ss — GENERATED from host/chez/{records,records-coll,\n")
      (put-string port ";; protocols,records-dispatch}.ss by host/gambit/gen-records.ss (make\n")
      (put-string port ";; gambitgen). Do not edit; regenerate when any of the four changes. The\n")
      (put-string port ";; define-jrec-family transformer is expansion-phase-hostile on Gambit;\n")
      (put-string port ";; its uses are pre-expanded here.\n\n"))
    (put-string port
      "#!no-fold-case\n;; records-guile.ss — GENERATED from host/chez/{records,records-coll,\n;; protocols,records-dispatch}.ss by host/chez/gen-records.ss (make\n;; guilegen). Do not edit. define-jrec-family uses are pre-expanded.\n\n"))
(for-each
  (lambda (f)
    (cond
      ((and (pair? f) (eq? (car f) 'define-syntax) (eq? (cadr f) 'define-jrec-family))
       (put-string port ";; (define-syntax define-jrec-family ...) — pre-expanded below\n\n"))
      ((and (pair? f) (eq? (car f) 'define-jrec-family))
       (put-string port ";; expansion of ")
       (write f port)
       (put-string port "\n")
       (for-each (lambda (g) (pretty-print g port) (newline port))
                 (cdr (expand-use f))))   ; drop the begin head
      (else
       (pretty-print f port)
       (unless (and (string=? target "guile") (eq? f last-form))
         (newline port)))))
  forms)
(close-port port)
(display (string-append "gen-records: wrote " out "\n"))
