# Phase 2a AUDIT — Guile 3.0.11 semantics for the jolt host adapter

- Auditor: glm-5.3 (VM & Host Adapter Engineer), Phase 2a slice, branch
  `guile/audit`.
- Date: 2026-11-28 (+07). Revision r6 (same lane): closed the final 2 P2
  items from `codex` (`gpt-6.2-sol`) r5 consensus on `f3bace2b` and
  re-ran all 13 witnesses under the external watchdog (`RUN-ALL: PASS`):
  took `w5`'s `gc-stats` snapshot strictly between the two active-flag
  reads (before and after `(gc)`/`(gc-stats)`), and marked standalone
  `memory-order-acquire`/`memory-order-release` fence compliance
  unverified (requiring a Phase 2b implementation that establishes
  ordering in the host's publication pattern).
- Ruling followed: DOC-FIRST (the p1a method, `origin/gambit-ffi-p1:p1a/AUDIT.md`)
  — manual first, execution decides. All 13 witnesses end in their
  `Wn-VERDICT: PASS` marker under the external watchdog; every witness
  retains negative/sanity controls.
- Scope: audit + witnesses ONLY. No adapter code was written.
- Provisioned target: `/opt/homebrew/opt/guile/bin/guile`, GNU Guile 3.0.11,
  darwin-arm64 (Darwin 25.6.0, T6000, aarch64-apple-darwin25.4.0).
  Linux-x86_64: **NOT RUN** (area 10 records what a Linux run must check).

## Sources cited

- `[man §x.y.z "Node"]` = the Guile Reference Manual documenting exactly
  3.0.11 (gnu.org/software/guile/manual/html_node/, title page: "This
  manual documents Guile version 3.0.11").
- `[wN]` = the recorded witness output
  `host/guile/witnesses/results/wN-*.out` (r3 run, 13/13 PASS;
  `RUN-ALL: PASS` line at the end of the run).
- `CONTRACT.txt` / `TARGET-CONTRACT.md` / `THREADS.md` — the pinned
  semantics under audit.
- `p1a/AUDIT.md` (`origin/gambit-ffi-p1`) — method precedent; the Gambit
  comparison points (its provisioned build: single OS thread, NO-GO on
  blocking-vs-GC and foreign-thread entry).

## Run state

13/13 witnesses PASS under the external watchdog
(`witnesses/results/*.out`, verbatim, `### exit=0` each; `RUN-ALL: PASS`).
Recorded refusals that serve as decisive evidence (not failures):
- `[w4 CL2b]`: retaining ONLY the raw `pointer-address` and dropping the
  `<pointer>` object from `procedure->pointer` crashes with `SIGSEGV`
  (`term-sig=11`) after GC in the same process, proving a callable
  registry is mandatory.
- `[w7]`: raw unattached foreign-thread entry crashes (`SIGSEGV`,
  `term-sig=11`) while documented `scm_with_guile` entry succeeds; and
  invoking a plain `procedure->pointer` trampoline directly on an
  unattached foreign pthread also crashes (`SIGSEGV`, `term-sig=11`,
  `[w7 CB1]`), proving `sa-foreign-callable-collect-safe` needs a C
  `libffi` + `scm_with_guile` closure helper.

## Capability matrix

| # | capability | verdict | decisive evidence |
|---|---|---|---|
| 1 | Reader/emit parity | **GO** | [w1] all rows + 3 controls |
| 2 | Threads (`threads` tier) | **GO** (standalone `memory-order-acquire`/`memory-order-release` fence compliance **unverified** — Phase 2b required) | [w2] T1–T7 + N1a/N1b/N2/N3 |
| 3 | One-shot escape continuations | **GO** | [w3] E1–E8, P1–P7 + NC1–NC3 |
| 4 | FFI (errno, blocking, foreign threads, dlopen, callbacks) | **GO** (`sa-foreign-callable-collect-safe` on foreign pthreads needs C libffi+`scm_with_guile` helper; callable registry required) | [w4] [w5] [w7] |
| 5 | GC + pinning | **GO** | [w6] P1–P4 + P3e + controls |
| 6 | I/O (realpath, O_EXCL, locks, sync, mtime, subprocess, sockets) | **GO** (fcntl locks need a compiled shim on darwin) | [w8] [w9] |
| 7 | Native compile / AOT cache | **PARTIAL** (`sa-compile-file` & `sa-make-boot-file` degraded under `CONTRACT.txt:312-319`; `.go` bytecode cache + JIT are Guile capabilities) | [w10] C1–C6 + NC |
| 8 | Cryptography | **PARTIAL** (FFI libcrypto + getentropy; BLAKE3 vendored) | [w11] K1–K5 |
| 9 | Performance | **GO (measured)** | [w12] PERF-SUMMARY + NC1 |
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

**Verdict GO.** `[w2]` (results/w2-threads.out), T1–T7 + N1a/N1b/N2/N3 PASS.

- **Thread-parameter fork-inheritance — native, executed.** A child
  forked under nested `parameterize` sees the creator's CURRENT value
  (`inner`) [w2 T1a]; the creator's current FLUID conveys (`fouter`)
  [w2 T1b]; thread-local fluids do NOT propagate (`tdefault`) [w2 T2];
  under atomic-flag synchronization guaranteeing the parent rebinds
  before the child reads, the post-fork parent rebinding is invisible to
  the child [w2 N1a: `"child saw before"`]; and a child mutating
  `(*param* #f)` (the `*txn*` clear pattern in `CONTRACT.txt:48-50`)
  leaves the parent's binding untouched [w2 N1b: `"parent-val"`]. This
  is the load-bearing CONTRACT pin, and it holds with zero adapter
  machinery (`[man §6.22.2]`: "new threads inherit the fluid bindings
  that were in place in their creator threads").
- **Mutexes — kind must be `allow-external-unlock`.** Standard
  `make-mutex`: owner re-acquire RAISES [w2 T3a] (fail-fast, never
  silent recursion). The contract's pinned SRFI-18 block semantic is met
  by the SRFI-18-tailored kind: owner re-acquire BLOCKS then times out
  (`=> #f` after 1s) [w2 T3b]. **Executed correction to the manual:**
  `[man §6.22.5]`'s `make-mutex` entry says "pass `unowned`" — on this
  build that spelling explicitly RAISES (`unowned rejected=#t`); only
  `'allow-external-unlock` is accepted [w2 T3b0]. Recursive mutexes count
  [w2 T3c].
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
- **Fences — standalone fence compliance UNVERIFIED (Phase 2b required).**
  `CONTRACT.txt:113-118` requires standalone zero-arg fences
  `(memory-order-release)` / `(memory-order-acquire)` around ordinary
  record/vector publication (`seq.ss`). Guile `(ice-9 atomic)` exposes
  C11 sequential consistency on atomic boxes (`[man §6.22.4]`), not an
  explicit standalone `atomic_thread_fence` primitive; `[w2 T6a]` is
  only a smoke test of the `%fence-word` pattern (`pub=1000 ack=1000
  mismatches=0`) and does **not** prove standalone acquire/release fence
  ordering, while `[w2 T6b]` checks direct `atomic-box` message passing
  (`seq=1000 ack=1000 mismatches=0`). Not a no-op: Guile threads are
  real pthreads, so Phase 2b **must** provide a standalone fence
  implementation that establishes acquire/release ordering in the host's
  publication pattern.
- **`sleep`/`current-time` shapes.** Core `(sleep 1)` sleeps [w2 T7a];
  SRFI-19 `current-time` zero-arg answers `time-utc` [w2 T7b]; SRFI-18
  `current-time`/`thread-sleep!` take TIME OBJECTS — the contract's
  R6RS sleep shape [w2 T7c].
- **SRFI-18 EXISTS** — the r1 brief and the `guile.ss` stub header both
  said gone; executed: `(srfi srfi-18)` resolves with the full
  thread/mutex/condvar/time surface (`condition-variable-signal!` /
  `-broadcast!` with bangs) [w0].

## Area 3 — Continuations

**Verdict GO (`call-with-prompt` wrapper mandatory; `call/cc` dropped for
Phase 2b).** `[w3]` (results/w3-escape.out), all rows + NC1–NC3 PASS.

- **Contract boundary (r3 correction):** per `TARGET-CONTRACT.md:49-50`
  and `CONTRACT.txt:291-293`, ownership (which thread/fiber may invoke an
  escape) is the **HOST** layer's rule (`continuations.ss`), NOT the
  target adapter's; the adapter owes only the one-shot/extent `spent`
  flag. Keeping the parent capture **live** while a child thread invokes
  it proves Guile's platform itself refuses cross-thread invocation: a
  live raw `call/cc` continuation hits Guile's continuation barrier
  (`"invoking continuation would cross continuation barrier"`) [w3 E6a],
  and a live `call-with-prompt` escape raises `"Abort to unknown prompt"`
  across threads [w3 E6b].
- **Phase 2b commitment (`call-with-prompt` + fresh tag + `dynamic-wind`
  every-exit invalidation, r4 P1):** setting `spent` only on the
  escape and ordinary return leaves `k` re-entrant if the wrapper unwinds
  via an unrelated thrown exception or outer escape (and `call/cc` is
  dropped as a Phase 2b option). Wrapping `(proc ...)` in a
  `dynamic-wind` out-guard `(lambda () (set! spent #t))` inside
  `call-with-prompt` with a **fresh `(make-prompt-tag "escape")` per
  call** invalidates `k` on **every** exit: normal return [w3 E1/P1],
  escape delivery [w3 E2/P2/P3a], in-flight second use during
  `dynamic-wind` unwind [w3 E3/P7], post-return raising via
  `escape-continuation` (`spent` flag) [w3 E4b/P3c], `dynamic-wind`
  unwind inner-first [w3 E5/E5b/P4/P4b], nested outer-escape delivery
  (`=> escaped`) [w3 P5], leaked `k` raising inside a later active prompt
  (`(raised misc-error escape-continuation)`) [w3 P6], thrown exception
  exit invalidating `k` both standalone and inside an enclosing escape
  frame (`standalone=escape-continuation enclosing=escape-continuation`)
  [w3 E7], and outer escape invalidating inner `k`
  (`post-inner-k=escape-continuation`) [w3 E8].
- Negative controls: the RAW `call/cc` re-enters a finished frame (two
  passes logged `(one two)`) [w3 NC1]; a wrapper WITHOUT the spent flag
  re-enters too [w3 NC2]; the real wrapper RAISES where both re-enter
  [w3 NC3] — the spent flag + exit guard are load-bearing.
- **Fibers tier: feasible, deferred.** The scheduler hook is proven in
  w9 S4 (suspendable ports + read waiter). The upstream fibers package
  is not bundled; the port either vendors a prompts-based scheduler or
  keeps `go` on OS threads (THREADS.md's documented degradation).

## Area 4 — FFI

**Verdict GO (callable registry required; foreign-thread
`sa-foreign-callable-collect-safe` requires a compiled C helper).**
`[w4]` `[w5]` `[w7]` all PASS.

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
- **Blocking calls vs GC — the Gambit p1a W2 killer, PASS here.** Thread
  A parks inside a compiled C shim (`w5_blocking_sleep(3)`), which sets
  a C-side atomic flag `w5_in_c=1` strictly across `sleep(3)` and clears
  it before returning, asserting both C return `rem=0` and real wall
  clock `elapsed-ms=3002.1` (`>= 2500 ms`). Thread B takes the
  `(gc-stats)` snapshot strictly between two `w5_is_in_c()` reads
  (bracketing `(gc)` and `(gc-stats)`), accepting the sample only when
  both are `1`, and the main thread drains the worker before taking the
  final snapshot: `rounds-during-block=1020` and `gc-times-during=204`
  real collections (`gc-times` `72` → `276` strictly inside the C-side
  handshake; live vector mutations intact) [w5]. Post-drain, the negative
  control proves `rounds-during-block` stays unchanged (`1020->1020`)
  while `rounds-total` advances (`1370->1718`) when `w5_in_c=0` [w5 NC].
  Blocking collapses to plain, exactly as `[man §6.22.6]` documents
  ("blocked threads no longer hinder garbage collection", since 2.0).
- **Foreign pthread entry — the Gambit p1a W3 killer, PASS here.** A
  compiled fixture enters Scheme from two concurrent foreign pthreads
  through `scm_with_guile`; each evaluates a Scheme lambda on its own
  argument (41 and 42) [w7 F1–F3]. The raw unattached entry probe
  crashes (`term-sig=11`, `SIGSEGV`) [w7] — `scm_with_guile` is the
  required entry protocol.
- **`sa-foreign-callable` vs `sa-foreign-callable-collect-safe` (r3
  correction).** `sa-foreign-callable-entry-point` merely extracts the C
  function pointer from a callable (`CONTRACT.txt:269`). Guile's
  `procedure->pointer` creates a `libffi` closure whose C entry point
  (`invoke_closure` in `libguile/foreign.c`) does **NOT** call
  `scm_with_guile`: invoking a `procedure->pointer` trampoline directly
  as a foreign pthread start routine crashes with `SIGSEGV`
  (`term-sig=11`) [w7 CB1]. Because `scm_with_guile` only accepts
  `void *(*)(void *)`, pure-Scheme `procedure->pointer` satisfies
  `sa-foreign-callable` (same-thread callbacks already in Guile mode),
  whereas `sa-foreign-callable-collect-safe` invoked from unattached
  foreign pthreads requires a compiled C `libffi` closure helper
  (`ffi_prep_closure_loc`) whose handler enters `scm_with_guile` before
  invoking `scm_call_N` (or must be qualified/degraded until built).
- **Callback lifetime — adapter callable registry REQUIRED (r3
  correction).** In `procedure->pointer`, the `ffi_closure` and Scheme
  procedure are rooted **by the returned `<pointer>` object** [w4 CL2a:
  dropping the Scheme proc ref while keeping `<pointer>` alive across 3
  GCs still sorts `(2 4 6 8)`]. Retaining ONLY the raw C address
  `(pointer-address cptr)` (the shape `sa-foreign-callable-entry-point`
  hands to C) and dropping `<pointer>` collects the closure and
  crashes with `SIGSEGV` (`term-sig=11`) after GC in the same process
  [w4 CL2b-dropped], whereas keeping `<pointer>` rooted and invoking
  `(make-pointer addr)` survives and sorts `(1 2 3 4 5)` [w4
  CL2b-kept]. Therefore, the Phase 2b adapter **MUST** maintain a
  callable registry keeping every `<pointer>` object rooted for as long
  as C holds its `sa-foreign-callable-entry-point` address.
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
  heap-size heap-total-allocated protected-objects`. Mapping (r4
  correction): `sa-total-memory-bytes` ← `heap-size`;
  `sa-bytes-allocated` ← `(- heap-size heap-free-size)` (live occupied
  heap from a single `(gc-stats)` snapshot, so `(- sa-total-memory-bytes
  sa-bytes-allocated)` equals `heap-free-size` and never goes negative,
  unlike cumulative `heap-total-allocated` which already exceeds
  `heap-size`). Validated in [w6 P3e]: base `1605632` → `3829760`
  (`<= heap-size 5242880`) when retaining 2 MiB of bytevectors across
  `(gc)`, dropping back to `1601536` after release + `(gc)`.
  `sa-gc-max-generation` ← fixed sentinel (no generation counters exist
  [w6 P3c]); heap ceiling from FFI `getrlimit(RLIMIT_AS)` — rlim_cur
  records RLIM_INFINITY here [w6 P3d].
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
  calls to VARIADIC `fcntl(2)` on an `O_RDWR` fd fail `rc=-1 errno=14`
  (`EFAULT`) on darwin-arm64 even with a rooted struct [w8 IO3a1] — the
  fixed-arity libffi convention does not match the variadic ABI. The
  repair (the adapter's row decision): a compiled NON-variadic shim
  (`w8_setlk`) that constructs `struct flock` in C using `<fcntl.h>`
  (ABI-safe across 24-byte darwin-arm64 and 32-byte linux-x86_64) and
  captures `errno` via `#:return-errno? #t`. It acquires the whole-file
  write lock [w8 IO3a `rc=0`], EXCLUDES a child process only on
  `EAGAIN`/`EACCES` (exit 42; other errors exit 43) [w8 IO3b], verifies
  parent `F_UNLCK` succeeds (`rc=0`) [w8 IO3c], and releases causally
  (child then acquires, exit 0) [w8 NC3]. Also recorded: a write lock
  on an O_RDONLY fd is refused (open RDWR on both sides).
- **Directory sync**: `fsync` on an O_RDONLY directory fd succeeds [w8
  IO4] (core `fsync` returns unspecified — reachability is the row).
- **`sa-file-mtime-ms` — signed FFI `stat` required on BOTH darwin and
  linux.** Executed finding: `(utime mt-file 1700000000 1700000000 0
  456000000)`'s ns argument DOES apply to the inode (`456000000` ns is
  preserved on disk), whereas Guile's core `stat:mtimensec` answers `0`
  for EVERY file on this darwin build (`1700000000000` ms) [w8 IO5a]; and
  Guile 3.0.11's `filesys.c` converts `st_mtime` via `scm_from_ulong`,
  wrapping pre-epoch timestamps unsigned (`utimensat(-10s, 250ms)` gave
  `core stat:mtime=18446744073709551606`) [w8 IO5c]. An FFI `stat(2)`
  reading signed `time_t` (`bytevector-s64-native-ref`) + `tv_nsec`
  (`st_mtimespec` offsets `48/56` on darwin-arm64, `st_mtim` offsets
  `88/96` on linux-x86_64) recovers the exact sub-second mtime
  (`1700000000456` ms) [w8 IO5b] and handles pre-epoch signed timestamps
  (`-9750` ms) [w8 IO5c]. The adapter therefore uses the signed FFI
  `stat` path on **both** darwin and Linux.
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

**Verdict PARTIAL (`sa-compile-file` & `sa-make-boot-file` degraded
under `CONTRACT.txt:312-319`).** `[w10]` (results/w10-compile.out) PASS.

- **Contract disposition (r4 correction):** `CONTRACT.txt:312-319`
  specifies native-object compilation and requires targets that cannot
  compile to native code to raise from both `sa-compile-file` and
  `sa-make-boot-file` (so `loader.ss` disables the native AOT cache and
  loads from source, and `jolt build` reports a clean error). Because
  Guile emits `.go` **VM bytecode** (not native machine-code objects)
  and `(system base compile)` exports no boot-file API (`make-boot-file
  bound: #f` [w10 C5]), **both `sa-compile-file` and `sa-make-boot-file`
  are recorded as degraded (raising message-carrying errors)** under
  the current contract.
- **Guile bytecode-cache & JIT capabilities (distinct from contract AOT
  objects):** `compile-file` produces a nonempty `.go` [w10 C1];
  optimization levels 0 and 2 are accepted [w10 C4]; `load-compiled`
  evaluates the compiled module [w10 C2]; `compiled-file-name` maps
  under `$XDG_CACHE_HOME/guile/ccache/3.0-LE-8-4.7/...`, verified absent
  before `compile-file` and present afterward [w10 C3/NC2b]; a broken
  source RAISES [w10 NC1]; and Guile's JIT accelerates in-memory
  compiled code by 75.1× (`w12`). `[man §6.16.6]`. If jolt later
  permits a bytecode-tier `sa-compile-file`, save/restore
  `current-module` around `load-compiled` (loading a `define-module`
  file switches it [w10 C2]) and note `%load-should-auto-compile` (no
  `?`, reflects `--no-auto-compile`, settable [w10 C6]).

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

- child-process boot (`guile --no-auto-compile -c 0`, all 3 children
  verified `exit=0` before computing/publishing median), median of 3:
  **156.2 ms**
- interpreter `eval` of `(+ 1 2)`: **3.12 µs/eval** (20000 evals)
- 1M-iteration tail loop (plain closure): **103.7 ms** (~9.6M simple
  calls/s)
- 1M-iteration closure: interpreted-eval'd **92.5 ms** vs in-memory
  `compile`d **1.231 ms** — **75.1× speedup** (Guile JIT capability on
  in-memory compiled code; `w12` does not load `.go` cache artifacts);
  `NC1` confirms 1 iteration takes `0.04 ms` << `92.5 ms`.

Context: suspendable-ports I/O costs "a factor of 3 or 4" vs C port ops
(`[man §6.12.13]`) — relevant to the fibers-tier choice; boot ~156 ms
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
  (both probed, `__error` wins on darwin [w4]); `struct flock` constructed
  in C via `<fcntl.h>` in `w8_setlk` (and 32-byte Linux `struct flock` /
  `AT_FDCWD` `-100` vs darwin `-2` [w8]); FFI `stat` signed `s64`
  `st_mtimespec`/`st_mtim` offsets (48/56 darwin arm64, 88/96 linux
  x86_64 [w8 IO5b/IO5c]); `RLIMIT_AS` (5 darwin / 9 linux [w6 P3d]);
  foreign-library extension order (`.bundle/.so/.dylib` darwin).
- Executed darwin facts a Linux run will differ on: variadic-FFI EFAULT
  (linux libffi may or may not pass variads — the w8 shim is the
  portable answer either way); `stat:mtimensec` dead at 0 on darwin (Linux
  Guile populates `stat:mtimensec`, so `w8 IO5a` branches on `darwin?`,
  while Guile 3.0.11 `filesys.c` uses `scm_from_ulong` for `st_mtime`
  on both platforms — so `sa-file-mtime-ms` should still use the signed
  FFI `stat` `s64` path on Linux too [w8 IO5c]).
- `getaffinity/setaffinity` are GNU-only (`[man §7.2.7]`) — not contract
  rows; recorded as surface.

---

## Surprises (r2–r6, executed)

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
4. **Callbacks require an adapter registry AND foreign-thread helper** —
   `procedure->pointer` roots its closure ONLY via the returned
   `<pointer>` object [w4 CL2a]; keeping only the raw C address
   (`sa-foreign-callable-entry-point`) and dropping `<pointer>` SIGSEGVs
   after GC [w4 CL2b], so the adapter **MUST** maintain a callable
   registry. Furthermore, `procedure->pointer` does not call
   `scm_with_guile`, so invoking it directly on an unattached foreign
   pthread SIGSEGVs [w7 CB1]; `sa-foreign-callable-collect-safe` on
   foreign threads needs a compiled C `libffi` + `scm_with_guile` shim.
5. **Variadic libc functions EFAULT through the FFI** on darwin-arm64
   (fcntl `rc=-1 errno=14` [w8 IO3a1]) — the compiled-shim technique
   (constructing `struct flock` in C via `<fcntl.h>`) is now a recorded
   adapter requirement for record locks (and any other variad) [w8 IO3].
6. **`stat:mtimensec` is dead on darwin and `stat:mtime` wraps unsigned
   on Guile 3.0.11 (`filesys.c` `scm_from_ulong`), while `utime` ns args
   DO apply** — `utime(..., 456000000 ns)` sets the inode's nanoseconds
   (`1700000000456` ms via FFI `stat`), while darwin core
   `stat:mtimensec` drops it to `0` (`1700000000000` ms), and core
   `stat:mtime` returned `18446744073709551606` for `-10s` (`-9750` ms
   via signed FFI `stat`) [w8 IO5a–IO5c]. Use signed FFI `stat` on both
   darwin and Linux.
7. **Both Gambit p1a NO-GO rows are recorded PASSes** — GC completes
   during a blocked C call (`1020` rounds, `gc-times-during=204` inside
   C-side handshake [w5]) and foreign pthreads enter cleanly through
   `scm_with_guile` (41/42 [w7]) while raw entry segfaults (`term-sig=11`
   [w7]).
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
   mutexes from `(make-mutex 'allow-external-unlock)`; standalone
   `(memory-order-acquire)` / `(memory-order-release)` fence compliance
   is **unverified** (Phase 2b **must** provide an implementation — e.g.
   a compiled C `atomic_thread_fence` helper or verified fence lowering
   — that establishes acquire/release ordering in the host's `seq.ss`
   publication pattern).
3. `sa-call-with-escape-continuation` on **`call-with-prompt`** ONLY
   (`call/cc` dropped for Phase 2b): fresh `(make-prompt-tag "escape")`
   per call, `spent` flag set on escape **and** in a `dynamic-wind`
   out-guard so every exit (normal return, escape, thrown exception,
   outer escape) invalidates `k`; unwind via `dynamic-wind`. **Do NOT**
   bake in an owner-thread check (ownership is the host layer's rule per
   `TARGET-CONTRACT.md:49-50`).
4. FFI: `#:return-errno?` for native-error (never slot reads); blocking
   collapses to plain; maintain a **callable registry** rooting every
   `procedure->pointer` `<pointer>` while C holds its
   `sa-foreign-callable-entry-point` address; use `procedure->pointer`
   for `sa-foreign-callable` (same-thread Guile mode), and either build a
   compiled C `libffi` closure helper (`ffi_prep_closure_loc` entering
   `scm_with_guile`) for `sa-foreign-callable-collect-safe` on foreign
   pthreads or qualify it as degraded until built; root FFI buffer args
   across calls; a variadic-shim C file constructing `struct flock` in C
   for `fcntl`-style locks.
5. GC: lock/unlock no-ops; `(gc)`; `sa-total-memory-bytes` ← `heap-size`,
   `sa-bytes-allocated` ← `(- heap-size heap-free-size)` (live occupied
   heap from one `(gc-stats)` snapshot); real `after-gc-hook` install.
6. I/O per w8/w9: signed FFI `stat` (`bytevector-s64-native-ref` for
   `time_t`) for ms mtime on **both** darwin and Linux (avoiding
   `filesys.c`'s unsigned `scm_from_ulong` wrap on `st_mtime`);
   canonicalize-path; O_EXCL; C-struct shim-based locks; spawn/waitpid;
   suspendable-ports event loop for DHT/WebSocket.
7. Compile tier: degrade both `sa-compile-file` and `sa-make-boot-file`
   with message-carrying raises under `CONTRACT.txt:312-319` (`.go` is
   VM bytecode, not native objects); crypto per w11 (libcrypto EVP +
   getentropy + vendored BLAKE3 decision).
