;; scheme-adapter-runtime.ss — the RUNTIME half of the portable-scheme-layer
;; adapter (PSL R3, epic jolt-867l) — GAMBIT TARGET (native gsi, G1 demo).
;;
;; The Chez adapter (host/chez/scheme-adapter-runtime.ss) owns the system-tier
;; FORBIDDEN names and exposes them through named capability entry points; a
;; non-Chez target implements (or explicitly degrades) this one small surface
;; instead of chasing call sites. This file is the Gambit implementation:
;; same sa-* names, same call shapes, same doc discipline, with the G1 demo
;; degradations below. Loaded FIRST in every boot path, after prelude-shims.ss
;; (which owns the (gambit) import) — so this file needs no import of its own.
;;
;; G1 degradation summary (each is documented at its entry point):
;;   - real:  sa-real-time-ms, sa-file-mtime-ms, sa-host-tag and the identity
;;            derived values. Everything else that can be honest is honest.
;;   - ffi:   P1b-stage1 PARTIAL-GO (codex C4): memory ops, loading, ordinary
;;            calls and invocation-local errno capture are implemented behind
;;            the ahead-of-time native bridge (host/gambit/ffi/, built by make
;;            gambitffi-bridge). Every other row — blocking, callables,
;;            collect-safe callables, runtime signatures, object pinning —
;;            keeps its message-carrying refusal, and with the bridge absent
;;            the WHOLE tier raises again (fail-closed). Never a bare raise
;;            (jolt surfaces ex-message; that lesson is paid for).
;;   - native-compile / image: raise, message-carrying — the AOT cache and
;;            jolt.image treat the raise as a clean cache disable / unsupported.
;;   - introspect: off (sa-introspect-enabled? is #f) — frames '() / proc-info
;;            #f / zero-vector stats; backtraces render from the compile-time
;;            tables alone, exactly the documented degraded mode.
;;   - subprocess: sa-run-process raises (demo target; Gambit's open-process
;;            ports exist but the demo scope does not ship a process tier).

;; ---- system tier (capability: system) --------------------------------------

;; (sa-run-process cmd transcoder) -> (values stdin stdout stderr pid)
;; Spawn CMD (a shell string) with block buffering and the given transcoder
;; (#f = binary), returning the four process ports and the pid. Contract: a
;; target must provide exactly this shape. Degradation: a target without
;; subprocess support must raise 'unsupported — every caller genuinely needs
;; the subprocess, so none of them may be silently degraded. The G1 demo
;; raises with a message-carrying condition.
(define (sa-run-process cmd transcoder)
  (error 'sa-run-process "subprocess support is unsupported on the gambit target" cmd))

;; (sa-environment-pairs) -> list of (name . value)
;; The whole process environment, the alist R7RS get-environment-variables
;; answers, which Gambit provides. Contract: that alist. Degradation: none.
(define (sa-environment-pairs)
  (get-environment-variables))

;; (sa-os-release) -> string | #f
;; The OS's own version string (the product version on macOS, the kernel
;; release elsewhere), or #f. Contract: that string or #f. Degradation: #f,
;; which leaves os.version out of the system properties; the demo target does
;; not probe the OS.
(define (sa-os-release)
  #f)

;; (sa-gc-collect) -> void
;; A full collection hint (every generation) — what the Runtime.gc /
;; System.gc callers mean: weak references clear and guardians fire.
;; Contract: perform a full collection. Degradation: may no-op — callers
;; already guard the call and the JVM semantic is only a hint. Gambit's
;; This target now invokes ##gc explicitly (stage-1).
;; sa-record-cas!: a record here is a vector with the type id in slot 0, so
;; field i is slot i+1; the swap runs under one mutex because a green thread
;; can be preempted between the read and the write.
(define sa-record-cas-mu (make-mutex))
(define (sa-record-cas! r i old new)
  (jwm-call sa-record-cas-mu
    (lambda ()
      (let ((k (+ i 1)))
        (if (eq? (vector-ref r k) old)
            (begin (vector-set! r k new) #t)
            #f)))))

;; sa-box-cas!: the same swap on a box, under the same mutex.
(define (sa-box-cas! b old new)
  (jwm-call sa-record-cas-mu
    (lambda ()
      (if (eq? (unbox b) old)
          (begin (set-box! b new) #t)
          #f))))

;; P1b-stage1: the REAL collection, not the pre-stage1 no-op. ##gc is Gambit's
;; own collection entry (lib/_kernel.scm's (##gc)); a caller that drops its
;; references before the call observes weak keys cleared; gambitcheck asserts
;; that behavior (no heap-size or blocked-call GC claim).
;; Return value mirrors the Chez adapter's success spelling ('ok).
(define (sa-gc-collect)
  (##gc)
  'ok)

;; (sa-gc-max-generation) -> exact integer
;; The deepest collectable generation, for callers mapping JVM generations.
;; Contract: return the maximum generation argument sa-gc-collect accepts.
;; Degradation: a single-generation collector returns 0.
(define (sa-gc-max-generation)
  0)

;; (sa-bytes-allocated) -> exact integer
;; Live-heap bytes — the "used" reading under current-memory-bytes that
;; Runtime.freeMemory is built from. Contract: bytes currently allocated and
;; live. Degradation: an approximation is acceptable; callers only subtract it
;; from total to compute free memory. Gambit's ##bytes-allocated is used when
;; bound (gsi native); 0 otherwise.
(define (sa-bytes-allocated)
  (guard (e (#t 0))
    (##bytes-allocated)))

;; (sa-total-memory-bytes) -> exact integer
;; Total process heap bytes — what the collector has reserved from the OS
;; (the JVM's totalMemory; Runtime.freeMemory is the difference against
;; sa-bytes-allocated). Contract: total heap bytes. Degradation: an
;; approximation is fine — callers only display it or subtract
;; sa-bytes-allocated from it. A large constant is the documented fallback
;; (the JVM arm already maps an unbounded heap to Long/MAX_VALUE).
(define (sa-total-memory-bytes)
  9223372036854775807)

;; (sa-max-memory-bytes) -> exact integer
;; Peak heap bytes since the last sa-reset-max-memory-bytes! -- the high-water
;; mark behind jolt.host/maximum-memory-bytes (not the JVM's maxMemory, which
;; is the heap ceiling). Contract: never below sa-total-memory-bytes.
;; Degradation: the current total -- Gambit keeps no high-water mark, so this
;; answers "now", which here is the same constant as the total.
(define (sa-max-memory-bytes)
  (sa-total-memory-bytes))

;; (sa-reset-max-memory-bytes!) -> void
;; Start the high-water mark over. Contract: right after it, sa-max-memory-bytes
;; answers the current total. Degradation: a no-op, which is exact here since
;; sa-max-memory-bytes already answers the current total.
(define (sa-reset-max-memory-bytes!)
  #f)

;; (sa-gc-install-after-collect! maintain observe) -> boolean
;; Permitted degradation: Gambit exposes no hook equivalent to Chez's
;; collect-request-handler, so answer #f and install nothing. The heap is then
;; unbounded and the nursery fixed, which is what every jolt before 0.8.5 did on
;; every target, and the caller reports maxMemory as unbounded rather than
;; promising a bound it cannot enforce.
(define (sa-gc-install-after-collect! maintain observe)
  #f)

;; (sa-gc-install-stall-watch! seconds on-stall) -> boolean
;; Permitted degradation: Gambit's collector is not a rendezvous of active
;; threads that a foreign call can hold off, and it exposes no hook on the
;; wait; answer #f and install nothing. The diagnostic is then absent, which
;; is what every release before 0.8.9 did on every target.
(define (sa-gc-install-stall-watch! seconds on-stall)
  #f)

;; (sa-gc-install-after-rendezvous! thunk) -> boolean
;; (sa-current-stack-bytes) -> exact integer | #f
;; Permitted degradation: #f from both. Gambit's collector is not a rendezvous
;; every thread passes through, and its continuation frames are measured only by
;; walking them. The stack is then unbounded, as it was on every target before
;; the limit: a runaway recursion grows the heap until Gambit's own heap limit
;; (or the JS engine's) stops it. The policy (rt.ss jolt-install-stack-limit!)
;; is Chez's; the Gambit kernel (rt-core.ss) does not carry it.
(define (sa-gc-install-after-rendezvous! thunk)
  #f)
(define (sa-current-stack-bytes)
  #f)

;; (sa-thread-id-of t) -> fixnum | #f
;; Permitted degradation: #f — no per-thread number is readable from a
;; thread object here, so the fork wrapper records nothing for the child and
;; nothing consumes the record (no stall watch is installed on this host).
(define (sa-thread-id-of t)
  #f)

;; (sa-real-time-ms) -> exact integer
;; Wall-clock milliseconds, monotonic within a process — used for elapsed
;; deltas (build profiling) and unique temp-file stamps. Contract: an
;; exact-integer ms clock usable for both. Gambit's (real-time) returns a
;; monotonic elapsed-seconds FLONUM (millisecond precision); convert to an
;; exact ms count.
(define (sa-real-time-ms)
  (inexact->exact (floor (* (real-time) 1000))))

;; (sa-epoch-ms) -> exact integer
;; Wall-clock milliseconds since the Unix epoch. Contract: differs between two
;; processes started at different times, which sa-real-time-ms (measured from
;; process start on Chez) does not -- used to salt ids that code compiled in one
;; process must not share with code another emitted. Degradation: none.
(define (sa-epoch-ms)
  (inexact->exact (floor (* (time->seconds (current-time)) 1000))))

;; ---- R5: io remainder (mtime) + the last GC hook -----------------------------

;; (sa-file-mtime-ms path) -> exact integer
;; Epoch milliseconds of PATH's last modification. Contract: a per-file mtime
;; usable for newer-than comparisons (build freshness, AOT cache keys, the
;; gate-boot staleness predicate). Degradation: none — stat is universal on
;; real targets; do not fake. Gambit's file-info-modification-time returns a
;; time object (converted via the bound time->seconds) or seconds directly.
(define (sa-file-mtime-ms path)
  ;; Gambit spells it file-info-last-modification-time (returns a time object);
  ;; time->seconds gives fractional epoch seconds.
  (let ((t (time->seconds (file-info-last-modification-time (file-info path)))))
    (if (number? t)
        (inexact->exact (floor (* t 1000)))
        (inexact->exact (floor (* (time->seconds t) 1000))))))

;; (sa-gc-tight! limit) -> void
;; Permitted degradation: Gambit has no in-place collection mode, so this is
;; ignored.
(define (sa-gc-tight! limit) (if #f #f))

;; (sa-make-large-bytevector n) -> bytevector
;; Permitted degradation: an ordinary bytevector; Gambit has no immobile
;; allocation to ask for.
(define (sa-make-large-bytevector n) (make-bytevector n 0))
;; (sa-pin-for-owner! owner obj) / (sa-unpin-for-owner! owner) -> void
;; Permitted degradation: both no-op; Gambit cannot be asked not to move an
;; object, and does not load the arrays that ask.
(define (sa-pin-for-owner! owner obj) (if #f #f))
(define (sa-unpin-for-owner! owner) (if #f #f))

;; (sa-gc-reserve-ratio! r) -> void
;; Permitted degradation: Gambit sizes its own heap reserve, so this is ignored.
(define (sa-gc-reserve-ratio! r) (if #f #f))

;; (sa-gc-trip-bytes! n) -> void
;; Set the allocation threshold at which a trip collection triggers — the
;; dev-cache CLI's GC tuning knob. Contract: honor N as a collection-trip
;; hint. Degradation: may no-op — the call tunes a dev cache only; collection
;; still happens on its own schedule.
(define (sa-gc-trip-bytes! n)
  #f)

;; (sa-gc-trip-bytes) -> exact integer
;; The allocation threshold at which a trip collection triggers. Contract: the
;; threshold in bytes. Degradation: 0 -- Gambit exposes no such threshold, so
;; nothing is invisible by construction and a floor built on it is no floor.
(define (sa-gc-trip-bytes)
  0)

;; ---- R6: introspection tier (capability: introspect) -------------------------

;; sa-introspect-enabled? — dynamic parameter, FIXED #f on this target. The
;; degraded-backtrace gate flips it to #f on Chez to prove that throw surfaces
;; still carry type+message while every introspect entry point returns
;; empty/#f; the gambit target IS that mode, permanently.
(define sa-introspect-enabled? (make-parameter #f))

;; (sa-host-tag) -> string
;; The runtime's host tag. NAMING ONLY: release/fasl directory names, image
;; headers, telemetry strings, error text. No logic may branch on it — logic
;; branches use sa-os-family / sa-arch / sa-endian. Contract: an opaque,
;; per-build-stable host string.
(define (sa-host-tag)
  "gambit")

;; (sa-os-family) -> 'macos | 'windows | 'linux
;; The OS family every host OS branch derives. Contract: one of the three
;; symbols. Degradation: none — the sites have no safe assumed default; an
;; unrecognized host falls back to 'linux, matching the Chez adapter's
;; else-branches. In Gambit's configuration triple Darwin uses vendor apple
;; and a versioned OS symbol (for example darwin25.6.0).
(define (sa-os-family)
  (if (memq 'apple (system-type)) 'macos 'linux))

;; (sa-arch) -> 'x86-64 | 'arm64 | 'i386 | 'other
;; The machine architecture. Contract: the architecture symbol. Degradation:
;; 'other for an unrecognized host; callers treat it as unverified.
(define (sa-arch)
  'other)

;; (sa-endian) -> 'little | 'big | #f
;; Byte order of the host. Contract: the byte order. The gambit target's
;; double-to-raw-bits byte layout (hasheq.ss) assumes little-endian; both
;; supported platforms (arm64/x86-64 macOS and linux) are little-endian.
;; (sa-flonum->bits x) / (sa-bits->flonum b): binary64 pattern as an unsigned
;; 64-bit integer and back; the high-word pair is the upper 32 bits of it.
(define (sa-flonum->bits x) (##flonum->ieee754-64 x))
(define (sa-bits->flonum b) (##ieee754-64->flonum b))
(define (sa-flonum-hi32 x) (quotient (##flonum->ieee754-64 x) 4294967296))
(define (sa-hi32->flonum h) (##ieee754-64->flonum (* h 4294967296)))

(define (sa-endian)
  'little)

;; (sa-stats) -> #(cpu-nanos real-nanos gc-count gc-cpu-nanos gc-real-nanos
;;                gc-bytes allocated-bytes)
;; One statistics snapshot as the seven exact-integer fields rt.ss reads into
;; the jolt.host telemetry vars (time fields pre-converted to nanos).
;; allocated-bytes is every byte allocated since the process started, freed or
;; not. Contract: the seven fields in this order. Degradation: a zero vector —
;; the OTel layer maps zeros to absent metrics.
(define (sa-stats)
  (vector 0 0 0 0 0 0 0))

;; (sa-continuation-frames k) -> list of frame inspectors | '()
;; The continuation's frames, innermost first. Contract: stepping a throw
;; continuation. Degradation: '() — the backtrace then renders from the
;; compile-time tables alone (jolt-backwalk) or reports no frames.
(define (sa-continuation-frames k)
  '())

;; (sa-procedure-info x) -> (name . ((free-name . value) ...)) | #f
;; A procedure's inspector name and live free-variable captures. Contract:
;; name + captured values. Degradation: #f — the image writer refuses the
;; closure ('image-no), the same verdict as today's no-inspector builds.
(define (sa-procedure-info x)
  #f)

;; (sa-procedure-code-name p) -> string | #f. Gambit names a procedure by its
;; define, not by a let binding, so a closure of an inner lambda answers #f;
;; the contract permits #f.
(define (sa-procedure-code-name p)
  (let ((n (##procedure-name p)))
    (and (symbol? n) (symbol->string n))))

;; ---- R7: ffi tier (capability: ffi) — P1b-stage1 bounded slice ---------------
;;
;; PARTIAL-GO (codex C4): memory, loading, ORDINARY calls and invocation-local
;; errno capture are IMPLEMENTED here behind the ahead-of-time native bridge
;; (host/gambit/ffi/joltffi-bridge.scm, compiled with gsc into
;; build/gambit-ffi/joltffi-bridge.o1 and loaded from gsi). Everything outside
;; the qualified set keeps its message-carrying refusal:
;;   - GC-safe blocking / blocking+errno — UNQUALIFIED on Gambit 4.9.8 (codex
;;     Q3: a processor inside a synchronous foreign call does not service
;;     on_all_processors collection barriers);
;;   - callables (dynamic closure-backed) — F6: stock 4.9.8 has no arm64/x86_64
;;     trampoline generator (___make_c_closure returns null);
;;   - collect-safe callables (foreign-thread entry), runtime-signature
;;     construction, object pinning (moving collector, no verified pin).
;; Bridge absent or load failing = fail-closed: every row raises the
;; message-carrying unsupported error again. Unregistered shapes raise BEFORE
;; any address is dereferenced — never an unbound Chez identifier (gap G-3).

(define (sa-ffi-raise who)
  (error who "ffi is unsupported on the gambit target"))

;; ---- the native bridge (loaded lazily, fail-closed) --------------------------
;; The bridge is a gsc-compiled unit; a c-lambda is a compiled facility and the
;; interpreter must never expand one (astra §2 compilation boundary). Built by
;; `make gambitffi-bridge` from the pinned source; the gates run from the repo
;; root. The bridge path is deliberately checkout-relative.

(define joltffi-bridge-loaded? #f)
(define joltffi-bridge-probed? #f)

(define (joltffi-bridge-path-candidates)
  ;; Native gates run from the checkout root; no ambient module lookup.
  (list "build/gambit-ffi/joltffi-bridge.o1"))

(define (joltffi-bridge-path-known)
  (let loop ((ps (joltffi-bridge-path-candidates)))
    (if (null? ps)
        #f
        (if (file-exists? (car ps)) (car ps) (loop (cdr ps))))))

;; (joltffi-ensure-bridge! who) -> #t, or raises the documented message-carrying
;; error. Loading is attempted once; a failed load leaves the tier refusing.
(define (joltffi-ensure-bridge! who)
  (or joltffi-bridge-loaded?
      (begin
        (if joltffi-bridge-probed?
            #f
            (begin
              (set! joltffi-bridge-probed? #t)
              ;; a bridge another path already loaded must not be re-loaded
              ;; (a second load of the same .o1 raises): probe for an export
              (if (guard (e (#t #f)) (joltffi-shim-lookup '() 'int #f #f) #t)
                  (set! joltffi-bridge-loaded? #t)
                  (let ((p (joltffi-bridge-path-known)))
                    (if p
                        (let ((ok (guard (e (#t #f))
                                    (load p)
                                    #t)))
                          (if ok (set! joltffi-bridge-loaded? #t) #f))
                        #f)))))
        (if joltffi-bridge-loaded?
            #t
            (error who
                   (string-append
                    "ffi is unsupported on the gambit target: the stage-1 native"
                    " bridge is not built or failed to load — run make gambitffi-bridge"
                    " from the repo root (looked for build/gambit-ffi/joltffi-bridge.o1)"))))))

;; ---- the loader registry (scoped, declaration order) -------------------------
;; Mirrors the Chez loader's jolt-ffi-load-native semantics (host/chez/java/
;; ffi.ss 408-448) minus its Windows arm: RTLD_NOW|RTLD_LOCAL dlopen, an
;; ordered handle list (declaration order), a path set so the same file loads
;; once, and per-candidate failure notes so MISSING and PRESENT-BUT-UNLOADABLE
;; stay distinguishable (jolt-lang/jolt#1127's reason preservation).

(define joltffi-native-mu (make-mutex))
(define joltffi-native-handles '())        ; ordered (path . handle-integer) pairs, oldest first
(define joltffi-native-paths (make-hashtable string-hash equal?))
(define joltffi-native-failures (make-hashtable string-hash equal?))

;; (joltffi-load-native path) -> path on success, #f on failure (note recorded).
;; A repeat load of an already-registered path is a no-op success.
(define (joltffi-load-native path)
  (if (not (string? path))
      #f
      (jwm-call joltffi-native-mu
        (lambda ()
          (cond
            ((hashtable-ref joltffi-native-paths path #f) path)
            (else
             (joltffi-dlerror)             ; clear any stale error first
             (let ((h (joltffi-dlopen path)))
               (if (and h (not (= h 0)))
                   (begin
                     (hashtable-set! joltffi-native-paths path #t)
                     (set! joltffi-native-handles
                           (append joltffi-native-handles (list (cons path h))))
                     path)
                   (let ((why (joltffi-dlerror)))
                     (hashtable-set! joltffi-native-failures path (or why "dlopen failed"))
                     #f)))))))))

;; (joltffi-resolvers sym) -> ordered (path . address) pairs across the declared
;; handles — every library through which SYM resolves, so duplicate-definition
;; detection can compare ADDRESSES, not handle counts (issue #731: dlsym also
;; searches a handle's dependency chain, so one address through several handles
;; is one copy, not a duplicate).
(define (joltffi-resolvers sym)
  (let loop ((hs joltffi-native-handles) (acc '()))
    (if (null? hs)
        (reverse acc)
        (let ((a (joltffi-dlsym (cdar hs) sym)))
          (loop (cdr hs)
                (if (and a (not (= a 0)))
                    (cons (cons (car hs) a) acc)
                    acc))))))

;; distinct definitions, one per ADDRESS, naming the first library that reaches it
(define (joltffi-definers sym)
  (let loop ((rs (joltffi-resolvers sym)) (seen '()) (acc '()))
    (cond
      ((null? rs) (reverse acc))
      ((memv (cdar rs) seen) (loop (cdr rs) seen acc))
      (else (loop (cdr rs) (cons (cdar rs) seen) (cons (car rs) acc))))))

;; (joltffi-dlsym-loaded sym) -> address | #f — the scoped probe. Resolves
;; against the FIRST declared native (declaration order); the definers list is
;; the duplicate diagnostic (jolt.ffi/defining-libraries in host-ffi.ss).
(define (joltffi-dlsym-loaded sym)
  (let ((rs (joltffi-resolvers sym)))
    (if (null? rs) #f (cdar rs))))

;; (joltffi-handle-of path) -> handle | #f — the dlopen handle a load
;; registered for PATH (the registry records the candidate that opened).
(define (joltffi-handle-of path)
  (let loop ((hs joltffi-native-handles))
    (cond ((null? hs) #f)
          ((string=? (caar hs) path) (cdar hs))
          (else (loop (cdr hs))))))

;; process-global resolution (RTLD_DEFAULT). RTLD_LOCAL natives are
;; deliberately invisible here — the one-way scoped-shadows-global guarantee.
(define (joltffi-resolve-global name who)
  (joltffi-dlerror)
  (let ((a (joltffi-dlsym-global name)))
    (if (or (joltffi-dlerror) (not a) (= a 0))
        (error who
               (string-append "jolt.ffi: no entry for \"" name
                              "\" — not in any loaded native and not in the process's global symbols"))
        a)))

;; (jolt-ffi-dlsym-native sym) -> address | #f
;; The compiler's emitted scoped probe (backend ffi-named-procedure-expr's
;; scoped branch): the loaded handles in declaration order; #f sends the
;; emitter to its by-name fallback. The Chez version's pending-loads seam
;; (ldr-natives-load-all!) has no gambit loader yet — a dependency's natives
;; load when their namespace loads (documented stage-1 limit).
(define (jolt-ffi-dlsym-native sym)
  (joltffi-ensure-bridge! 'jolt-ffi-dlsym-native)
  (if (string? sym)
      (joltffi-dlsym-loaded sym)
      #f))

;; ---- construction-time shape validation --------------------------------------
;; Unregistered shapes raise DELIBERATELY here, at binding construction, with
;; the full signature in the message — before any address is resolved or
;; dereferenced (astra: "unregistered shapes must raise", never an unbound
;; Chez identifier).

(define (joltffi-sig-string argtypes res)
  (string-append "("
                 (let loop ((ts argtypes) (first #t) (acc ""))
                   (if (null? ts)
                       acc
                       (loop (cdr ts) #f
                             (string-append acc (if first "" " ")
                                            (symbol->string (car ts))))))
                 ") -> " (symbol->string res)))

(define (joltffi-unregistered-raise who argtypes res)
  (error who
         (string-append "jolt.ffi: no gambit shim for signature "
                        (joltffi-sig-string argtypes res)
                        " — unregistered shape on the gambit target"
                        " (the stage-1 registry covers the non-blocking p1b-inv"
                        " shapes only; see p1b-inv/shim-registry.edn)")))

;; argument-type sanity for anything the shim set cannot carry: :string
;; arguments (emitted as u8*) need an immobile copy, which Gambit cannot
;; provide (moving collector, no immobile allocation) — refused with a
;; message-carrying error, and never a registered shape.
(define (joltffi-check-argtypes! who argtypes)
  (for-each
   (lambda (t)
     (if (or (eq? t 'string) (eq? t 'u8*))
         (error who
                (string-append
                 "jolt.ffi: :string arguments are unsupported on the gambit target"
                 " — no immobile allocation behind the stage-1 bridge (signature: "
                 (symbol->string t) " argument)"))))
   argtypes))

;; ret-type sanity: by-value aggregates and the (& ftype) destination convention
;; are Chez ftype facilities the stage-1 registry does not carry (the compiler's
;; :gambit arm refuses them earlier; this is the defensive layer behind it).
(define (joltffi-check-ret! who res)
  (if (pair? res)
      (error who
             (string-append "jolt.ffi: aggregate results are unsupported on the"
                            " gambit target — no ftype engine behind the stage-1"
                            " bridge (result: (& ...))"))))

;; (joltffi-foreign-procedure argtypes res name) -> procedure
;; ARGTYPES/RES: the Chez foreign-type tokens the compiler emits (symbols).
;; NAME: a string (by-name, resolved lazily on first call through the process's
;; global symbols — the emitter's fallback) or an ADDRESS (the scoped branch:
;; jolt-ffi-dlsym-native already resolved a declared native). The shim is
;; selected from the bridge registry by (argtypes ret); the resolved address is
;; its first argument, exactly astra §2's "typed, generated C shims per call
;; shape, shared across symbols with identical ABI shapes".
(define (joltffi-foreign-procedure argtypes res name variadic)
  (joltffi-ensure-bridge! 'sa-foreign-procedure)
  (joltffi-check-argtypes! 'sa-foreign-procedure argtypes)
  (joltffi-check-ret! 'sa-foreign-procedure res)
  (let ((wrapper (joltffi-shim-lookup argtypes res #f variadic)))
    (if (not wrapper)
        (joltffi-unregistered-raise 'sa-foreign-procedure argtypes res)
        (if (string? name)
            ;; by-name: resolve lazily on first call and cache, like the Chez
            ;; emitter's (or p ...) first-call binding caches its resolution
            (let ((addr #f) (resolved? #f))
              (lambda args
                (if (not resolved?)
                    (begin (set! addr (or (joltffi-dlsym-loaded name) (joltffi-resolve-global name 'sa-foreign-procedure)))
                           (set! resolved? #t)))
                (apply wrapper addr args)))
            ;; scoped address — take it as-is (the emitter's null check ran)
            (lambda args
              (apply wrapper name args))))))

;; (joltffi-foreign-capture-procedure argtypes res name) -> two-value procedure
;; The native-error half: EVERY call allocates its own errno cell BEFORE the
;; target call, the shim captures IMMEDIATELY after the target returns (before
;; any allocation/cleanup/runtime re-entry — astra §2), and the Scheme side
;; reads the cell and frees it. Invocation-local: no global or TLS "last errno"
;; cell, so nested and concurrent calls cannot clobber each other.
(define (joltffi-foreign-capture-procedure argtypes res name variadic)
  (joltffi-ensure-bridge! 'sa-foreign-procedure-native-error)
  (joltffi-check-argtypes! 'sa-foreign-procedure-native-error argtypes)
  (joltffi-check-ret! 'sa-foreign-procedure-native-error res)
  (let ((wrapper (joltffi-shim-lookup argtypes res #t variadic)))
    (if (not wrapper)
        (joltffi-unregistered-raise 'sa-foreign-procedure-native-error argtypes res)
        (let ((addr (and (not (string? name)) name)))
          (lambda args
            (unless addr
              (set! addr (or (joltffi-dlsym-loaded name)
                             (joltffi-resolve-global name 'sa-foreign-procedure-native-error))))
            ;; Cell lifetime covers conversion errors too; order is explicit.
            (let ((cell (sa-foreign-alloc 4)))
              (dynamic-wind
                (lambda () #f)
                (lambda ()
                  (let* ((r (apply wrapper addr cell args))
                         (e (joltffi-read-i32 cell)))
                    (values r e)))
                (lambda () (sa-foreign-free cell)))))))))

;; ---- constructor macros -------------------------------------------------------
;; define-MACRO (not define-syntax): the argument positions carry the literal
;; signature, which must be parsed and validated at construction. The macros
;; only NORMALIZE; every decision (bridge presence, registration, refusal) is a
;; runtime state-derived check. The gambit boot reaches them via ##include (one
;; compilation unit) and via eval on gsi, where unit macros are visible.
;; The js target's eval cannot see unit macros — that target keeps the entire
;; ffi tier excluded (no bridge, no jolt.ffi runtime), so nothing reaches the
;; macros there; the native gsi leg is the qualification surface.

(define-macro (sa-foreign-procedure . form)
  (cond
    ((= (length form) 3)
     `(joltffi-foreign-procedure ',(cadr form) ',(caddr form) ,(car form) #f))
    ((and (= (length form) 4) (pair? (car form))
          (eq? (caar form) '__varargs_after) (= (length (car form)) 2))
     `(joltffi-foreign-procedure ',(caddr form) ',(cadddr form) ,(cadr form) ,(cadar form)))
    (else `(sa-ffi-raise 'sa-foreign-procedure))))

(define-macro (sa-foreign-procedure-native-error . form)
  (if (= (length form) 5)
      (let ((conv (cadr form)) (name (caddr form))
            (args (cadddr form)) (res (car (cddddr form))))
        (cond
          ((equal? conv '(__collect_safe)) `(sa-foreign-procedure-blocking-raise))
          ((null? conv) `(joltffi-foreign-capture-procedure ',args ',res ,name #f))
          ((and (= (length conv) 1) (pair? (car conv))
                (eq? (caar conv) '__varargs_after) (= (length (car conv)) 2))
           `(joltffi-foreign-capture-procedure ',args ',res ,name ,(cadar conv)))
          (else `(sa-ffi-raise 'sa-foreign-procedure-native-error))))
      `(sa-ffi-raise 'sa-foreign-procedure-native-error)))

;; The compiler emits this target wrapper so Chez can select errno versus
;; GetLastError at expansion time. On the gambit target the conv slot carries
;; () for ordinary capture, (__collect_safe) for the refused blocking
;; combination, and ((__varargs_after n)) for declared-tail varargs capture.
(define-macro (jolt-ffi-native-error-procedure . form)
  `(sa-foreign-procedure-native-error unsupported-native-error ,@form))

;; (sa-foreign-procedure-blocking name args res) -> never returns a procedure
;; REFUSED (codex C4): GC-safe blocking is unqualified on Gambit 4.9.8 — a
;; processor inside a synchronous foreign call does not participate in
;; on_all_processors collection barriers, and the release/claim mechanism astra
;; §2 requires has no verified 4.9.8 implementation (codex Q3/Q4; the MT
;; experiment confirmed the failure mode). Message-carrying, never bare.
(define (sa-foreign-procedure-blocking-raise)
  (error 'sa-foreign-procedure-blocking
         "blocking ffi is unsupported on the gambit target — GC-safe blocking is unqualified on Gambit 4.9.8 (no verified release/claim transition)"))

(define-macro (sa-foreign-procedure-blocking . form)
  `(sa-foreign-procedure-blocking-raise))

;; (sa-foreign-callable proc args res) -> never returns a callable
;; REFUSED (codex C4/F6): dynamic closure-backed callables need a trampoline
;; generator; stock Gambit 4.9.8's C_CLOSURE_CODE_SIZE covers neither arm64
;; nor x86_64, so ___make_c_closure answers null. Static c-define fixtures do
;; not qualify this row (codex F6).
(define (sa-foreign-callable-raise)
  (error 'sa-foreign-callable
         "foreign callables are unsupported on the gambit target — dynamic closure-backed callables are unqualified (no arm64/x86_64 trampoline generator in stock Gambit 4.9.8)"))

(define-macro (sa-foreign-callable . form)
  `(sa-foreign-callable-raise))

(define (sa-foreign-callable-collect-safe-raise)
  (error 'sa-foreign-callable-collect-safe
         "foreign-thread callbacks are unsupported on the gambit target — generic foreign-pthread entry is unqualified (no verified attachment/claim protocol)"))
(define-macro (sa-foreign-callable-collect-safe . form)
  `(sa-foreign-callable-collect-safe-raise))

;; (sa-foreign-procedure-runtime name args res blocking?) -> raise
;; REFUSED: constructing procedures for RUNTIME-discovered signatures is the
;; open-ended shape space a finite registry cannot claim (astra §2; the
;; inventory's :runtime-signature-eval class).
(define (sa-foreign-procedure-runtime name args res blocking?)
  (error 'sa-foreign-procedure-runtime
         "runtime-signature ffi construction is unsupported on the gambit target — a finite shim registry cannot claim runtime-discovered signatures"))

;; ---- memory ops (qualified; through the bridge) -------------------------------
;; Pointers are exact integers (jolt's own pointer semantics — a jolt pointer
;; IS a raw address). Widths are exact for LP64 layouts (LP64).

(define (sa-foreign-alloc n)
  (joltffi-ensure-bridge! 'sa-foreign-alloc)
  (if (and (exact-integer? n) (>= n 0))
      (let ((p (joltffi-malloc n)))
        (if (and (= p 0) (> n 0))
            (error 'sa-foreign-alloc "jolt.ffi: native allocation failed" n)
            p))
      (error 'sa-foreign-alloc "jolt.ffi: allocation size must be an exact integer" n)))

(define (sa-foreign-free p)
  (joltffi-ensure-bridge! 'sa-foreign-free)
  (joltffi-free p))

;; typed access: the TYPE VOCABULARY is the contract's — Chez's foreign type
;; symbols (the values jolt.ffi's ffi-type->chez produces). Reads/writes go
;; through memcpy-based bridge helpers, so unaligned offsets behave.
(define (sa-foreign-ref type addr off)
  (joltffi-ensure-bridge! 'sa-foreign-ref)
  (case type
    ((int) (joltffi-ref-i32 addr off))
    ((unsigned-int) (joltffi-ref-u32 addr off))
    ((integer-8) (joltffi-ref-i8 addr off))
    ((unsigned-8) (joltffi-ref-u8 addr off))
    ((integer-16) (joltffi-ref-i16 addr off))
    ((unsigned-16) (joltffi-ref-u16 addr off))
    ((integer-32) (joltffi-ref-i32 addr off))
    ((unsigned-32) (joltffi-ref-u32 addr off))
    ((integer-64 ssize_t long iptr) (joltffi-ref-i64 addr off))
    ((unsigned-64 size_t unsigned-long uptr) (joltffi-ref-u64 addr off))
    ((double) (joltffi-ref-f64 addr off))
    ((float) (joltffi-ref-f32 addr off))
    ((void*) (joltffi-ref-u64 addr off))
    ((char) (joltffi-ref-i8 addr off))
    (else
     (error 'sa-foreign-ref
            (string-append "jolt.ffi: unsupported foreign type "
                           (if (symbol? type) (symbol->string type) (object->string type))
                           " on the gambit target")))))

(define (sa-foreign-set! type addr off v)
  (joltffi-ensure-bridge! 'sa-foreign-set!)
  (case type
    ((int integer-32) (joltffi-set-i32! addr off v))
    ((unsigned-int unsigned-32) (joltffi-set-u32! addr off v))
    ((integer-8) (joltffi-set-i8! addr off v))
    ((unsigned-8) (joltffi-set-u8! addr off v))
    ((integer-16) (joltffi-set-i16! addr off v))
    ((unsigned-16) (joltffi-set-u16! addr off v))
    ((integer-64 ssize_t long iptr) (joltffi-set-i64! addr off v))
    ((unsigned-64 size_t unsigned-long uptr) (joltffi-set-u64! addr off v))
    ((double) (joltffi-set-f64! addr off v))
    ((float) (joltffi-set-f32! addr off v))
    ((void*) (joltffi-set-u64! addr off v))
    ((char) (joltffi-set-i8! addr off v))
    (else
     (error 'sa-foreign-set!
            (string-append "jolt.ffi: unsupported foreign type "
                           (if (symbol? type) (symbol->string type) (object->string type))
                           " on the gambit target")))))

;; bulk octet moves: ONE block copy foreign<->bytevector per call, the same
;; shape the Chez adapter's memcpy path gives. The bytevector's body is
;; borrowed for the duration of the synchronous call only (no collection can
;; run inside it on this runtime); a count past the bytevector's end raises
;; here, before the bridge dereferences anything.
(define (sa-foreign-bytes-ref! addr bv n)
  (joltffi-ensure-bridge! 'sa-foreign-bytes-ref!)
  (if (not (u8vector? bv))
      (error 'sa-foreign-bytes-ref! "jolt.ffi: bulk copy target must be a bytevector"))
  (if (or (not (exact-integer? n)) (< n 0) (> n (u8vector-length bv)))
      (error 'sa-foreign-bytes-ref! "jolt.ffi: bulk copy count exceeds the bytevector" n))
  (if (not (= 0 (joltffi-bytes-to-bv! bv addr n)))
      (error 'sa-foreign-bytes-ref! "jolt.ffi: bulk copy refused by the bridge" n)))

(define (sa-foreign-bytes-set! addr bv n)
  (joltffi-ensure-bridge! 'sa-foreign-bytes-set!)
  (if (not (u8vector? bv))
      (error 'sa-foreign-bytes-set! "jolt.ffi: bulk copy source must be a bytevector"))
  (if (or (not (exact-integer? n)) (< n 0) (> n (u8vector-length bv)))
      (error 'sa-foreign-bytes-set! "jolt.ffi: bulk copy count exceeds the bytevector" n))
  (if (not (= 0 (joltffi-bytes-from-bv! addr bv n)))
      (error 'sa-foreign-bytes-set! "jolt.ffi: bulk copy refused by the bridge" n)))

(define (sa-foreign-zero! addr n)
  (joltffi-ensure-bridge! 'sa-foreign-zero!)
  (joltffi-zero addr n))

;; Sizes below describe LP64 (only macOS arm64 is qualified here).
;; :bool travels as unsigned-8 (the one-byte C99 _Bool); the
;; value conversion happens at the boundary, not in the width.
(define (sa-foreign-sizeof type)
  (joltffi-ensure-bridge! 'sa-foreign-sizeof)
  (case type
    ((integer-8 char) 1)
    ((unsigned-8) 1)
    ((integer-16 unsigned-16) 2)
    ((integer-32 unsigned-32 int unsigned-int float) 4)
    ((integer-64 unsigned-64 size_t ssize_t long unsigned-long iptr uptr double void*) 8)
    (else
     (error 'sa-foreign-sizeof
            (string-append "jolt.ffi: no size for foreign type "
                           (if (symbol? type) (symbol->string type) (object->string type))
                           " on the gambit target")))))

;; (sa-lock-object x) -> never returns
;; REFUSED (astra §2 Memory): Gambit's collector MOVES objects; rooting
;; prevents reclamation but not relocation, and no verified pinning mechanism
;; exists on 4.9.8. Inheriting the non-moving-collector no-op exemption would
;; be a silent lie — a consistent refusal, never a one-sided pin.
(define (sa-lock-object x)
  (error 'sa-lock-object
         "object pinning is unsupported on the gambit target — the collector moves objects and no verified pinning mechanism exists"))

(define (sa-unlock-object x)
  (error 'sa-unlock-object
         "object pinning is unsupported on the gambit target — the collector moves objects and no verified pinning mechanism exists"))

;; ---- loading and resolution (qualified; scoped-first) ------------------------

;; (sa-load-shared-object name-or-#f) -> void | raises
;; The scoped loader on this target: RTLD_NOW|RTLD_LOCAL dlopen, ordered
;; registration, per-candidate failure notes (missing vs unloadable stay
;; distinguishable — the loader's own dlerror reason is preserved verbatim).
;; #f is the process-image handle, loaded once (the boot already resolves its
;; symbols through RTLD_DEFAULT; nothing to promote).
(define sa-process-symbols-loaded? #f)
(define (sa-load-shared-object name)
  (joltffi-ensure-bridge! 'sa-load-shared-object)
  (cond
    ((not name)
     (unless sa-process-symbols-loaded?
       (set! sa-process-symbols-loaded? #t))
     (if #f #f))
    ((string? name)
     (or (joltffi-load-native name)
         (error 'sa-load-shared-object
                (string-append "jolt.ffi: cannot load \"" name "\""
                               (let ((why (hashtable-ref joltffi-native-failures name #f)))
                                 (if why (string-append " — " why) ""))))))
    (else
     (error 'sa-load-shared-object "jolt.ffi: library name must be a string or nil" name))))

;; (sa-foreign-entry? name) -> boolean — scoped handles first, then the
;; process's global symbols. #f for anything unresolved (the contract).
(define (sa-foreign-entry? name)
  (joltffi-ensure-bridge! 'sa-foreign-entry?)
  (if (not (string? name))
      #f
      (or (not (eq? (joltffi-dlsym-loaded name) #f))
          (let ()
            (joltffi-dlerror)
            (let ((a (joltffi-dlsym-global name)))
              (joltffi-dlerror)          ; consume the probe's error text
              (and a (not (= a 0))))))))

;; (sa-foreign-entry-address name) -> address — resolves like sa-foreign-entry?
;; and raises for anything missing (callers only ask for known symbols).
(define (sa-foreign-entry-address name)
  (joltffi-ensure-bridge! 'sa-foreign-entry-address)
  (let ((scoped (joltffi-dlsym-loaded name)))
    (if scoped
        scoped
        (joltffi-resolve-global name 'sa-foreign-entry-address))))

;; (sa-foreign-callable-entry-point co) -> raise
;; REFUSED with the callables: there is no callable machinery to take an entry
;; point from (see sa-foreign-callable above).
(define (sa-foreign-callable-entry-point co)
  (sa-foreign-callable-raise))

;; The typed-access readers/writers (joltffi-ref-*/set-*) live in the BRIDGE
;; unit — c-lambda is a compiled facility and this file is interpreted under
;; gsi (##include-spliced). They are plain data-plane readers with no errno
;; semantics; see joltffi-bridge.scm.

;; ---- R8: eval/compile/AOT (capabilities: native-compile, image) --------------

;; (sa-baked-global sym) -> value | #f
;; The top-level value of SYM, or #f when unbound. Callers probe optionally-
;; baked globals (jolt-baked-runtime-fingerprint, jolt-baked-version-early,
;; jolt-compile-eval-form) whose values are never #f, so #f is a safe absent
;; sentinel. Contract: reflect on the running top level by symbol. Degradation:
;; #f always — the gambit target has no baked-image globals; all three callers
;; tolerate absent. jolt.scheme/proc also uses this hook for loaded source.
(define (sa-baked-global sym)
  (and (##global-var? sym)
       (let ((value (##global-var-ref (##make-global-var sym))))
         (and (not (##unbound? value)) value))))

(define logand bitwise-and)
(define logor bitwise-ior)
(define logxor bitwise-xor)
(define ash arithmetic-shift)
(define bitwise-length integer-length)
(define scheme-version system-version-string)

(##include "unicode-nfc.ss")

;; (sa-compile-file src so profile) -> void
;; Compile the Scheme source file SRC to the native object SO under PROFILE.
;; Contract: native compilation of SRC to SO. Degradation: raise a
;; message-carrying condition, never a bare raise — the AOT cache (loader.ss)
;; treats the raise as a cache disable and falls back to loading from source;
;; `jolt build` surfaces it as a jolt-level error whose message is the
;; condition's.
(define (sa-compile-file src so profile)
  (error 'sa-compile-file "native compilation is unsupported on the gambit target" src))

;; (sa-make-boot-file out base-boots) -> void
;; Assemble the boot file OUT from the base boot files BASE-BOOTS. Contract:
;; write a boot file the target's runtime can boot from. Degradation: raise —
;; same story as sa-compile-file.
(define (sa-make-boot-file out base-boots)
  (error 'sa-make-boot-file "native compilation is unsupported on the gambit target" out))

;; (sa-fasl-write obj port [externals-pred]) -> void
;; Serialize OBJ to PORT. Contract: serialize a value graph to a byte image.
;; Degradation: raise — jolt.image's dump surfaces as a clean jolt-level
;; unsupported error carrying the condition's message; the raise must be
;; message-carrying, never a bare raise.
(define (sa-fasl-write obj port . rest)
  (error 'sa-fasl-write "fasl serialization is unsupported on the gambit target"))

;; (sa-fasl-read port [who exts]) -> value
;; Deserialize the next object from PORT. Contract: read back what
;; sa-fasl-write wrote. Degradation: raise — same story as sa-fasl-write.
(define (sa-fasl-read port . rest)
  (error 'sa-fasl-read "fasl serialization is unsupported on the gambit target"))

;; ---- execution-count profiling (capability: profile) -----------------------
;; Gambit's compiler has no per-expression counters to read back, so this tier
;; takes the contract's degradation throughout: jolt.profile reports profiling
;; as unsupported and every reading is empty.
(define (sa-profile-instrument! on?) (not on?))
(define (sa-profile-instrumenting?) #f)
(define (sa-profile-compile thunk) (thunk))
(define (sa-profile-counts) '())
(define (sa-profile-release!) '())
;; no block counters, so no build here can be profile-guided
(define (sa-block-profile-dump! path tag) 0)
(define (sa-block-profile-tag path) (error 'sa-block-profile-tag "no block profiles on this target" path))
(define (sa-block-profile-load-unit! paths src) #f)
(define (sa-profile-clear!) (if #f #f))

;; ---- stack sampling (capability: sample) ------------------------------------
;; No engine timer per thread to drive a sampler from, so this tier degrades:
;; jolt.profile reports sampling as unsupported.
(define (sa-stack-walk k cap proc) #f)
(define (sa-frame-source-pair frame) #f)
(define (sa-code-name code) #f)
(define (sa-thread-cpu-nanos) 0)
;; The shared lazy-bridge.ss fork wrapper asks the Chez tick scheduler whether a
;; new thread should join the sampler (host/chez/ticks.ss). Never, here.
(define jolt-tick-sampling? #f)
(define (jolt-tick-join-sampling!) (if #f #f))
(define (jolt-tick-watch!) (if #f #f))


;; ---- continuations tier (capability: continuations) -------------------------

;; (sa-call-with-escape-continuation proc) -> value
;; The one-shot ESCAPE continuation jolt.continuations is built on. Gambit's
;; usable primitive is call/cc (the same R0(e) finding the fiber scheduler
;; below rests on: ##continuation-capture/##continuation-graft SIGBUS gsi on
;; same-stack re-entry), and call/cc is MULTI-SHOT — so the one-shot half of
;; the contract is this adapter's job, not something the primitive gives.
;;
;; The spent flag is what supplies it. Chez's call/1cc refuses a second
;; invocation and refuses one after the capturing call returned; both refusals
;; are reproduced here, because without them a re-invocation would graft
;; control back into a frame that already finished and silently re-run the
;; caller's half-completed expression — the exact trap the fiber scheduler
;; below avoids by construction rather than by checking.
;;
;; The flag is set on the normal return as well as on the escape: after PROC
;; answers, this capture is no longer live, and a saved k invoked later must
;; raise rather than re-enter. The layer above (host/chez/continuations.ss)
;; adds the thread/fiber ownership rule and the jolt-level error; a target owes
;; only the one-shot primitive.
(define (sa-call-with-escape-continuation proc)
  (call/cc
   (lambda (k)
     (let ((spent #f))
       (let ((v (proc (lambda (val)
                        (if spent
                            (error 'sa-call-with-escape-continuation
                                   "escape continuation is spent")
                            (begin (set! spent #t) (k val)))))))
         (set! spent #t)
         v)))))

;; ---- fibers R1: coroutines tier (capability: coroutines) --------------------
;; Stackful green threads sharing one OS thread, per CONTRACT.txt's coroutines
;; tier. R0(e) pinned the primitive: ##continuation-capture/##continuation-graft
;; SIGBUS gsi on same-stack re-entry; call/cc is the usable primitive (the
;; switch is ~10x the Chez cost interpreted, and there is no transparent IO
;; parking on this target, so `go` stays on OS threads — the plan's documented
;; degradation). The scheduler mirrors host/chez/fibers.ss: each park captures
;; a FRESH continuation and the scheduler invokes each continuation exactly
;; once, so call/cc's multi-shot-ness is never exercised (the plan's one-shot
;; discipline — a resumed fiber must never re-enter the caller's half-finished
;; expression). The current fiber rides a plain global here — the virtual
;; register is a Chez perf choice (R0(c): 2ns vs 33ns thread-parameter write),
;; not a contract shape.

(define-record-type jolt-fiber
  (fields (mutable state)
          thunk
          (mutable k)
          (mutable result)
          (mutable error)
          (mutable next)
          (mutable slice))
  (nongenerative jolt-fiber-v1))

(define jolt-fiber-q-head #f)
(define jolt-fiber-q-tail #f)
(define jolt-sched-k #f)
(define jolt-gambit-current-fiber #f)

(define (jolt-current-fiber) jolt-gambit-current-fiber)

(define (jolt-fiber-enqueue! f)
  (if jolt-fiber-q-tail
      (begin (jolt-fiber-next-set! jolt-fiber-q-tail f)
             (set! jolt-fiber-q-tail f))
      (begin (set! jolt-fiber-q-head f)
             (set! jolt-fiber-q-tail f))))

(define (jolt-fiber-dequeue!)
  (let ((f jolt-fiber-q-head))
    (if f
        (begin
          (set! jolt-fiber-q-head (jolt-fiber-next f))
          (if (not jolt-fiber-q-head) (set! jolt-fiber-q-tail #f))
          (jolt-fiber-next-set! f #f)
          f)
        #f)))

(define (jolt-fiber-to-scheduler! f)
  (set! jolt-gambit-current-fiber #f)
  (call/cc
    (lambda (k)
      (jolt-fiber-k-set! f k)
      (jolt-sched-k))))

(define (sa-fiber-yield)
  (let ((f (jolt-current-fiber)))
    (if f
        (begin (jolt-fiber-state-set! f 'ready)
               (jolt-fiber-enqueue! f)
               (jolt-fiber-to-scheduler! f))
        (error 'sa-fiber-yield "yield called outside a fiber"))))

(define (jolt-fiber-park!)
  (let ((f (jolt-current-fiber)))
    (if f
        (begin (jolt-fiber-state-set! f 'parked)
               (jolt-fiber-to-scheduler! f))
        (error 'jolt-fiber-park! "park called outside a fiber"))))

(define (sa-fiber-resume f)
  (if (eq? (jolt-fiber-state f) 'parked)
      (begin (jolt-fiber-state-set! f 'ready)
             (jolt-fiber-enqueue! f))
      #f))

(define (sa-fiber-spawn thunk)
  (let ((f (make-jolt-fiber 'ready thunk #f #f #f #f #f)))
    (jolt-fiber-enqueue! f)
    f))

(define (jolt-fiber-run f)
  (set! jolt-gambit-current-fiber f)
  (call/cc
    (lambda (k)
      (set! jolt-sched-k k)
      (jolt-fiber-resume* f))))

(define (jolt-fiber-resume* f)
  (case (jolt-fiber-state f)
    ((ready)
     (if (jolt-fiber-k f)
         ((jolt-fiber-k f))
         (begin
           (jolt-fiber-state-set! f 'running)
           (let ((r (guard (e (#t (jolt-fiber-dead! f e)))
                      ((jolt-fiber-thunk f)))))
             (jolt-fiber-done! f r)))))
    (else (error 'jolt-fiber-run "fiber in unexpected state"
                 (jolt-fiber-state f)))))

(define (jolt-fiber-done! f r)
  (jolt-fiber-state-set! f 'done)
  (jolt-fiber-result-set! f r)
  (jolt-fiber-k-set! f #f)
  (set! jolt-gambit-current-fiber #f)
  (jolt-sched-k))

(define (jolt-fiber-dead! f e)
  (jolt-fiber-state-set! f 'dead)
  (jolt-fiber-error-set! f e)
  (jolt-fiber-k-set! f #f)
  (set! jolt-gambit-current-fiber #f)
  (jolt-sched-k))

(define (sa-fiber-run-all)
  (let loop ()
    (let ((f (jolt-fiber-dequeue!)))
      (if f
          (begin (jolt-fiber-run f) (loop))
          #f))))

;; ---- terminal tier (capability: terminal) -----------------------------------
;; No terminal on this target, the contract's permitted degradation: the
;; terminal is never claimed, and the REPL reads lines as it does from a pipe.
;; (sa-make-output-port name put! put-some! flush! clear! close!) -> #f: no
;; handler-backed ports here, so the process streams stay Gambit's own.
(define (sa-make-output-port . _) #f)
(define (sa-term-open) #f)
(define (sa-term-closed . _) (error "sa-term: no terminal on this target"))
(define sa-term-raw! sa-term-closed)
(define sa-term-cooked! sa-term-closed)
(define sa-term-read-char sa-term-closed)
(define sa-term-size sa-term-closed)
(define sa-term-write-char sa-term-closed)
(define sa-term-char-width sa-term-closed)
(define sa-term-flush sa-term-closed)
(define sa-term-move! sa-term-closed)
(define sa-term-clear! sa-term-closed)
(define sa-term-cr! sa-term-closed)
(define sa-term-lf! sa-term-closed)
(define sa-term-bell! sa-term-closed)
(define sa-term-pause! sa-term-closed)
(define sa-term-color! sa-term-closed)

;; --- capability-unchecked ---------------------------------------------------
;; The unchecked fixnum / vector primitives (CONTRACT.txt): this target expands
;; them to the checked primitives — the permitted degradation.
(define-syntax sa-ufx+ (syntax-rules () ((_ a b) (fx+ a b))))
(define-syntax sa-ufx- (syntax-rules () ((_ a b) (fx- a b))))
(define-syntax sa-ufx<? (syntax-rules () ((_ a b) (fx<? a b))))
(define-syntax sa-ufx>=? (syntax-rules () ((_ a b) (fx>=? a b))))
(define-syntax sa-ufx=? (syntax-rules () ((_ a b) (fx=? a b))))
(define-syntax sa-uvector-ref (syntax-rules () ((_ v i) (vector-ref v i))))
(define-syntax sa-uvector-set! (syntax-rules () ((_ v i x) (vector-set! v i x))))
(define-syntax sa-ustring-ref (syntax-rules () ((_ s i) (string-ref s i))))
;; The flonum family. Gambit binds no flvector and no R6RS bytevector-ieee
;; accessors: its flonum vector is the f64vector, a bytevector is a u8vector,
;; and an IEEE pattern converts through ##flonum->ieee754-32/64 and back. So
;; these are the checked equivalents built from those, in native byte order
;; (sa-endian: little on every supported platform). Nothing on this target
;; calls them yet (typed arrays and the ffi tier are Chez-only); they keep the
;; contract whole for the day something does.
(define (sa-g-bv-uint bv at width . order)
  (let ((big? (equal? order '(big))))
    (let loop ((k 0) (acc 0))
      (if (= k width)
          acc
          (let ((i (if big? k (- width k 1))))
            (loop (+ k 1) (+ (* acc 256) (u8vector-ref bv (+ at i)))))))))
(define (sa-g-bv-uint-set! bv at width n . order)
  (let ((big? (equal? order '(big))))
    (let loop ((k 0) (n n))
      (when (< k width)
        (let ((i (if big? (- width k 1) k)))
          (u8vector-set! bv (+ at i) (bitwise-and n 255))
          (loop (+ k 1) (arithmetic-shift n -8)))))))

;; Raw Scheme escape-hatch clients pass the R6RS explicit byte order.
(define (bytevector-ieee-double-set! bv at x order)
  (sa-g-bv-uint-set! bv at 8 (##flonum->ieee754-64 x) order))
(define (bytevector-ieee-double-ref bv at order)
  (##ieee754-64->flonum (sa-g-bv-uint bv at 8 order)))
(define (bytevector-u64-ref bv at order)
  (sa-g-bv-uint bv at 8 order))
(define (bytevector-u32-set! bv at n order)
  (unless (and (exact-integer? n) (<= 0 n #xffffffff))
    (error "bytevector-u32-set!: value outside unsigned 32-bit range" n))
  (sa-g-bv-uint-set! bv at 4 n order))
(define-syntax sa-uflvector-ref (syntax-rules () ((_ v i) (f64vector-ref v i))))
(define-syntax sa-uflvector-set! (syntax-rules () ((_ v i x) (f64vector-set! v i x))))
(define-syntax sa-ubytevector-ieee-single-native-ref
  (syntax-rules () ((_ bv at) (##ieee754-32->flonum (sa-g-bv-uint bv at 4)))))
(define-syntax sa-ubytevector-ieee-single-native-set!
  (syntax-rules () ((_ bv at x) (sa-g-bv-uint-set! bv at 4 (##flonum->ieee754-32 x)))))
(define-syntax sa-ubytevector-ieee-double-native-ref
  (syntax-rules () ((_ bv at) (##ieee754-64->flonum (sa-g-bv-uint bv at 8)))))
(define-syntax sa-ubytevector-ieee-double-native-set!
  (syntax-rules () ((_ bv at x) (sa-g-bv-uint-set! bv at 8 (##flonum->ieee754-64 x)))))
;; gambit's vector-copy! / string-copy! have the R7RS shape already
(define (sa-vector-copy-range! to at from start end)
  (vector-copy! to at from start end))
(define (sa-string-copy-range! to at from start end)
  (string-copy! to at from start end))
(define (sa-bytevector-copy-range! to at from start end)
  (bytevector-copy! to at from start end))
(define (sa-vector-copy v) (subvector v 0 (vector-length v)))
(define (sa-subvector v start end) (subvector v start end))
(define sa-vector-append vector-append)

;; Shared-table reads, inline-cache site cells, epoch counters, published
;; tables, and multimethod snapshot tables. On Gambit, keep existing fast
;; direct operations.
(define-syntax sa-shared-read
  (syntax-rules ()
    ((_ _mu expr) expr)))

(define-syntax sa-shared-intern
  (syntax-rules ()
    ((_ mu hit-expr miss-expr)
     (or hit-expr (jolt-with-mutex mu (or hit-expr miss-expr))))))

(define-syntax sa-seqlock-read
  (syntax-rules ()
    ((_ _mu _gen-box expr) expr)))

(define-syntax sa-site-cell-make
  (syntax-rules ()
    ((_ init) (vector init))))

(define-syntax sa-site-cell-ref
  (syntax-rules ()
    ((_ cell) (vector-ref cell 0))))

(define-syntax sa-site-cell-set!
  (syntax-rules ()
    ((_ cell val) (vector-set! cell 0 val))))

(define-syntax sa-epoch-define
  (syntax-rules ()
    ((_ _cell var init) (define var init))))

(define-syntax sa-epoch-ref
  (syntax-rules ()
    ((_ _cell var) var)))

(define-syntax sa-epoch-bump!
  (syntax-rules ()
    ((_ _cell var) (set! var (fx+ var 1)))))

(define-syntax sa-pub-define
  (syntax-rules ()
    ((_ _cell var init) (define var init))))

(define-syntax sa-pub-ref
  (syntax-rules ()
    ((_ _cell var) var)))

(define-syntax sa-pub-set!
  (syntax-rules ()
    ((_ _cell var val) (set! var val))))

(define-syntax sa-mm-table-make
  (syntax-rules ()
    ((_ h e) (make-hashtable h e))))

(define-syntax sa-mm-table-ref
  (syntax-rules ()
    ((_ tbl k d) (hashtable-ref tbl k d))))

(define-syntax sa-mm-table-keys
  (syntax-rules ()
    ((_ mu tbl) (jolt-with-mutex mu (hashtable-keys tbl)))))

(define-syntax sa-mm-table-entries
  (syntax-rules ()
    ((_ mu tbl) (jolt-with-mutex mu (hashtable-entries tbl)))))

(define-syntax sa-mm-table-put!
  (syntax-rules ()
    ((_ mu tbl k v after ...)
     (jolt-with-mutex mu
       (hashtable-set! tbl k v)
       after ...))))

(define-syntax sa-mm-table-del!
  (syntax-rules ()
    ((_ mu tbl k after ...)
     (jolt-with-mutex mu
       (hashtable-delete! tbl k)
       after ...))))

(define-syntax sa-mm-table-clear!
  (syntax-rules ()
    ((_ mu tbl after ...)
     (jolt-with-mutex mu
       (hashtable-clear! tbl)
       after ...))))

(define-syntax sa-mm-prefer-put!
  (syntax-rules ()
    ((_ mu prefers a b h e after ...)
     (jolt-with-mutex mu
       (let ((sub (or (hashtable-ref prefers a #f)
                      (let ((tbl (make-hashtable h e)))
                        (hashtable-set! prefers a tbl)
                        tbl))))
         (hashtable-set! sub b #t))
       after ...))))

(define-syntax sa-mm-prefers-entries
  (syntax-rules ()
    ((_ mu prefers)
     (jolt-with-mutex mu
       (let-values (((ks vs) (hashtable-entries prefers)))
         (cons ks (vector-map (lambda (sub) (hashtable-keys sub)) vs)))))))

(define-syntax sa-mm-cache-make
  (syntax-rules ()
    ((_ h e) (make-hashtable h e))))

(define-syntax sa-mm-cache-ref
  (syntax-rules ()
    ((_ cache k d) (hashtable-ref cache k d))))

(define-syntax sa-mm-cache-validate!
  (syntax-rules ()
    ((_ mu mf cur-ep cur-hier get-cache get-ep set-ep! get-hier set-hier!)
     (unless (and (fx= (get-ep mf) cur-ep)
                  (eq? (get-hier mf) cur-hier))
       (jolt-with-mutex mu
         (unless (and (fx= (get-ep mf) cur-ep)
                      (eq? (get-hier mf) cur-hier))
           (hashtable-clear! (get-cache mf))
           (set-ep! mf cur-ep)
           (set-hier! mf cur-hier)))))))

(define-syntax sa-mm-cache-put!
  (syntax-rules ()
    ((_ mu mf cache cur-ep-expr target-ep target-hier dv m get-ep get-hier)
     (jolt-with-mutex mu
       (when (and (fx= target-ep cur-ep-expr)
                  (fx= (get-ep mf) target-ep)
                  (eq? (get-hier mf) target-hier))
         (hashtable-set! cache dv m))))))

