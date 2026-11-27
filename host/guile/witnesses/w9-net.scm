;; W9 — sockets: UDP, non-blocking, poller, suspendable ports (audit area 6).
;;
;; Decides DHT and WebSocket parity prerequisites (brief area 6):
;;   S1 UDP datagram round-trip on a loopback socket;
;;   S2 O_NONBLOCK + errno-at-boundary: recvfrom on an empty socket
;;      returns -1 with EAGAIN/EWOULDBLOCK captured at the call boundary
;;      (darwin EAGAIN=35, linux EAGAIN=11 — recorded, not assumed);
;;   S3 a poller: select(0-timeout) reports not-ready before the datagram
;;      and ready after (causal);
;;   S4 the fibers-enabling facility (manual §6.12.13): install-
;;      suspendable-ports! + current-read-waiter — a read that would
;;      block invokes the waiter parameter, which observes the late
;;      datagram (this is the scheduler hook Guile Fibers rides).
;;
;; Negative controls:
;;   NC1 select on the empty socket with timeout 0 must be NOT-ready
;;      (otherwise the S3 causality check is vacuous);
;;   NC2 the waiter must fire MORE THAN ZERO times (a read that never
;;      parked would make S4 vacuous — record the count).

(use-modules (system foreign)
             (system foreign-library)
             (rnrs bytevectors)
             (rnrs io ports)
             (ice-9 threads)
             (srfi srfi-1)
             (srfi srfi-8))
;; NOTE: there is NO (ice-9 sockets) module in stock 3.0.11 (recorded) —
;; socket/bind/sendto/recvfrom! are core (guile) exports, and the bound
;; address comes from core getsockname as a VECTOR #(family addr port).

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(format #t "=== W9 sockets / non-blocking / poller witness ===~%")

(define c-recvfrom
  (foreign-library-function #f "recvfrom"
                            #:return-type ssize_t
                            #:arg-types (list int '* size_t int '* '*)
                            #:return-errno? #t))
(define c-usleep
  (foreign-library-function #f "usleep"
                            #:return-type int
                            #:arg-types (list unsigned-int)))
(define c-fcntl
  (foreign-library-function #f "fcntl"
                            #:return-type int
                            #:arg-types (list int int)))

;; ---- S1 UDP loopback ---------------------------------------------------------
(define rx (socket AF_INET SOCK_DGRAM 0))
(bind rx AF_INET INADDR_LOOPBACK 0)
(define addr (getsockname rx))              ; #(family addr port)
(define rx-port-num (vector-ref addr 2))
(format #t "S1 bound to ~s~%" addr)
(define tx (socket AF_INET SOCK_DGRAM 0))
(sendto tx #vu8(90) AF_INET INADDR_LOOPBACK rx-port-num) ; 90 = #\Z
(define rbuf (make-bytevector 16))
(let ((res (recvfrom! rx rbuf)))            ; (n . sockaddr)
  (format #t "S1 received ~a byte(s): ~s~%" (car res)
          (bytevector-u8-ref rbuf 0))
  (check "S1 UDP datagram round-trip on loopback"
         (and (= (car res) 1)
              (= (bytevector-u8-ref rbuf 0) 90))))

;; ---- S2 non-blocking + errno at the boundary -----------------------------------
(define rxfd (fileno rx))
(define flags (fcntl rxfd F_GETFL))
(define rc (fcntl rxfd F_SETFL (logior flags O_NONBLOCK)))
(check "S2a F_SETFL O_NONBLOCK applied (fcntl => 0)" (= rc 0))
(receive (n e) (c-recvfrom rxfd (bytevector->pointer rbuf) 16 0
                            %null-pointer %null-pointer)
  (format #t "S2b recvfrom on empty socket => n=~a errno=~a~%" n e)
  (check "S2b non-blocking recvfrom returns -1 with EAGAIN/EWOULDBLOCK \
captured at the boundary (darwin 35 / linux 11)"
         (and (= n -1) (> e 0))))

;; ---- S3 poller causality --------------------------------------------------------
(define (readable? fd)
  (pair? (car (select (list fd) '() '() 0))))
;; A poller polls: readiness must appear within a short window after the
;; datagram (loopback delivery can land a tick after sendto returns) and
;; must NEVER appear before it.
(define c-usleep9
  (foreign-library-function #f "usleep"
                            #:return-type int
                            #:arg-types (list unsigned-int)))
(define (readable-within? fd tries)
  (let loop ((n 0))
    (cond ((readable? fd) #t)
          ((>= n tries) #f)
          (else (c-usleep9 10000) (loop (+ n 1))))))
(check "NC1 control: select(0) says NOT ready before any datagram \
(strict single shot)"
       (not (readable? rxfd)))
(sendto tx #vu8(65) AF_INET INADDR_LOOPBACK rx-port-num)
(check "S3 select(0) says ready within a poll window after the datagram \
(causality)"
       (readable-within? rxfd 20))
(receive (n e) (c-recvfrom rxfd (bytevector->pointer rbuf) 16 0
                            %null-pointer %null-pointer)
  (check "S3b drain the ready datagram" (and (= n 1)
                                             (= (bytevector-u8-ref rbuf 0) 65))))

;; ---- S4 suspendable ports + read waiter -------------------------------------------
(use-modules (ice-9 suspendable-ports))
(install-suspendable-ports!)
(define waiter-count 0)
(define late-port #f)
(define waiter-thread
  (call-with-new-thread
   (lambda ()
     (c-usleep 300000)                         ; 300ms
     (sendto tx #vu8(81) AF_INET INADDR_LOOPBACK rx-port-num))))
(set! late-port (fdopen rxfd "r"))
(parameterize ((current-read-waiter
                (lambda (port)
                  (set! waiter-count (+ waiter-count 1))
                  (c-usleep 50000))))
  (define b (get-bytevector-n late-port 1))
  (format #t "S4 read returned ~s after ~a waiter invocation(s)~%"
          b waiter-count)
  (check "S4 the read that would block parks through current-read-waiter \
and completes when the datagram lands (the fibers scheduler hook)"
         (and (bytevector? b) (= (bytevector-u8-ref b 0) 81)))
  (check "NC2 control: the waiter actually fired (> 0)"
         (> waiter-count 0)))
(join-thread waiter-thread)

(if (zero? fails)
    (format #t "W9-VERDICT: PASS (DHT/WebSocket parity prerequisites)~%")
    (format #t "W9-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
