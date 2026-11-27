;; W1 — reader/emit parity witness (audit area 1).
;;
;; Decides what the adapter must do at boot so jolt's emitted Scheme reads
;; identically to Chez's reader.  Manual §6.16.2 "Reading Scheme Code"
;; documents the option set and its DEFAULTS on 3.0.11:
;;   positions yes / case-insensitive no / keywords #f / r6rs-hex-escapes
;;   no / square-brackets yes / hungry-eol-escapes no / curly-infix no /
;;   r7rs-symbols no / bytestrings no
;; and §6.16.1.4 "Case Sensitivity" states Guile is case SENSITIVE by
;; default (the task brief's contrary premise is recorded by W0/W1).
;;
;; Rows decided here:
;;   R1 case sensitivity (default sensitive; fold directive exists)
;;   R2 square brackets as parens (default yes)
;;   R3 datum (#;) and block (#| |#) comments
;;   R4 string escapes: default vs r6rs-hex-escapes (boot must enable)
;;   R5 |...| symbol notation: NOT one symbol by default (bars are
;;      ordinary characters); enabling r7rs-symbols is the boot action
;;   R6 numbers battery
;;   R7 bytevector literals: #vu8(...) reads NATIVELY by default
;;      (recorded finding — no read-hash-extend! repair needed)
;;
;; Negative controls (each proves the witness can fail):
;;   N1 with case-insensitive ON, the case-distinctness check inverts —
;;      recorded as the control detecting exactly the wrong-reader mode;
;;   N2 a malformed #vu8(a b) literal must RAISE under the default reader;
;;   N3 the R6RS escape probe must NOT decode \x41;B as "AB" under the
;;      default options — if it did, the boot-time r6rs-hex-escapes row
;;      would be vacuous.

(use-modules (srfi srfi-1)
             (rnrs bytevectors))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(define (read-str s)
  (read (open-input-string s)))

(format #t "=== W1 reader/emit parity witness ===~%")
(format #t "read-options-default: ~a~%" (read-options))

;; ---- R1 case sensitivity -------------------------------------------------
(check "R1a default reader is case-SENSITIVE ('Abc distinct from 'abc)"
       (not (eq? (read-str "Abc") (read-str "abc"))))
(let ((direct (read-str "#!no-fold-case\nAbc")))
  (check "R1b #!no-fold-case directive keeps 'Abc distinct from 'abc"
         (and (symbol? direct) (eq? direct 'Abc))))
;; N1 negative control: fold ON must merge the symbols.
(read-enable 'case-insensitive)
(let ((folded (read-str "Abc")))
  (check "N1 control: with case-insensitive ON 'Abc reads as 'abc \
(witness detects folding)"
         (eq? folded 'abc)))
(read-disable 'case-insensitive)
(check "N1b control: after read-disable, folding is off again"
       (not (eq? (read-str "Abc") (read-str "abc"))))

;; ---- R2 square brackets ---------------------------------------------------
(check "R2 [1 2 3] reads as the list (1 2 3)"
       (equal? (read-str "[1 2 3]") '(1 2 3)))
(check "R2b nested mix [(a [b] c)] reads with brackets as parens"
       (equal? (read-str "[(a [b] c)]") '((a (b) c))))

;; ---- R3 comments ----------------------------------------------------------
(check "R3a datum comment #; removes next datum"
       (equal? (read-str "(1 #;2 3)") '(1 3)))
(check "R3b block comment #| ... |# skipped"
       (equal? (read-str "(1 #| two |# 3)") '(1 3)))
(check "R3c nested block comments"
       (equal? (read-str "(1 #| outer #| inner |# still |# 3)") '(1 3)))

;; ---- R4 string escapes ----------------------------------------------------
;; Guile default: \x consumes a FIXED number of hex digits (2), no ';'.
;; R6RS: \x<hex>; variable length.  Chez emits the R6RS form.
(define esc-default (read-str "\"\\x41;B\""))
(format #t "R4 default read of \"\\\\x41;B\" => ~s~%" esc-default)
(check "N3 control: default reader does NOT decode \\x41;B as \"AB\""
       (not (equal? esc-default "AB")))
(read-enable 'r6rs-hex-escapes)
(define esc-r6rs (read-str "\"\\x41;B\""))
(format #t "R4 r6rs-escapes read of \"\\\\x41;B\" => ~s~%" esc-r6rs)
(check "R4 with r6rs-hex-escapes ON, \\x41;B decodes as \"AB\" \
(boot must enable)"
       (equal? esc-r6rs "AB"))
(read-disable 'r6rs-hex-escapes)
(check "R4b common escapes \\n \\t \\\" \\\\ identical everywhere"
       (equal? (read-str "\"a\\nb\\t c \\\"q\\\\z\"") "a\nb\t c \"q\\z"))

;; ---- R5 |...| symbols -----------------------------------------------------
;; NOTE: the witness source itself must not contain raw |barred symbol|
;; tokens — the DEFAULT reader treats | as an ordinary symbol constituent
;; and splits at whitespace (recorded below), so probes are built from
;; strings.
(define bar-sym-name "hello world")
(define bar-literal (string-append (string #\|) bar-sym-name (string #\|)))
(define barred (false-if-exception (read-str bar-literal)))
(format #t "R5 ~s default => ~s~%" bar-literal barred)
(define bars-ok-by-default?
  (and barred (symbol? barred)
       (eq? barred (string->symbol bar-sym-name))))
(if bars-ok-by-default?
    (check "R5 |...| symbol notation reads as ONE symbol under DEFAULT \
options"
           #t)
    (begin
      (format #t "R5 default split it (bars are ordinary characters until \
r7rs-symbols is enabled)~%")
      (read-enable 'r7rs-symbols)
      (let ((repaired (read-str bar-literal)))
        (format #t "R5 after read-enable 'r7rs-symbols => ~s~%" repaired)
        (check "R5 boot action decided: enabling r7rs-symbols makes \
|...| read as ONE symbol"
               (and (symbol? repaired)
                    (eq? repaired (string->symbol bar-sym-name)))))
      (read-disable 'r7rs-symbols)))

;; ---- R6 numbers -----------------------------------------------------------
(check "R6a exact rational 1/3"
       (and (exact? (read-str "1/3")) (= 1/3 (read-str "1/3"))))
(check "R6b #e1.5 is exact 3/2" (equal? (read-str "#e1.5") 3/2))
(check "R6c exponent 1e3 is inexact 1000.0"
       (and (inexact? (read-str "1e3")) (= (read-str "1e3") 1000.0)))
(check "R6d #x10 is 16" (equal? (read-str "#x10") 16))
(check "R6e negative rational -22/7 exact"
       (and (exact? (read-str "-22/7")) (= (read-str "-22/7") -22/7)))
(check "R6f +inf.0/-inf.0/+nan.0 read"
       (and (= (read-str "+inf.0") +inf.0) (= (read-str "-inf.0") -inf.0)
            (nan? (read-str "+nan.0"))))

;; ---- R7 bytevector literals ----------------------------------------------
;; RECORDED FINDING (contradicts the doc-tier expectation): the 3.0.11
;; default reader DOES read #vu8(...) natively — no read-hash-extend!
;; boot action and no emitter change needed for Chez-style bytevector
;; literals.
(define vu8-native (false-if-exception (read-str "#vu8(1 2 3 254)")))
(format #t "R7 #vu8(1 2 3 254) default => ~s~%" vu8-native)
(check "R7a the DEFAULT reader reads #vu8(...) as a bytevector \
(native — no boot action)"
       (and (bytevector? vu8-native)
            (equal? (bytevector->u8-list vu8-native) '(1 2 3 254))))
(define vu8-bad (false-if-exception (read-str "#vu8(a b)")))
(format #t "N2 control: #vu8(a b) default => ~s~%" vu8-bad)
(check "N2 control: a malformed #vu8 literal RAISES (the row is decided, \
not vacuous)"
       (not vu8-bad))
(define bs (false-if-exception (read-str "#u8\"ab\"")))
(format #t "R7c SRFI-207 #u8\"...\" bytestring (option default off) => ~s~%"
        bs)
(check "R7c SRFI-207 bytestrings stay OFF by default (not part of the \
emit surface; enabling is a read-set! away)"
       (not bs))

(if (zero? fails)
    (format #t "W1-VERDICT: PASS (~a rows + controls)~%" "reader")
    (format #t "W1-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
