;; W1 — errno-atomicity witness (astra's "essential sequence").
;;
;; p1a-r2 REPAIR of review finding F2: the fixtures now capture
;; `int saved = errno;` IMMEDIATELY after the target call, before ANY
;; malloc/conversion/cleanup, and shapes A/C preserve the TARGET's real
;; errno instead of manufacturing it. New capture-order negative controls:
;;   - shape F: intervening clobber BETWEEN target and capture — the witness
;;     EXPECTS the immediate capture to defeat it;
;;   - shape G: a deliberately wrong shim that captures AFTER the clobber —
;;     the witness EXPECTS the clobbered value, proving the assertions
;;     distinguish capture order (so the immediate-capture shapes are
;;     load-bearing).
;;
;; Asserts the Scheme side sees the right (result, errno) pair EVERY time for:
;;   - shape A (-1, EAGAIN), shape B (7, 42 preserved on success), shape C (-2, EACCES)
;;   - shape D: c-lambda code body with a deliberate ___AT_END clobber AFTER
;;     the result conversion (capture order proof at the conversion boundary)
;;   - shape E: capture before a nested re-entry into Scheme (per-invocation
;;     capture, not a global "last errno" cell), including the documented
;;     C->Scheme->C->Scheme nesting on one thread (manual §"Continuations,
;;     the C-interface and threads")
;;   - shape F (-1, EAGAIN with an intervening clobber defeated by the
;;     immediate capture)
;;   - shape G (-1, W1_INTERVENING_CLOBBER — the late-capture negative control)
;;   - concurrent calls from two Scheme threads with interleaved shapes
;;
;; Run: ./w1.exe

(c-declare #<<c-declare-end

#include <errno.h>

typedef struct { int res; int err; } w1_pair;

w1_pair *w1_shape_a (void);
w1_pair *w1_shape_b (void);
w1_pair *w1_shape_c (void);
w1_pair *w1_shape_e (void);
w1_pair *w1_shape_f (void);
w1_pair *w1_shape_g (void);
void w1_free_pair (w1_pair *p);
int w1_errno_again (void);
int w1_errno_acces (void);
int w1_errno_io (void);
int w1_intervening_clobber (void);

c-declare-end
)

(c-define-type w1-pair (pointer "w1_pair"))

;; platform errno values (EAGAIN/EACCES/EIO differ between macOS and Linux)
(define w1-EAGAIN ((c-lambda () int "w1_errno_again")))
(define w1-EACCES ((c-lambda () int "w1_errno_acces")))
(define w1-EIO    ((c-lambda () int "w1_errno_io")))
;; the intervening-clobber constant (C-declared, so the negative control
;; compares against the fixture's own value)
(define w1-clobber ((c-lambda () int "w1_intervening_clobber")))

(define w1-call-a (c-lambda () w1-pair "w1_shape_a"))
(define w1-call-b (c-lambda () w1-pair "w1_shape_b"))
(define w1-call-c (c-lambda () w1-pair "w1_shape_c"))
(define w1-call-e (c-lambda () w1-pair "w1_shape_e"))
(define w1-call-f (c-lambda () w1-pair "w1_shape_f"))
(define w1-call-g (c-lambda () w1-pair "w1_shape_g"))

;; shape D: c-lambda code body, ___AT_END clobber after result conversion.
(define w1-call-d
  (c-lambda () w1-pair
#<<c-lambda-end
   w1_pair *p = w1_shape_c ();
   ___return (p);
   #define ___AT_END errno = 31337;
c-lambda-end
))

(define w1-pair-res (c-lambda (w1-pair) int "___return (___arg1->res);"))
(define w1-pair-err (c-lambda (w1-pair) int "___return (___arg1->err);"))
(define w1-free-pair (c-lambda (w1-pair) void "w1_free_pair (___arg1); ___return;"))

;; c-define'd callback used by shape E: performs a nested foreign call
;; (shape B) and returns exactly 12 when x = 5.
(c-define (w1-nested-cb x) (int) int "w1_nested_cb" "extern"
  (if (= x 5)
      (let ((p (w1-call-b)))
        (let ((r (+ (w1-pair-res p) (w1-pair-err p))))  ; 7 + 42, forces both reads
          (w1-free-pair p)
          (if (= r 49) 12 r)))
      -1))

(define w1-failures 0)
(define w1-checks 0)

(define (w1-check! tag p er es)
  (set! w1-checks (+ w1-checks 1))
  (let ((r (w1-pair-res p)) (e (w1-pair-err p)))
    (if (not (and (= r er) (= e es)))
        (begin
          (set! w1-failures (+ w1-failures 1))
          (display "W1-MISMATCH: ") (display tag)
          (display " got (") (display r) (display ",") (display e)
          (display ") expected (") (display er) (display ",") (display es)
          (display ")")
          (newline)))
    (w1-free-pair p)))

(define (w1-loop! tag call er es n)
  (let loop ((i 0))
    (if (< i n)
        (begin
          (w1-check! tag (call) er es)
          (loop (+ i 1))))))

(define (w1-worker tid)
  ;; interleaved shapes from one thread; a global "last errno" cell cannot
  ;; survive this interleave, per-invocation capture must — and a shim that
  ;; captured late (after allocation) would fail A/F vs G's different values.
  (let loop ((i 0))
    (if (< i 400)
        (begin
          (w1-check! "A" (w1-call-a) -1 w1-EAGAIN)
          (w1-check! "B" (w1-call-b) 7 42)
          (w1-check! "C" (w1-call-c) -2 w1-EACCES)
          (w1-check! "E" (w1-call-e) -3 w1-EIO)
          (w1-check! "F" (w1-call-f) -1 w1-EAGAIN)
          (w1-check! "G" (w1-call-g) -1 w1-clobber)
          (thread-sleep! 0.0001)              ; force green interleaving
          (loop (+ i 1))))))

(display "=== W1 errno-atomicity witness (p1a-r2: capture-before-allocation + negative controls) ===")
(newline)
(display "EAGAIN=") (display w1-EAGAIN) (display " EACCES=") (display w1-EACCES)
(display " EIO=") (display w1-EIO) (display " intervening-clobber=") (display w1-clobber)
(newline)
(set! w1-failures 0)
(set! w1-checks 0)

;; negative control FIRST: the deliberately-late shim must observe the
;; clobber, or the assertions would be insensitive to capture order.
(let ((p (w1-call-g)))
  (let ((r (w1-pair-res p)) (e (w1-pair-err p)))
    (w1-free-pair p)
    (set! w1-checks (+ w1-checks 1))
    (if (and (= r -1) (= e w1-clobber))
        (begin
          (display "W1-NEGATIVE-CONTROL: OK (shape G captured AFTER the intervening clobber and reported it — the assertions distinguish capture order, so the immediate-capture shapes are load-bearing)")
          (newline))
        (begin
          (set! w1-failures (+ w1-failures 1))
          (display "W1-NEGATIVE-CONTROL: FAIL (shape G got (") (display r)
          (display ",") (display e) (display ") expected (") (display -1)
          (display ",") (display w1-clobber)
          (display ") — assertions insensitive to capture order)")
          (newline)))))

;; sequential shapes
(w1-loop! "A" w1-call-a -1 w1-EAGAIN 200)
(w1-loop! "B" w1-call-b 7 42 200)
(w1-loop! "C" w1-call-c -2 w1-EACCES 200)
(w1-loop! "D" w1-call-d -2 w1-EACCES 100)      ; ___AT_END clobber must not leak
(w1-loop! "E" w1-call-e -3 w1-EIO 100)         ; nested re-entry capture
(w1-loop! "F" w1-call-f -1 w1-EAGAIN 200)      ; intervening clobber DEFEATED
(w1-loop! "G" w1-call-g -1 w1-clobber 100)     ; late capture reports the clobber

;; concurrent shapes from two Scheme threads
(define t1 (make-thread (lambda () (w1-worker 1)) 'w1-t1))
(define t2 (make-thread (lambda () (w1-worker 2)) 'w1-t2))
(thread-start! t1)
(thread-start! t2)
(thread-join! t1)
(thread-join! t2)

(display "W1-CHECKS=") (display w1-checks) (newline)
(display "W1-FAILURES=") (display w1-failures) (newline)
(if (= w1-failures 0)
    (display "W1-VERDICT: PASS (every shim captured (result,errno) immediately after the target, before ANY allocation/conversion/re-entry: shapes A/C preserve the target's own errno, shape B preserves errno=42 on success, shape E captures before the nested Scheme re-entry, shape F defeats an intervening clobber written between target and capture; shape G proves the assertions distinguish capture order; the ___AT_END clobber (shape D) and the two-thread interleave add conversion-boundary and scheduling pressure)")
    (display "W1-VERDICT: FAIL"))
(newline)
