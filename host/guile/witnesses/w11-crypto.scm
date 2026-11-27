;; W11 — cryptography witness (audit area 8).
;;
;; Doc tier first (manual §7.2.14 "Encryption"): Guile's bundled crypto is
;; crypt(3) + getpass ONLY — "not suited for strong encryption".  So
;; BLAKE3 / SHA-256 / Ed25519 / CSPRNG must come from FFI (libcrypto or a
;; vendored C extension).  This witness decides what is actually reachable
;; on the provisioned host:
;;
;;   K1 no native digest primitives bound in core/gcrypt (recorded);
;;   K2 libcrypto loadable via (system foreign-library) + a SHA-256
;;      EVP_Digest KNOWN-ANSWER test ("abc" — the FIPS 180 vector);
;;   K3 CSPRNG: getentropy(2) reachable through the global namespace;
;;   K4 Ed25519: EVP_PKEY_new_raw_private_key symbol present in libcrypto
;;      (parameterized by "ED25519" — presence implies support);
;;   K5 BLAKE3: no system library on stock darwin/linux — the row records
;;      the vendored-C decision.
;;
;; Negative controls:
;;   NC1 the KAT is exact — digesting a DIFFERENT input must give a
;;      different digest (the check can fail);
;;   NC2 getentropy output must not be all zeros (a degenerate generator
;;      fails).

(use-modules (system foreign)
             (system foreign-library)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-13))

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(format #t "=== W11 cryptography witness ===~%")

;; ---- K1 no bundled digests ----------------------------------------------------
(let ((core (resolve-interface '(guile)))
      (names '(sha256 blake3 ed25519-sign random-bytes)))
  (format #t "K1 core-bound crypto names: ~s~%"
          (filter (lambda (n) (module-bound? core n)) names))
  (check "K1 no digest/sign primitives bundled in core (FFI required)"
         (every (lambda (n) (not (module-bound? core n))) names)))
(let ((g (false-if-exception (resolve-interface '(gcrypt base16))))
      (g4 (false-if-exception (resolve-interface '(gcrypt hash)))))
  (format #t "K1b (gcrypt ...) resolvable: base16=~a hash=~a~%" (and g #t)
          (and g4 #t))
  (format #t "K1b note: guile-gcrypt is an EXTERNAL package, not bundled; \
its absence here is expected on a stock install~%"))

;; ---- K2 libcrypto SHA-256 known-answer -------------------------------------------
(define libcrypto
  (or (false-if-exception (load-foreign-library "libcrypto"))
      (false-if-exception (load-foreign-library "crypto"))))
(check "K2a libcrypto loadable through (system foreign-library)"
       (and libcrypto #t))

(when libcrypto
  (define evp-sha256
    (foreign-library-function libcrypto "EVP_sha256"
                              #:return-type '*
                              #:arg-types '()))
  (define evp-digest
    (foreign-library-function libcrypto "EVP_Digest"
                              #:return-type int
                              #:arg-types (list '* size_t '* '* '* '*)))
  (define (hex b) (string-pad (number->string b 16) 2 #\0))
  (define (sha256 bv)
    (let* ((md (make-bytevector 32 0))
           (size-buf (make-bytevector 4 0))
           (rc (evp-digest (bytevector->pointer bv) (bytevector-length bv)
                           (bytevector->pointer md)
                           (bytevector->pointer size-buf)
                           (evp-sha256) %null-pointer)))
      ;; EVP_Digest returns 1 on success (OpenSSL convention), not 0.
      (if (= rc 1) md #f)))
  (define abc-digest (sha256 (string->utf8 "abc")))
  (define abc-hex
    (and abc-digest
         (string-concatenate
          (map hex (bytevector->u8-list abc-digest)))))
  (format #t "K2b sha256(\"abc\") = ~a~%" abc-hex)
  (check "K2b SHA-256 known-answer test (FIPS 180 \"abc\" vector)"
         (and abc-hex
              (string=? abc-hex
                        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")))
  (define other (sha256 (string->utf8 "abd")))
  (define other-hex
    (and other
         (string-concatenate
          (map hex (bytevector->u8-list other)))))
  (check "NC1 control: a different input gives a different digest"
         (and abc-hex other-hex (not (string=? abc-hex other-hex))))

  ;; ---- K4 Ed25519 surface ------------------------------------------------------
  (define ed-symbol
    (false-if-exception
     (foreign-library-function libcrypto "EVP_PKEY_new_raw_private_key"
                               #:return-type '*
                               #:arg-types (list '* '* '* size_t))))
  (format #t "K4 EVP_PKEY_new_raw_private_key present in libcrypto: ~a~%"
          (and ed-symbol #t))
  (check "K4 Ed25519 reachable via libcrypto EVP raw-key API \
(OpenSSL 1.1+/3.x: sn \"ED25519\")"
         (and ed-symbol #t)))

;; ---- K3 CSPRNG -------------------------------------------------------------------
(define getentropy
  (false-if-exception
   (foreign-library-function #f "getentropy"
                             #:return-type int
                             #:arg-types (list '* size_t))))
(check "K3a getentropy(2) reachable via the global namespace"
       (and getentropy #t))
(when getentropy
  (define rnd (make-bytevector 32 1))
  (define rc (getentropy (bytevector->pointer rnd) 32))
  (define nonzero
    (fold (lambda (b acc) (if (zero? b) acc (+ acc 1))) 0
          (bytevector->u8-list rnd)))
  (format #t "K3b getentropy rc=~a nonzero-bytes=~a/32~%" rc nonzero)
  (check "K3b getentropy fills 32 bytes, not all zero (NC2 control)"
         (and (zero? rc) (> nonzero 0))))

;; ---- K5 BLAKE3 -------------------------------------------------------------------
(define blake3-lib
  (or (false-if-exception (load-foreign-library "blake3"))
      (false-if-exception (load-foreign-library "libblake3"))))
(format #t "K5 system libblake3 loadable: ~a~%" (and blake3-lib #t))
(format #t "K5 BLAKE3: not in OpenSSL and not a stock system library — \
the row decision is VENDORED C (blake3 reference implementation compiled \
as a loadable extension), or a jolt-level degradation~%")
(check "K5 BLAKE3 absent from the system (vendored-C decision recorded)"
       (not blake3-lib))

(if (zero? fails)
    (format #t "W11-VERDICT: PASS (crypto surface mapped: libcrypto + \
getentropy reachable; BLAKE3 vendored)~%")
    (format #t "W11-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
