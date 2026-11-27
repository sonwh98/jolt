# Phase 2a AUDIT — Guile 3.0.11 semantics for the jolt host adapter

- Auditor: glm-5.3 (VM & Host Adapter Engineer), Phase 2a slice, branch
  `guile/audit`.
- Date: 2026-11-27 (+07). Revision r2 (same lane): witnesses repaired
  against the executed runtime and re-run; every verdict below cites a
  recorded `results/*.out` line. The r1 document was doc-derived only —
  the r1 staging session's permission mode denied execution, the
  orchestrator's first run found the witnesses broken (only w5 and w12
  passed), and r2 fixed them for real. Where execution contradicted the
  r1 doc-tier expectations, THIS document sides with the witness and
  says so.
- Ruling followed: DOC-FIRST (the p1a method, `origin/gambit-ffi-p1:p1a/AUDIT.md`)
  — manual first, execution decides. All 13 witnesses now end in their
  `Wn-VERDICT: PASS` marker under the external watchdog; every witness
  retains its negative controls.
- Scope: audit + witnesses ONLY. No adapter code was written.
- Provisioned target: `/opt/homebrew/opt/guile/bin/guile`, GNU Guile 3.0.11,
  darwin-arm64 (Darwin 25.6.0, T6000, aarch64-apple-darwin25.4.0).
  Linux-x86_64: **NOT RUN** (area 10 records what a Linux run must check).

## Sources cited

- `[man §x.y.z "Node"]` = the Guile Reference Manual documenting exactly
  3.0.11 (gnu.org/software/guile/manual/html_node/, title page: "This
  manual documents Guile version 3.0.11").
- `[wN]` = the recorded witness output
  `host/guile/witnesses/results/wN-*.out` (r2 run, 13/13 PASS;
  `RUN-ALL: PASS` line at the end of the run).
- `CONTRACT.txt` / `TARGET-CONTRACT.md` / `THREADS.md` — the pinned
  semantics under audit.
- `p1a/AUDIT.md` (`origin/gambit-ffi-p1`) — method precedent; the Gambit
  comparison points (its provisioned build: single OS thread, NO-GO on
  blocking-vs-GC and foreign-thread entry).

## Run state

13/13 witnesses PASS under the external watchdog
(`witnesses/results/*.out`, verbatim, `### exit=0` each; `RUN-ALL: PASS`).
One recorded refusal exists by design and is evidence, not a failure: the
w7 bad-mode raw foreign-thread entry crashes (SIGSEGV, exit-status 11
[w7]) while the documented `scm_with_guile` entry is clean — that pair IS
the foreign-thread row.

## Capability matrix

| # | capability | verdict | decisive evidence |
|---|---|---|---|
| 1 | Reader/emit parity | **GO** | [w1] all rows + 3 controls |
| 2 | Threads (`threads` tier) | **GO** | [w2] T1–T7 + N1–N3 |
| 3 | One-shot escape continuations | **GO** | [w3] E/P batteries + NC1–NC3 |
| 4 | FFI (errno, blocking, foreign threads, dlopen, callbacks) | **GO** | [w4] [w5] [w7] |
| 5 | GC + pinning | **GO** | [w6] P1–P4 + controls |
| 6 | I/O (realpath, O_EXCL, locks, sync, mtime, subprocess, sockets) | **GO** (fcntl locks need a compiled shim on darwin) | [w8] [w9] |
| 7 | Native compile / AOT cache | **PARTIAL** (VM bytecode + JIT; boot-file raises) | [w10] C1–C6 + NC |
| 8 | Cryptography | **PARTIAL** (FFI libcrypto + getentropy; BLAKE3 vendored) | [w11] K1–K5 |
| 9 | Performance | **GO (measured)** | [w12] PERF-SUMMARY |
| 10 | Platform parity darwin/linux | **PARTIAL** (darwin-arm64 executed; Linux NOT RUN) | [w0] + per-witness uname-derived branches |

Headline: **no NO-GO row on darwin-arm64** — the two Gambit p1a killers
(blocking-vs-GC, foreign-pthread entry) are both recorded PASSes here.

---

## Area 1 — Reader and emit parity

**Verdict GO.** `[w1]` (results/w1-reader.out), all rows + controls PASS.

The 3.0.11 default option set (recorded live: `read-options-default:
(square-brackets keywords #f positions)` [w1]) matches `[man §6.16.2]`.

- **Case: the r1 brief's premise was inverted, now executed-proof.**
  Default reader is case-SENSITIVE — `'Abc` distinct from `'abc` [w1
  R1a]; `#!no-fold-case` directive works [w1 R1b]; the N1 control shows
  the witness detects folding when `case-insensitive` is switched on.
  `[man §6.16.1.4]` said exactly this. **No boot action for case.**
- **Square brackets** read as parens by default [w1 R2/R2b].
- **Datum `#;` and nested block `#| |#` comments** [w1 R3a–R3c].
- **String escapes — the one real boot action.** Default reader
  mis-decodes R6RS `"\x41;B"` as `"A;B"` [w1 R4]; with
  `(read-enable 'r6rs-hex-escapes)` it decodes as `"AB"` [w1 R4]. Boot
  MUST enable `r6rs-hex-escapes` before reading Chez-emitted strings.
- **`|...|` symbols — second boot action.** Default: bars are ordinary
  symbol characters; `"|hello world|"` reads as the symbol `|hello`
  split at the space [w1 R5]. With `(read-enable 'r7rs-symbols)` it
  reads as ONE symbol (printed `#{hello world}#`, `eq?` to
  `(string->symbol "hello world")`) [w1 R5]. Boot enables
  `r7rs-symbols`.
- **Numbers**: rationals, `#e`, exponents, `#x`, `±inf.0/nan.0` all read
  [w1 R6a–f].
- **Bytevector literals — r1's doc-tier expectation was WRONG.** The
  default reader reads `#vu8(1 2 3 254)` NATIVELY as a bytevector [w1
  R7a: "default => #vu8(1 2 3 254)"]; a malformed `#vu8(a b)` raises
  [w1 N2]; SRFI-207 `#u8"..."` bytestrings stay off [w1 R7c]. **No
  `read-hash-extend!` repair and no emitter change needed.**

## Area 2 — Threads

**Verdict GO.** `[w2]` (results/w2-threads.out), T1–T7 + N1–N3 PASS.

- **Thread-parameter fork-inheritance — native, executed.** A child
  forked under nested `parameterize` sees the creator's CURRENT value
  (`inner`) [w2 T1a]; the creator's current FLUID conveys (`fouter`)
  [w2 T1b]; thread-local fluids do NOT propagate (`tdefault`) [w2 T2];
  a post-fork parent rebinding is invisible to the child [w2 N1:
  "child saw before"]. This is the load-bearing CONTRACT pin, and it
  holds with zero adapter machinery (`[man §6.22.2]`: "new threads
  inherit the fluid bindings that were in place in their creator
  threads").
- **Mutexes — kind must be `allow-external-unlock`.** Standard
  `make-mutex`: owner re-acquire RAISES [w2 T3a] (fail-fast, never
  silent recursion). The contract's pinned SRFI-18 block semantic is met
  by the SRFI-18-tailored kind: owner re-acquire BLOCKS then times out
  (`=> #f` after 1s) [w2 T3b]. **Executed correction to the manual:**
  `[man §6.22.5]`'s `make-mutex` entry says "pass `unowned`" — on this
  build that spelling RAISES "unsupported mutex kind: unowned"; only
  `'allow-external-unlock` is accepted [w2 T3b0: "spelling accepted:
  allow-external-unlock"]. Recursive mutexes count [w2 T3c].
- **Conditions — no lost wakeups.** A 200-round signal baton (state
  changes under the mutex, both sides predicate-loop) completes [w2 T4a];
  broadcast wakes all 4 parked waiters [w2 T4b]; an un-signaled wait
  times out [w2 N2] — a lost wakeup would hang and the watchdog would
  record it. (r2 note: the r1 baton design itself deadlocked — a signal
  delivered before the waiter parks is lost; the contract's own rule
  "every wait site re-checks its predicate" is exactly the fix.)
- **Numeric thread ids — mapping works.** Ids recorded from OUTSIDE the
  thread while live, children agree on the same numbers (`(1 2 3 4 5)`
  both directions) [w2 T5a], distinct [w2 N3], and exited threads answer
  `#f` through the `(thread-exited?)` gate [w2 T5b].
- **Fences.** Mapped onto `(ice-9 atomic)` accesses (SC ⊇ acq+rel,
  `[man §6.22.4]`); 1000 cross-thread monotonic increments with zero
  loss [w2 T6]. Not a no-op: Guile threads are real pthreads.
- **`sleep`/`current-time` shapes.** Core `(sleep 1)` sleeps [w2 T7a];
  SRFI-19 `current-time` zero-arg answers `time-utc` [w2 T7b]; SRFI-18
  `current-time`/`thread-sleep!` take TIME OBJECTS — the contract's
  R6RS sleep shape [w2 T7c].
- **SRFI-18 EXISTS** — the r1 brief and the `guile.ss` stub header both
  said gone; executed: `(srfi srfi-18)` resolves with the full
  thread/mutex/condvar/time surface (`condition-variable-signal!` /
  `-broadcast!` with bangs) [w0].

## Area 3 — Continuations

**Verdict GO (wrapper mandatory).** `[w3]` (results/w3-escape.out), all
rows + NC1–NC3 PASS.

- The wrapper prototype (call/cc + spent flag + owner-thread check):
  normal return [w3 E1], escape value delivery [w3 E2], **one-shot
  enforced in-flight** — a second use from inside the escape's own
  dynamic-wind unwind RAISES [w3 E3], post-return invocation RAISES
  [w3 E4b], cross-thread invocation RAISES [w3 E6]. `finally` bodies
  run on the way out, inner first [w3 E5/E5b].
- The prompt-based prototype (cheaper; `[man §6.11.5]` recommends
  prompts for escapes) passes the same battery [w3 P1–P4, P3c].
- Negative controls: the RAW `call/cc` re-enters a finished frame (two
  passes logged `(one two)`) [w3 NC1]; a wrapper WITHOUT the spent flag
  re-enters too [w3 NC2]; the real wrapper RAISES where both re-enter
  [w3 NC3] — the spent flag is load-bearing, exactly as `guile.ss`
  anticipated.
- **Fibers tier: feasible, deferred.** The scheduler hook is proven in
  w9 S4 (suspendable ports + read waiter). The upstream fibers package
  is not bundled; the port either vendors a prompts-based scheduler or
  keeps `go` on OS threads (THREADS.md's documented degradation).

## Area 4 — FFI

**Verdict GO.** `[w4]` `[w5]` `[w7]` all PASS.

- **errno at the call boundary — native and decisive.**
  `#:return-errno?` captures per-thread errno at the boundary: 1000
  interleaved rounds of two threads running two DIFFERENT failing calls
  (read→EBADF 9 vs access→ENOENT 2) with zero cross-captures [w4 E2];
  the captured pair survives a post-capture clobber [w4 E3b]. **Executed
  finding that reshapes the adapter: the RAW errno slot is not a valid
  access path on this build** — Guile manages errno across foreign
  calls (a set of 77 reads back 0; a plain failing call leaves the slot
  0) [w4 E1]. A late raw read diverges from the captured pair [w4 NC1] —
  so `sa-foreign-procedure-native-error` MUST be the `#:return-errno?`
  two-value form, never a slot read.
- **Blocking calls vs GC — the Gambit p1a W2 killer, PASS here.** While
  thread A sat 3s inside a libc `sleep` entered via the FFI, thread B
  completed 823 real collection rounds (heap-size samples varied, live
  vector mutations intact) [w5]. Blocking collapses to plain, exactly as
  `[man §6.22.6]` documents ("blocked threads no longer hinder garbage
  collection", since 2.0).
- **Foreign pthread entry — the Gambit p1a W3 killer, PASS here.** A
  compiled fixture enters Scheme from two concurrent foreign pthreads
  through `scm_with_guile`; each evaluates a Scheme lambda on its own
  argument (41 and 42) [w7 F1–F3]. The raw unattached entry probe
  crashes (exit-status 11, SIGSEGV) [w7] — the documented protocol is
  the only entry. `sa-foreign-callable-entry-point` must route through
  a `scm_with_guile` trampoline.
- **Callback lifetime — internally rooted (executed).** qsort through
  `procedure->pointer` with the reference dropped and 3 forced GCs still
  sorts correctly [w4 CL2: "arr=(2 4 6 8)"] — Guile roots the
  trampoline; the adapter does NOT need its own registry (a defensive
  one is harmless).
- **dlopen/dlsym.** Missing symbol RAISES [w4 D1]; missing library
  RAISES [w4 D2]; the `#f` handle resolves libc symbols from the running
  executable's namespace [w4 D3]. Search order and darwin extension
  order per `[man §6.19.1]`.
- **ADAPTER DISCIPLINE (recorded in w8):** foreign-call buffer arguments
  must stay ROOTED — an anonymous `(bytevector->pointer (make-struct ...))`
  can be collected before the call and the syscall then fails EFAULT.

## Area 5 — GC and pinning

**Verdict GO.** `[w6]` (results/w6-gc-pinning.out) PASS.

- **Non-moving, executed.** A bytevector pointer held across 10 real
  collections stays address-stable, aliased writes persist [w6 P1];
  controls prove the collections were real (heap samples vary) [w6 NC1]
  and the alias tracks the object [w6 NC2]. malloc'd foreign memory
  likewise stable [w6 P2]. `sa-lock-object`/`sa-unlock-object` may BOTH
  be no-ops (BDW-GC, `[man §9.2.4]`).
- **Memory accounting, exact key set recorded** [w6 P3]:
  `gc-time-taken gc-times heap-allocated-since-gc heap-free-size
  heap-size heap-total-allocated protected-objects`. Mapping:
  `sa-bytes-allocated` ← `heap-allocated-since-gc` (delta) or
  `heap-total-allocated`; `sa-total-memory-bytes` ← `heap-size`
  (approximation permitted); `sa-gc-max-generation` ← fixed sentinel (no
  generation counters exist [w6 P3c]); heap ceiling from FFI
  `getrlimit(RLIMIT_AS)` — rlim_cur records RLIM_INFINITY here [w6 P3d].
- **`after-gc-hook` fires on `(gc)`** [w6 P4] — `sa-gc-install-
  after-collect!` can be real on this target, not the #f degradation.

## Area 6 — I/O

**Verdict GO (fcntl locks via a compiled shim on darwin).** `[w8]`
`[w9]` PASS.

- **realpath**: `canonicalize-path` resolves a two-link symlink chain
  (and `/tmp`→`/private/tmp` itself) [w8 IO1]; a missing component
  RAISES [w8 NC2] — matches `[man §7.2.3]`.
- **Exclusive create**: first `O_CREAT|O_EXCL` succeeds, second RAISES
  EEXIST [w8 IO2a/NC1].
- **Advisory locking — with an executed platform finding.** Direct FFI
  calls to VARIADIC `fcntl(2)` fail EFAULT(14) on darwin-arm64 even with
  a rooted struct [w8 IO3a1] — the fixed-arity libffi convention does
  not match the variadic ABI. The repair (the adapter's row decision):
  a compiled NON-variadic shim (`w8_setlk`), which acquires the
  whole-file write lock [w8 IO3a `=> 0`], EXCLUDES a child process
  (exit 42 = EAGAIN) [w8 IO3b], and releases causally (child then
  acquires, exit 0) [w8 NC3]. Also recorded: a write lock on an
  O_RDONLY fd is refused (open RDWR on both sides).
- **Directory sync**: `fsync` on an O_RDONLY directory fd succeeds [w8
  IO4] (core `fsync` returns unspecified — reachability is the row).
- **`sa-file-mtime-ms` — second-resolution floor, FFI repair proven.**
  Executed finding: `stat:mtimensec` answers 0 for EVERY file on this
  darwin build (and `utime`'s ns args do not apply) [w8 IO5a]; an FFI
  `stat(2)` reading `st_mtimespec` (offset 48/56 on darwin arm64)
  reaches sub-second mtime (`...978` ms vs `...000`) [w8 IO5b]. The
  adapter implements mtime-ms over the FFI stat on darwin.
- **Subprocess**: `spawn` + pipe + `waitpid`, output captured, exit 0
  [w8 IO6]; `opendir/readdir/closedir` [w8 IO7]. `[man §7.2.7]`.
- **Sockets / poller / suspendable ports — DHT and WebSocket parity
  feasible.** UDP loopback round-trip [w9 S1]; `O_NONBLOCK` via core
  `fcntl` + boundary-captured EAGAIN (35 on darwin) [w9 S2]; `select(0)`
  readiness causality with a strict not-ready control [w9 S3/NC1]; and
  the load-bearing piece — `(ice-9 suspendable-ports)`
  `install-suspendable-ports!` + `current-read-waiter`: a read that
  would block parks through the waiter parameter (fired 6×) and
  completes when a late datagram lands [w9 S4/NC2]. This is the exact
  hook a fibers-style event loop rides (`[man §6.12.13]`).
- Executed correction: there is NO `(ice-9 sockets)` module in stock
  3.0.11 — `socket/bind/sendto/recvfrom!` are core exports and
  `getsockname` answers a VECTOR `#(family addr port)`; `recvfrom!`
  returns `(n . sockaddr)` [w9].

## Area 7 — Native compile

**Verdict PARTIAL.** `[w10]` (results/w10-compile.out) PASS.

- `compile-file` produces a nonempty `.go` [w10 C1]; optimization levels
  0 and 2 accepted — the target-neutral profile maps [w10 C4];
  `load-compiled` evaluates the compiled module [w10 C2]; the ccache
  path maps under `$XDG_CACHE_HOME/guile/ccache/3.0-LE-8-4.7/...` and is
  written only by a compile [w10 C3/NC2b]; a broken source RAISES [w10
  NC1]. `[man §6.16.6]`.
- **Executed adapter fact:** loading a file whose first form is
  `define-module` SWITCHES the current module for the rest of the
  loading script — save/restore around `load-compiled` [w10 C2].
- The auto-compile knob is `%load-should-auto-compile` (NO question
  mark — r1 had the wrong name); it reflects `--no-auto-compile` (it
  reads `#f` under the witnesses' runner) and is settable [w10 C6].
- PARTIAL because: `.go` is Guile VM bytecode, not an AOT machine-code
  object (the JIT makes hot code native at run time — the 75.9× compiled
  speedup in w12 is the executed proof the cache serves its purpose);
  and `sa-make-boot-file` MUST raise — `(system base compile)` exports
  no boot-file API [w10 C5: "make-boot-file bound: #f"], the
  contract-permitted degradation.

## Area 8 — Cryptography

**Verdict PARTIAL.** `[w11]` (results/w11-crypto.out) PASS.

- No digest/sign primitives in core (and guile-gcrypt is an external
  package, absent) [w11 K1/K1b] — `[man §7.2.14]` bundles only
  crypt/getpass.
- **libcrypto via FFI works**: `load-foreign-library "libcrypto"`
  resolves (OpenSSL 3.6.3 on this host), `EVP_Digest` SHA-256 passes the
  FIPS "abc" known-answer test
  (`ba7816bf...15ad`) [w11 K2b]; different input → different digest
  [w11 NC1]. Note the OpenSSL convention: `EVP_Digest` returns 1 on
  success (r1's zero-test was wrong).
- **Ed25519**: `EVP_PKEY_new_raw_private_key` present in the loaded
  libcrypto [w11 K4] — the EVP raw-key path (sn "ED25519") is
  reachable; full sign/verify KATs are Phase 2b adapter work.
- **Randomness**: `getentropy(2)` via the global namespace fills 32/32
  nonzero bytes [w11 K3].
- **BLAKE3**: no system library on stock darwin [w11 K5] and not in
  OpenSSL — the row decision is VENDORED C (the reference
  single-file implementation as a loadable extension) or the jolt-level
  degradation. This is the crypto tier's one open engineering item.

## Area 9 — Performance

**GO (measured).** `[w12]` (results/w12-perf.out), PERF-SUMMARY line:

- child-process boot (`guile --no-auto-compile -c 0`), median of 3:
  **193.4 ms**
- interpreter `eval` of `(+ 1 2)`: **3.71 µs/eval** (20000 evals)
- 1M-iteration tail loop (plain closure): **111.9 ms** (~9M simple
  calls/s)
- 1M-iteration closure: interpreted-eval'd **116.6 ms** vs `compile`d
  **1.537 ms** — **75.9× speedup** (the JIT/VM-compile path the AOT
  cache buys)

Context: suspendable-ports I/O costs "a factor of 3 or 4" vs C port ops
(`[man §6.12.13]`) — relevant to the fibers-tier choice; boot ~194 ms
is heavy for short-lived CLI processes (the Chez comparison number is a
Phase 2b measurement on the same corpus, not part of 2a).

## Area 10 — Platform (darwin-arm64 vs linux-x86_64)

**PARTIAL — darwin-arm64 executed, Linux NOT RUN.**

- Identity derives from live probes per TARGET-CONTRACT.md: `(uname)` →
  `Darwin`/`arm64` [w0], `(native-endianness)` → `little` [w0];
  `sa-host-tag` candidate `guile-3.0.11-aarch64-apple-darwin25.4.0` [w0].
- Platform constants are derived at runtime inside the witnesses from
  `uname`, and a Linux run must confirm each: `EAGAIN` (35 darwin /
  11 linux — recorded 35 [w9 S2b]); `__error` vs `__errno_location`
  (both probed, `__error` wins on darwin [w4]); `struct flock` layout +
  `F_SETLK` (8/3 darwin [w8]); FFI `stat` `st_mtimespec` offsets (48/56
  darwin arm64 [w8 IO5b]); `RLIMIT_AS` (5 darwin / 9 linux [w6 P3d]);
  foreign-library extension order (`.bundle/.so/.dylib` darwin).
- Executed darwin facts a Linux run will differ on: variadic-FFI EFAULT
  (linux libffi may or may not pass variads — the w8 shim is the
  portable answer either way); `stat:mtimensec` dead at 0 (Linux Guile
  populates it — the adapter prefers core stat there and falls back to
  the FFI probe).
- `getaffinity/setaffinity` are GNU-only (`[man §7.2.7]`) — not contract
  rows; recorded as surface.

---

## Surprises (r2, executed)

1. **`#vu8(...)` reads NATIVELY** — r1's doc-derived claim that the
   default reader fails on it (needing `read-hash-extend!`) was wrong
   [w1 R7a]. Boot actions for the reader are exactly two:
   `r6rs-hex-escapes` and `r7rs-symbols` [w1 R4/R5].
2. **The manual's `make-mutex` entry is wrong for this build**: the
   `unowned` kind spelling RAISES "unsupported mutex kind"; only
   `'allow-external-unlock` works [w2 T3b0].
3. **The raw errno slot is unusable** — Guile manages errno across
   foreign calls; boundary capture (`#:return-errno?`) is not just
   preferable, it is the ONLY sound mechanism [w4 E1/NC1].
4. **Callbacks are internally rooted** — dropped-reference qsort
   trampolines survive GC and run correctly [w4 CL2]; no adapter
   registry required.
5. **Variadic libc functions EFAULT through the FFI** on darwin-arm64
   (fcntl) — the compiled-shim technique is now a recorded adapter
   requirement for record locks (and any other variad) [w8 IO3].
6. **`stat:mtimensec` is dead on this darwin build** (always 0) and
   `utime` ns args do not apply — ms-resolution mtime needs the FFI
   stat [w8 IO5].
7. **Both Gambit p1a NO-GO rows are recorded PASSes** — GC completes
   during a blocked C call (823 rounds [w5]) and foreign pthreads enter
   cleanly through `scm_with_guile` (41/42 [w7]) while raw entry
   segfaults (exit 11 [w7]).
8. **`(srfi srfi-18)` exists** in 3.0.11 with the full surface (the r1
   brief and the guile.ss header note are stale) [w0]; there is NO
   `(ice-9 sockets)` module — the socket API is core [w9].
9. **Process reality**: loading a `define-module` file switches the
   current module for the rest of the script [w10 C2]; core `fsync`
   returns unspecified [w8 IO4]; `%load-should-auto-compile` (no `?`)
   is the auto-compile knob [w10 C6].

## Adapter to-do extracted (Phase 2b)

1. Boot: `(read-enable 'r6rs-hex-escapes)` + `(read-enable
   'r7rs-symbols)`; `#!no-fold-case` guard in emitted prologues; nothing
   for `#vu8`.
2. `fork-thread` over `call-with-new-thread`; `make-thread-parameter`
   over `make-parameter`; numeric id registry + `(thread-exited?)` gate;
   mutexes from `(make-mutex 'allow-external-unlock)`; fences via
   `(ice-9 atomic)` ops.
3. `sa-call-with-escape-continuation` on prompts (or call/cc) + spent
   flag + owner-thread raise; unwind via dynamic-wind.
4. FFI: `#:return-errno?` for native-error (never slot reads); blocking
   collapses to plain; `sa-foreign-callable-entry-point` returns a
   `scm_with_guile` trampoline; root FFI buffer args across calls; a
   variadic-shim C file for fcntl-style locks.
5. GC: lock/unlock no-ops; `(gc)`; stats mapping per w6's recorded key
   set; real `after-gc-hook` install.
6. I/O per w8/w9: FFI stat for ms mtime on darwin; canonicalize-path;
   O_EXCL; shim-based locks; spawn/waitpid; suspendable-ports event loop
   for DHT/WebSocket.
7. Compile tier per w10; crypto per w11 (libcrypto EVP + getentropy +
   vendored BLAKE3 decision).
