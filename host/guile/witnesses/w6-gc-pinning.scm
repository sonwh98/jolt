;; W6 — GC and pinning witness (audit area 5).
;;
;; Rows decided:
;;   P1 sa-lock-object / sa-unlock-object as no-ops: Guile 3.0 uses the
;;      Boehm-Demers-Weiser conservative NON-MOVING collector (manual
;;      §9.2.4 "Conservative Garbage Collection"); a bytevector's address
;;      is stable across collections by construction.  Decided executably:
;;      hold (bytevector->pointer bv) across (gc) + churn and verify the
;;      aliased writes land and persist.
;;   P2 foreign memory malloc'd through the FFI stays put across GC
;;      (pointer->bytevector alias).
;;   P3 memory accounting: (gc-stats) key set and observed shapes → the
;;      sa-bytes-allocated / sa-total-memory-bytes / sa-max-memory-bytes /
;;      sa-gc-max-generation mapping rows; getrlimit(2) reachable via FFI
;;      for a heap ceiling.
;;   P4 after-gc-hook: manual §6.9.6.4 documents it — sa-gc-install-
;;      after-collect! can be REAL on this target, not a #f degradation.
;;
;; Negative controls:
;;   NC1 the GC in the loop must be observably real (bytes-since-gc /
;;       heap samples change) — otherwise P1's stability would be vacuous;
;;   NC2 the alias write must actually change the bytevector (the stability
;;       check is not comparing constants).

(use-modules (system foreign)
             (system foreign-library)
             (rnrs bytevectors)
             (srfi srfi-1))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(format #t "=== W6 GC and pinning witness ===~%")

(define c-malloc (foreign-library-function #f "malloc"
                                           #:return-type '*
                                           #:arg-types (list size_t)))
(define c-free   (foreign-library-function #f "free"
                                           #:return-type void
                                           #:arg-types (list '*)))
(define c-getrlimit
  (foreign-library-function #f "getrlimit"
                            #:return-type int
                            #:arg-types (list int '*)))

;; ---- P1 bytevector address stability across GC ------------------------------
(define bv (make-bytevector 64 0))
(define ptr (bytevector->pointer bv))
(define alias (pointer->bytevector ptr 64))
(define heap-samples '())
(do ((i 0 (+ i 1)))
    ((= i 10))
  (bytevector-u8-set! alias 0 i)               ; write THROUGH the pointer
  (let ((g (make-vector 10000 'churn)))        ; allocate garbage
    (vector-set! g 0 'live)
    (gc)
    (set! heap-samples (cons (assq-ref (gc-stats) 'heap-size) heap-samples)))
  (unless (= (bytevector-u8-ref bv 0) i)
    (error 'w6 "alias write lost — collector moved or dropped the object")))
(check "P1 bytevector pointer stayed address-stable across 10 collections \
(non-moving collector: lock/unlock may BOTH be no-ops)"
       (= (bytevector-u8-ref bv 0) 9))
(check "NC2 control: the aliased writes really reached the bytevector \
(alias tracks bv, not a copy)"
       (not (equal? (bytevector-u8-ref bv 0) 0)))
(check "NC1 control: the collections were real (heap-size samples vary)"
       (> (length (delete-duplicates heap-samples)) 1))

;; ---- P2 foreign memory across GC ---------------------------------------------
(define fptr (c-malloc 128))
(define falias (pointer->bytevector fptr 128))
(do ((i 1 (+ i 1)))
    ((> i 8))
  (bytevector-u64-native-set! falias 0 i)
  (gc)
  (unless (= (bytevector-u64-native-ref falias 0) i)
    (error 'w6 "foreign alias corrupted")))
(check "P2 malloc'd foreign memory stable across GC (writes persist)"
       (= (bytevector-u64-native-ref falias 0) 8))
(c-free fptr)

;; ---- P3 memory accounting shapes ---------------------------------------------
;; RECORDED on this build, the gc-stats key set is exactly:
;;   gc-time-taken gc-times heap-allocated-since-gc heap-free-size
;;   heap-size heap-total-allocated protected-objects
(define s0 (gc-stats))
(gc)
(define s1 (gc-stats))
(format #t "P3 gc-stats keys: ~a~%"
        (sort (map car s1)
              (lambda (a b) (string<? (symbol->string a)
                                      (symbol->string b)))))
(for-each (lambda (k)
            (format #t "P3 ~a: before=~s after-gc=~s~%" k
                    (assq-ref s0 k) (assq-ref s1 k)))
          '(heap-size heap-allocated-since-gc heap-total-allocated
            heap-free-size gc-times gc-time-taken protected-objects))
(check "P3a gc-stats carries heap-size (sa-total-memory-bytes candidate)"
       (assq-ref s1 'heap-size))
(check "P3b gc-stats carries occupied-heap inputs (heap-size and \
heap-free-size)"
       (and (assq-ref s1 'heap-size)
            (assq-ref s1 'heap-free-size)))
;; P3e validate occupied-heap estimate (- heap-size heap-free-size) for
;; sa-bytes-allocated: must stay <= heap-size, grow across (gc) when 2 MiB
;; of bytevectors are retained, and drop after release + (gc).
(define (live-heap-bytes)
  (let ((s (gc-stats)))
    (- (assq-ref s 'heap-size) (assq-ref s 'heap-free-size))))
(gc)
(define live-base (live-heap-bytes))
(define live-retained (map (lambda (_) (make-bytevector 65536 1)) (iota 32)))
(gc)
(define live-stats (gc-stats))
(define live-with-2m (- (assq-ref live-stats 'heap-size)
                        (assq-ref live-stats 'heap-free-size)))
(define live-total-2m (assq-ref live-stats 'heap-size))
(set! live-retained #f)
(gc)
(define live-after-drop (live-heap-bytes))
(format #t "P3e occupied heap (- heap-size heap-free-size): base=~a \
with-2MiB=~a (heap-size=~a) after-drop=~a~%"
        live-base live-with-2m live-total-2m live-after-drop)
(check "P3e occupied-heap estimate tracks retained 2MiB allocations across GC \
and remains <= heap-size"
       (and (<= live-with-2m live-total-2m)
            (>= (- live-with-2m live-base) 2000000)
            (< live-after-drop live-with-2m)))
;; Guile's BDW-GC build has no generations: sa-gc-max-generation answers a
;; fixed sentinel; record that the stats expose none.
(check "P3c no generation counters in gc-stats (sa-gc-max-generation: \
no generations on a BDW-GC build)"
       (not (find (lambda (k) (string-contains (symbol->string k) "gen"))
                  (map car s1))))
;; getrlimit reachable (heap ceiling for sa-max-memory-bytes).  RLIMIT_AS:
;; darwin 5, linux 9 — derived from the platform here.
(define rlimit-as (if (string-contains (utsname:sysname (uname)) "Darwin")
                      5 9))
(let* ((rbuf (make-bytevector 16 0))
       (rc (c-getrlimit rlimit-as (bytevector->pointer rbuf))))
  (format #t "P3d getrlimit(RLIMIT_AS=~a) => ~a rlim_cur=~s~%" rlimit-as rc
          (bytevector-u64-native-ref rbuf 0))
  (check "P3d getrlimit is FFI-reachable (heap ceiling source)"
         (= rc 0)))

;; ---- P4 after-gc-hook ---------------------------------------------------------
(define fired 0)
(add-hook! after-gc-hook (lambda () (set! fired (+ fired 1))))
(gc)
(check "P4 after-gc-hook fires on (gc) — sa-gc-install-after-collect! can \
be real, not the #f degradation"
       (> fired 0))

(if (zero? fails)
    (format #t "W6-VERDICT: PASS (non-moving proven; stats mapped)~%")
    (format #t "W6-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
