;; gambitffi-abi.ss — the gambitffi-abi gate: scalar widths, pointers, byte
;; copies, return conversion, REGISTERED signatures, symbol parity.
;;
;; Run via `make gambitffi-abi` (which builds the bridge + fixtures first, runs
;; this under an external watchdog, from the repo root). Every row asserts
;; state-derived behavior against the fixture library's targets — nothing
;; prints unconditionally.

(##include "ffi-harness.ss")

;; ---- prerequisites: the qualified tier is the bridge + fixture ---------------

;; Fail-closed note: with the bridge absent (a bypassed prerequisite), EVERY row
;; below raises the documented "ffi is unsupported on the gambit target: the
;; stage-1 native bridge is not built" message instead of passing — the gate
;; never skips. The bridge is loaded here; that is what the gate qualifies.
(let ((pre (guard (e (#t (condition-message e)))
             (sa-load-shared-object ffi-fixture-path)
             "NO-RAISE")))
  (if (string=? pre "NO-RAISE")
      (printf "  ok     fixture library loaded through the adapter loader\n")
      (begin (printf "  FAIL   fixture load raised: ~s\n" pre)
             (set! ffi-failures (+ ffi-failures 1))
             (ffi-gate-finish "gambitffi-abi"))))

;; ---- scalar widths ------------------------------------------------------------

(printf "== scalar widths (exact, LP64 legs) ==\n")
(ffi-check "sizeof int" (sa-foreign-sizeof 'int) 4)
(ffi-check "sizeof unsigned-int" (sa-foreign-sizeof 'unsigned-int) 4)
(ffi-check "sizeof integer-8" (sa-foreign-sizeof 'integer-8) 1)
(ffi-check "sizeof unsigned-8" (sa-foreign-sizeof 'unsigned-8) 1)
(ffi-check "sizeof integer-16" (sa-foreign-sizeof 'integer-16) 2)
(ffi-check "sizeof unsigned-16" (sa-foreign-sizeof 'unsigned-16) 2)
(ffi-check "sizeof integer-32" (sa-foreign-sizeof 'integer-32) 4)
(ffi-check "sizeof unsigned-32" (sa-foreign-sizeof 'unsigned-32) 4)
(ffi-check "sizeof integer-64" (sa-foreign-sizeof 'integer-64) 8)
(ffi-check "sizeof unsigned-64" (sa-foreign-sizeof 'unsigned-64) 8)
(ffi-check "sizeof size_t" (sa-foreign-sizeof 'size_t) 8)
(ffi-check "sizeof ssize_t" (sa-foreign-sizeof 'ssize_t) 8)
(ffi-check "sizeof long" (sa-foreign-sizeof 'long) 8)
(ffi-check "sizeof unsigned-long" (sa-foreign-sizeof 'unsigned-long) 8)
(ffi-check "sizeof iptr" (sa-foreign-sizeof 'iptr) 8)
(ffi-check "sizeof uptr" (sa-foreign-sizeof 'uptr) 8)
(ffi-check "sizeof double" (sa-foreign-sizeof 'double) 8)
(ffi-check "sizeof float" (sa-foreign-sizeof 'float) 4)
(ffi-check "sizeof void*" (sa-foreign-sizeof 'void*) 8)
(ffi-check-raise-message "sizeof unknown type refuses"
                         (lambda () (sa-foreign-sizeof 'jolt-agg)) "no size for foreign type")

;; ---- pointers, alloc/free/zero, byte copies -----------------------------------

(printf "== pointers + bulk byte copies ==\n")
(let ((p (sa-foreign-alloc 64)))
  (ffi-check-true "alloc answers a nonzero address" (and (exact-integer? p) (> p 0)))
  (sa-foreign-zero! p 64)
  (let ((bv (make-u8vector 64 255)))
    (sa-foreign-bytes-ref! p bv 64)
    (ffi-check "zero! + bytes-ref! all-zero" (u8vector->list bv)
               (make-list 64 0)))
  ;; binary-faithful moves: NUL and 0xff included
  (let ((bv (u8vector 0 1 #xff 0 66 0 0 0)))
    (sa-foreign-bytes-set! p bv 8)
    (let ((out (make-u8vector 8 9)))
      (sa-foreign-bytes-ref! p out 8)
      (ffi-check "bytes-set!/ref! round-trip (NUL + 0xff)" (u8vector->list out)
                 '(0 1 #xff 0 66 0 0 0))))
  ;; unaligned offset write/read through the typed accessors
  (sa-foreign-set! 'integer-32 p 5 -7)
  (ffi-check "typed set!/ref! unaligned i32" (sa-foreign-ref 'integer-32 p 5) -7)
  (sa-foreign-set! 'unsigned-64 p 24 18446744073709551615)
  (ffi-check "typed set!/ref! u64 max" (sa-foreign-ref 'unsigned-64 p 24) 18446744073709551615)
  (sa-foreign-set! 'integer-64 p 32 -9007199254740993)
  (ffi-check "typed set!/ref! i64 past double range" (sa-foreign-ref 'integer-64 p 32) -9007199254740993)
  (sa-foreign-set! 'double p 40 1.5)
  (ffi-check "typed set!/ref! double" (sa-foreign-ref 'double p 40) 1.5)
  (sa-foreign-set! 'float p 48 0.25)
  (ffi-check "typed set!/ref! float (single precision)" (sa-foreign-ref 'float p 48) 0.25)
  (sa-foreign-set! 'integer-8 p 50 -128)
  (ffi-check "typed set!/ref! i8" (sa-foreign-ref 'integer-8 p 50) -128)
  (sa-foreign-set! 'unsigned-16 p 52 65535)
  (ffi-check "typed set!/ref! u16" (sa-foreign-ref 'unsigned-16 p 52) 65535)
  (sa-foreign-free p)
  #f)
(ffi-check-raise-message "bytes-ref! past the bytevector refuses"
                         (lambda () (sa-foreign-bytes-ref! 1 (make-u8vector 2 0) 3))
                         "bulk copy count exceeds the bytevector")

;; ---- registered signatures through the fixture library ------------------------

(printf "== registered signatures (fixture targets through the tier) ==\n")
;; Adapter syntax and resolved-address calls are exercised here. The companion
;; gambitffi-public.ss exercises actual emitted jolt code. Named adapter calls
;; resolve declared handles first, then process globals.
(let ((clobber (sa-foreign-alloc 32)))
  ;; pointers are exact integers here: a foreign buffer the fixtures write
  ;; into, read back through the bulk copies (the copy-in/copy-out design)
  (sa-foreign-zero! clobber 32)
  ;; s01: () -> int
  (let ((a (jolt-ffi-dlsym-native "joltffi_fx_layout_version")))
    (ffi-check-true "scoped resolution finds the fixture symbol" (and a (not (= a 0))))
    (ffi-check "s01 () -> int" ((sa-foreign-procedure a () int)) 42))
  ;; s01b: () -> int32
  (let ((a (jolt-ffi-dlsym-native "joltffi_fx_eintr")))
    (let ((probe (jolt-ffi-dlsym-native "joltffi_fx_eintr_c")))
      (ffi-check "s01b () -> int32 matches its own probe"
                 ((sa-foreign-procedure a () integer-32))
                 ((sa-foreign-procedure probe () int)))))
  ;; s02: (void*, size_t) -> int
  (let ((a (jolt-ffi-dlsym-native "joltffi_fx_provenance")))
    (let ((f (sa-foreign-procedure a (void* size_t) int)))
      (ffi-check "s02 null buffer refusal" (f 0 0) -1)
      (ffi-check "s02 provenance text"
                 (let ((n (f clobber 16)))
                   (let ((out (make-u8vector n)))
                     (sa-foreign-bytes-ref! clobber out n)
                     (list n (u8vector->list out))))
                 (list 15 (map char->integer (string->list "joltffi-fixture"))))))
  ;; s03: (void*, size_t) -> void
  (let ((a (jolt-ffi-dlsym-native "joltffi_fx_cleanse")))
    (let ((f (sa-foreign-procedure a (void* size_t) void)))
      (sa-foreign-set! 'integer-32 clobber 0 305419896)
      (f clobber 4)
      (ffi-check "s03 cleanse zeroed the range" (sa-foreign-ref 'integer-32 clobber 0) 0)))
  ;; s12/s12b: BE field get/put
  (let ((a-get (jolt-ffi-dlsym-native "joltffi_fx_s32be_get"))
        (a-put (jolt-ffi-dlsym-native "joltffi_fx_s32be_put")))
    (let ((put (sa-foreign-procedure a-put (void* integer-64 integer-32) void))
          (get (sa-foreign-procedure a-get (void* integer-64) integer-32)))
      (put clobber 4 -2023406815)
      (ffi-check "s12b/s12 BE round-trip" (get clobber 4) -2023406815)))
  ;; s13: (int64, void*, int64) -> int64
  (let ((a (jolt-ffi-dlsym-native "joltffi_fx_strerror")))
    (let ((f (sa-foreign-procedure a (integer-64 void* integer-64) integer-64)))
      (let ((n (f 3 clobber 16)))
        (let ((out (make-u8vector n)))
          (sa-foreign-bytes-ref! clobber out n)
          (ffi-check "s13 error-text writer" (utf8->string out) "err-3")))))
  ;; s19/s18: () -> void* then (void*) -> void
  (let ((a-new (jolt-ffi-dlsym-native "joltffi_fx_worker_new"))
        (a-free (jolt-ffi-dlsym-native "joltffi_fx_free")))
    (let ((new (sa-foreign-procedure a-new () void*))
          (free (sa-foreign-procedure a-free (void*) void)))
      (let ((w (new))
            (before ((sa-foreign-procedure "joltffi_fx_free_count" () int))))
        (ffi-check-true "s19 answers a nonzero pointer" (and (exact-integer? w) (> w 0)))
        (free w)
        (ffi-check "s18 target records exactly one deallocation"
                   ((sa-foreign-procedure "joltffi_fx_free_count" () int)) (+ before 1)))))
  ;; s20: () -> void* (errno accessor shape)
  (let ((a (jolt-ffi-dlsym-native "joltffi_fx_errno_location")))
    (let ((f (sa-foreign-procedure a () void*)))
      (ffi-check-true "s20 errno-location answers a nonzero pointer"
                      (and (exact-integer? (f)) (> (f) 0)))))
  ;; s21: (int) -> string (NULL result must surface as #f at this layer)
  (let ((a (jolt-ffi-dlsym-native "joltffi_fx_errtext")))
    (let ((f (sa-foreign-procedure a (int) string)))
      (ffi-check "s21 string result" (f 1) "joltffi-error-one")
      (ffi-check "s21 NULL string result" (f 0) #f)))
  ;; s22: declared-tail varargs (int, int, int) -> int
  (let ((a (jolt-ffi-dlsym-native "joltffi_fx_vfcntl")))
    (let ((f (sa-foreign-procedure (__varargs_after 2) a (int int int) int)))
      (ffi-check "s22 varargs (2 fixed + 1 tail)" (f 10 3 100) 113)))
  ;; by-name construction against PROCESS-GLOBAL symbols (libc): strerror
  ;; through s21 and the host-selected errno accessor through s20. Both libc
  ;; accessors return int*, so the value needs exactly one int dereference.
  ;; RTLD_LOCAL scoped libs stay invisible to
  ;; this path by design (tested in the load-failure gate).
  (let ((f (sa-foreign-procedure "strerror" (int) string)))
    (ffi-check-true "by-name process-global resolution (strerror, s21)" (string? (f 1)))
    (let* ((name (ffi-errno-accessor-name))
           (location ((sa-foreign-procedure name () void*)))
           (read (sa-foreign-procedure "joltffi_fx_errno_deref" (void* size_t) int)))
      (ffi-check-true (string-append "by-name errno accessor (" name ", s20)")
                      (and (exact-integer? location) (> location 0)))
      ;; The fixture validates location == &errno, sets errno, and reads that
      ;; int immediately in one C invocation, avoiding intervening Scheme work.
      (ffi-check (string-append "by-name errno accessor " name " int* dereference")
                 (read location 7777) 7777)))
  ;; symbol parity
  (ffi-check-true "sa-foreign-entry? fixture symbol" (sa-foreign-entry? "joltffi_fx_layout_version"))
  (ffi-check-true "sa-foreign-entry? libc symbol" (sa-foreign-entry? "malloc"))
  (ffi-check-true "sa-foreign-entry? unknown symbol answers #f"
                  (not (sa-foreign-entry? "joltffi_fx_absent_symbol")))
  (ffi-check-true "sa-foreign-entry-address matches the scoped resolution"
                  (= (sa-foreign-entry-address "joltffi_fx_layout_version")
                     (joltffi-dlsym-loaded "joltffi_fx_layout_version")))
  (ffi-check-true "sa-foreign-entry-address raises for unknown"
                  (not (guard (e (#t #f)) (sa-foreign-entry-address "joltffi_fx_absent_symbol") #t)))
  (sa-foreign-free clobber))


(ffi-check "s32 scoped variadic pointer tail"
 ((sa-foreign-procedure (__varargs_after 2) "joltffi_fx_vsetopt" (void* int void*) int) 0 7 0) 7)
(printf "== scalar argument/result conversions ==\n")
(ffi-check "scalar integer-8" ((sa-foreign-procedure "joltffi_fx_scalar_0" (integer-8) integer-8) -128) -128)
(ffi-check "scalar unsigned-8" ((sa-foreign-procedure "joltffi_fx_scalar_1" (unsigned-8) unsigned-8) 255) 255)
(ffi-check "scalar integer-16" ((sa-foreign-procedure "joltffi_fx_scalar_2" (integer-16) integer-16) -32768) -32768)
(ffi-check "scalar unsigned-16" ((sa-foreign-procedure "joltffi_fx_scalar_3" (unsigned-16) unsigned-16) 65535) 65535)
(ffi-check "scalar integer-32" ((sa-foreign-procedure "joltffi_fx_scalar_4" (integer-32) integer-32) -2147483648) -2147483648)
(ffi-check "scalar unsigned-32" ((sa-foreign-procedure "joltffi_fx_scalar_5" (unsigned-32) unsigned-32) 4294967295) 4294967295)
(ffi-check "scalar integer-64" ((sa-foreign-procedure "joltffi_fx_scalar_6" (integer-64) integer-64) -9007199254740993) -9007199254740993)
(ffi-check "scalar unsigned-64" ((sa-foreign-procedure "joltffi_fx_scalar_7" (unsigned-64) unsigned-64) 18446744073709551615) 18446744073709551615)
(ffi-check "scalar size_t" ((sa-foreign-procedure "joltffi_fx_scalar_8" (size_t) size_t) 18446744073709551615) 18446744073709551615)
(ffi-check "scalar ssize_t" ((sa-foreign-procedure "joltffi_fx_scalar_9" (ssize_t) ssize_t) -7) -7)
(ffi-check "scalar float" ((sa-foreign-procedure "joltffi_fx_scalar_10" (float) float) 0.25) 0.25)
(ffi-check "scalar double" ((sa-foreign-procedure "joltffi_fx_scalar_11" (double) double) 1.5) 1.5)
(ffi-check "scalar void*" ((sa-foreign-procedure "joltffi_fx_scalar_12" (void*) void*) 0) 0)
(ffi-check "production bridge has no errno instrumentation" (joltffi-capture-test-enabled?) #f)
(printf "== generated capture shapes ==\n")
(let ((p (sa-foreign-alloc 32)))
  (let ((f (sa-foreign-procedure-native-error posix () (jolt-ffi-dlsym-native "joltffi_fx_socketlike") (int int int) int))
        (e ((sa-foreign-procedure "joltffi_fx_eacces" () int))))
    (ffi-check "fixed capture (distinct from variadic s22b)"
               (call-with-values (lambda () (f -1 2 3)) list) (list -1 e)))
  (let ((f (sa-foreign-procedure-native-error posix () "joltffi_fx_bindlike" (int void* int) int))
        (e ((sa-foreign-procedure "joltffi_fx_eacces" () int))))
    (ffi-check "s26b" (call-with-values (lambda () (f -1 p 4)) list) (list -1 e)))
  (let ((f (sa-foreign-procedure-native-error posix () "joltffi_fx_listenlike" (int int) int))
        (g (sa-foreign-procedure-native-error posix () "joltffi_fx_setsockoptlike" (int int int void* int) int))
        (h (sa-foreign-procedure-native-error posix () "joltffi_fx_getsocknamelike" (int void* void*) int))
        (k (sa-foreign-procedure-native-error posix () "joltffi_fx_getsockoptlike" (int int int void* void*) int))
        (e ((sa-foreign-procedure "joltffi_fx_ebadf" () int))))
    (ffi-check "s26c" (call-with-values (lambda () (f -1 2)) list) (list -1 e))
    (ffi-check "s26d" (call-with-values (lambda () (g -1 2 3 p 4)) list) (list -1 e))
    (ffi-check "s26e" (call-with-values (lambda () (h -1 p p)) list) (list -1 e))
    (ffi-check "s23" (call-with-values (lambda () (k -1 2 3 p p)) list) (list -1 e)))
  (let ((f (sa-foreign-procedure-native-error posix ((__varargs_after 2)) "joltffi_fx_vfcntl" (int int int) int))
        (g (sa-foreign-procedure-native-error posix ((__varargs_after 2)) "joltffi_fx_vioctl" (int unsigned-long void*) int))
        (a ((sa-foreign-procedure "joltffi_fx_eagain" () int)))
        (b ((sa-foreign-procedure "joltffi_fx_ebadf" () int))))
    (ffi-check "s22b variadic tail" (call-with-values (lambda () (f 1 99 7)) list) (list -1 a))
    (ffi-check "s22c variadic pointer tail" (call-with-values (lambda () (g 1 88 p)) list) (list -1 b)))
  (sa-foreign-free p))

(ffi-check-raise-message "unregistered signature names its shape"
 (lambda () (sa-foreign-procedure "malloc" (void* int) void*)) "(void* int) -> void*")
(ffi-check-raise-message "wrong variadic boundary refuses before dereference"
 (lambda () (sa-foreign-procedure (__varargs_after 1) 1 (int int int) int)) "unregistered shape")
(ffi-check-raise-message "string arguments refuse"
 (lambda () (sa-foreign-procedure "absent" (u8*) int)) ":string arguments are unsupported")
(printf "== P1f Internet address and datagram shapes ==\n")
(let ((src (sa-foreign-alloc 8))
      (dst (sa-foreign-alloc 8))
      (lenp (sa-foreign-alloc 4))
      (pton (sa-foreign-procedure "joltffi_fx_inet_pton" (int void* void*) int))
      (ntop (sa-foreign-procedure "joltffi_fx_inet_ntop" (int void* void* unsigned-int) void*))
      (sendto (sa-foreign-procedure-native-error posix ()
                "joltffi_fx_sendto" (int void* size_t int void* unsigned-int) ssize_t))
      (recvfrom (sa-foreign-procedure-native-error posix ()
                  "joltffi_fx_recvfrom" (int void* size_t int void* void*) ssize_t))
      (eagain ((sa-foreign-procedure "joltffi_fx_eagain" () int)))
      (einval ((sa-foreign-procedure "joltffi_fx_einval" () int))))
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (sa-foreign-set! 'unsigned-8 src 0 255)
      (ffi-check "inet_pton int and output pointer" (pton 6 src dst) 1)
      (ffi-check "inet_pton writes binary address" (sa-foreign-ref 'unsigned-8 dst 0) 42)
      (ffi-check "inet_ntop unsigned socklen and returned pointer" (ntop 6 dst src #xffffffff) src)
      (ffi-check "inet_ntop null result" (ntop 6 dst src 0) 0)
      (ffi-check "sendto six slots, wide result and errno"
        (call-with-values (lambda () (sendto 17 src #x100000003 -8 dst #xffffffff)) list)
        (list #x100000003 7777))
      (ffi-check "sendto captures error from its own call"
        (call-with-values (lambda () (sendto -1 src 8 0 dst 0)) list)
        (list -1 einval))
      (ffi-check "recvfrom six slots, wide result and errno"
        (call-with-values (lambda () (recvfrom 17 src #x100000003 -8 dst lenp)) list)
        (list #x100000003 7777))
      (ffi-check "recvfrom payload, source address and in/out socklen"
        (list (sa-foreign-ref 'unsigned-8 src 0) (sa-foreign-ref 'unsigned-8 dst 0)
              (sa-foreign-ref 'unsigned-int lenp 0))
        '(42 255 28))
      (ffi-check "recvfrom would-block capture"
        (call-with-values (lambda () (recvfrom -1 src 8 0 dst lenp)) list)
        (list -1 eagain)))
    (lambda () (sa-foreign-free lenp) (sa-foreign-free dst) (sa-foreign-free src))))

(let* ((socket (sa-foreign-procedure-native-error posix () "socket" (int int int) int))
       (getsockname (sa-foreign-procedure-native-error posix () "getsockname"
                     (int void* void*) int))
       (ebadf ((sa-foreign-procedure "joltffi_fx_ebadf" () int)))
       (fd (call-with-values (lambda () (socket 2 2 17))
             (lambda (fd _) fd)))) ; AF_INET, SOCK_DGRAM, IPPROTO_UDP on both legs
  (ffi-check-true "datagram close test opened a fresh fd" (>= fd 0))
  (when (>= fd 0)
    (ffi-check "datagram worker returns success" (joltffi-await-datagram-close fd) 0)
    (let ((addr (sa-foreign-alloc 128)) (lenp (sa-foreign-alloc 4)))
      (dynamic-wind
        (lambda () (sa-foreign-set! 'int lenp 0 128))
        (lambda ()
          (ffi-check "the worker closed the descriptor"
            (call-with-values (lambda () (getsockname fd addr lenp)) list)
            (list -1 ebadf)))
        (lambda () (sa-foreign-free lenp) (sa-foreign-free addr)))))
  (ffi-check "datagram worker returns its own close errno"
    (joltffi-await-datagram-close -1) (+ (- (expt 2 32)) ebadf)))

(ffi-gate-finish "gambitffi-abi")
