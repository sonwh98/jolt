# P1a AUDIT — Gambit 4.9.8 runtime: the mechanisms the jolt FFI contract needs

- Auditor: glm-5.3-flash (VM Runtime Engineer delegate), P1a slice, Gambit FFI track
- Date: 2026-11-18 (+07)
- Ruling followed: DOC-FIRST (owner ruling 2026-11-18) — manual chapter/section
  first, then the documented C API in the installed headers, runtime
  implementation `file:line` only where the docs underdetermine the pinned
  semantics, with the doc gap named.
- Scope: audit + witnesses ONLY. No jolt adapter code was written.

## Sources cited

- `[txi §...]` = the official manual shipped in the source clone,
  `~/workspace/gambit-v4.9.8-src/doc/gambit.txi` (line numbers of the current
  checkout, tag v4.9.8, commit 2228e4d).
- `[gambit.h:N]` = the installed configured header
  `~/.local/share/mise/installs/gambit/4.9.8/include/gambit.h`.
- `[lib/file.c:N]` = `~/workspace/gambit-v4.9.8-src/lib/...` (implementation
  tier, cited only to resolve a documented gap).
- Witness outputs are recorded verbatim in `p1a/witnesses/results/*.out`; each
  run is under the external watchdog `p1a/witnesses/watchdog.sh` (SIGKILL +
  exit 124 on timeout, so a deadlock is a recorded failure).
- Provisioned toolchain: `~/.local/share/mise/installs/gambit/4.9.8/bin/{gsi,gsc}`
  (absolute paths only; bare `gsc` on PATH is Ghostscript). The mise plugin
  (`~/.local/share/mise/plugins/gambit/lib/utils.bash:68`) builds with exactly
  `./configure --enable-single-host --prefix=...` — nothing else.

---

## Q1 — Runtime build configuration and threading model of the provisioned 4.9.8

**Answer: single VM, single OS-threaded (`___SINGLE_THREADED_VMS`), one
processor (green threads multiplexed over exactly one OS thread that runs all
Scheme execution); `--enable-single-host` codegen; NO multi-processor support
compiled in. The jolt CI flags `f8,-8,t8` are I/O-encoding defaults only and
have no threading effect. The provisioned runtime differs from CI's runtime
only in those baked default I/O options (CI's build had them compiled in via
`--enable-default-runtime-options`; mise's build uses the library defaults).**

Evidence, in the DOC-FIRST order:

1. Manual:
   - Threads are green: a thread is "a virtual processor which shares object
     space with all other threads" [txi §Threads/Introduction, gambit.txi:9876].
     Execution starts on the "primordial thread"; "All threads are terminated
     when the primordial thread terminates" [txi §Threads/Primordial thread,
     gambit.txi:10105-10114]. Nothing in the Threads chapter mentions OS-level
     threads or processors; the model presented is one object space
     multiplexed by the scheduler.
2. Documented headers (installed):
   - The configured header pins the threading model:
     `#define ___SINGLE_THREADED_VMS` [gambit.h:1469-1472]. That line is the
     configure substitution of `@CONF_SINGLE_MULTIPLE_THREADED_VMS@`
     [gambit-v4.9.8-src/include/gambit.h.in:1471], which is `___SINGLE_THREADED_VMS`
     unless `--enable-multiple-threaded-vms` is passed [configure:6348-6357;
     configure.ac:1271-1283 default `no`]. The mise plugin passes only
     `--enable-single-host`, so the provisioned build has the default.
   - `___MAX_PROCESSORS` = 1 [gambit.h:1489-1493; configure:6394-6398 sets
     `CONF_MAX_PROCESSORS=1` unless multiple-threaded-vms; the 64 maximum
     applies only to that build].
   - The comment at [gambit.h:1464-1466] states the semantics: "Are Gambit VM
     instances single or multiple threaded at the OS level? In other words,
     is it allowed for multiple OS threads to be running in a given VM
     instance?" — the provisioned answer is NO.
   - POSIX thread system is linked (`___USE_POSIX_THREAD_SYSTEM`,
     [gambit.h:1498-1505]), but that only selects the locking/primitives
     implementation; it does not create a second Scheme-executing OS thread.
   - `--enable-single-host` is codegen only: "compile each Scheme module as a
     single C function (by default each Scheme procedure is compiled to a C
     function, otherwise N ... is the maximum number of control points ...)"
     [configure:1778-1784]. It reaches the build as `-D___SINGLE_HOST`
     [configure:5116-5119] and the installed `gambuild-C` passes it to every
     compiled module (`DEFS_OBJ=" -D___SINGLE_HOST "`, bin/gambuild-C:27). It
     has no threading implication.
3. Implementation (resolves what the docs do not say about the processor
   count at startup): a VM "starts off with a single processor":
   `___vms->processor_count = 1; ___vms->mem.target_processor_count_ = 1;`
   [lib/setup.c:4791-4795]. The documented resize entry clamps any request to
   `___MAX_PROCESSORS` [gambit.h:14767-14770 declares `___current_vm_resize`;
   lib/setup.c:1163-1166 clamps; the resize machinery itself is compiled out
   entirely under `___SINGLE_THREADED_VMS`, lib/setup.c:884-1013]. The
   documented garbage-collect entry is a barrier sync over processors
   [gambit.h:14772-14775; lib/setup.c:1181-1194 via `on_all_processors`].
4. CI's `--enable-default-runtime-options=f8,-8,t8`: per the manual's Runtime
   options chapter, `f` is `file-settings=` (gambit.txi:2106), `-` is
   `stdio-settings=` (gambit.txi:2109), `t` is `terminal-settings=`
   (gambit.txi:2121), and the code `8` selects "UTF-8 character encoding"
   (gambit.txi:2356-2357) among the per-port default I/O settings
   (gambit.txi:2319-2370). So `f8,-8,t8` forces UTF-8 as the default
   character encoding for file, stdio and terminal ports — a pure I/O
   setting. It is baked into the binaries at configure time as
   `___DEFAULT_RUNTIME_OPTIONS` (configure:5412-5424), consumed first among
   the option sources before `GAMBOPT`/script/`-:` [lib/main.c:24-25,
   505-620]. **It has zero effect on threading, GC, or the FFI.** The
   provisioned runtime matches CI's threading configuration exactly (both are
   `___SINGLE_THREADED_VMS`/1-processor builds; CI added no
   `--enable-multiple-threaded-vms` either); the only divergence is the baked
   UTF-8 default encodings.

**Witness W0 (build-config, PASS)** — `p1a/witnesses/w0-config.scm`, output
`results/w0.out` (verbatim):

```
### cmd: ./watchdog.sh 60 ./w0-config.exe
=== W0 build-configuration witness ===
___VERSION=409008
___SINGLE_VM=defined
___SINGLE_THREADED_VMS=defined
___MAX_PROCESSORS=1
___USE_POSIX_THREAD_SYSTEM=defined
___SINGLE_HOST=defined (-D by gambuild-C)
___SINGLE_HOST_LIMIT=30000
___USE_RC_ALLOCATION_FOR_FOREIGN=defined
min-heap-bytes=2097152
max-heap-bytes=0
live-percent=50
parallelism-level=1
##cpu-count=8
##core-count=8
##current-vm-processor-count=1
after ##current-vm-resize(4): processor-count=1 (before: 1)
W0-VERDICT: PASS (configuration recorded)
### exit=0
```

The last three lines are the empirical proof on the provisioned binaries:
8 hardware cores exist, the VM runs ONE processor, and the documented resize
request for 4 processors is clamped back to 1.

---

## Q2 — The exact leave/re-enter (release/claim) mechanism

**Answer: no such mechanism exists in Gambit 4.9.8 — not in the manual, not
in the documented C API, and not in the runtime implementation. There is no
entry point by which the code inside a foreign call releases the processor
for other threads and re-claims it afterwards.**

- Doc tier 1 (manual): the entire C-interface chapter (gambit.txi:18672-19993)
  documents c-declare/c-initialize/c-lambda/c-define/c-define-type and the
  nesting section. No release/claim/suspend/resume of runtime ownership is
  documented anywhere. The nearest documented behavior is the WARNING that
  nested C→Scheme calls are unsafe across threads (see Q3/Q4).
- Doc tier 2 (headers): `gambit.h` has no `___leave`/`___enter`/`claim`
  execution-ownership API (grep negative). The only exported "release" entry
  points are OBJECT releases — `___release_rc`, `___release_scmobj`,
  `___release_pointer`, `___release_string`, ... (gambit.h:9840-9886,
  10179-10268) — reference-count releases for foreign data, unrelated to
  execution ownership. The exported runtime-control API is exactly:
  `___setup_params_reset`, `___setup`, `___cleanup`,
  `___cleanup_and_exit_process`, `___current_vm_resize`, `___garbage_collect`,
  `___setup_vmstate`/`___cleanup_vmstate`/`___setup_pstate`/`___cleanup_pstate`
  [gambit.h:14757-14788] — none of them releases the current processor while
  staying inside a foreign frame.
- Implementation tier (gap justified: the docs do not determine whether an
  undocumented mechanism exists): grep of `lib/*.c` for
  `___leave/___claim/LEAVE_GAMBIT/ENTER_GAMBIT/___reclaim` returns nothing.
  The processor hand-off points that DO exist are only (a) the scheduler's
  own green-thread switch (inside Scheme execution, at safe points — never
  inside a foreign call) and (b) the multi-processor sync ops
  (`barrier_sync_op`, lib/setup.c:542+) — which are compiled to no-ops under
  `___SINGLE_THREADED_VMS` (lib/setup.c:527-541, 549) and would require a
  second processor anyway. A c-lambda/c-define body runs inline on the
  owning processor for its whole duration; the generated entry/exit macros
  (gambit.h:10028-10044 `___BEGIN_SFUN_*` / `___END_SFUN_*`; `___BEGIN_CFUN_*`
  in gambit.h:10327-10360) contain no ownership transition.

Consequence for the jolt blocking transition (astra §2 steps 4 and 6 — "Leave
runtime execution through the verified mechanism" / "Re-enter the runtime
through its required claim mechanism"): **there is no verified mechanism to
use.**

---

## Q3 — Does a released foreign frame permit (a) another Gambit thread to run and (b) collection to complete?

**Answer: the question's premise (a "released foreign frame") cannot be
constructed on this build — there is no release (Q2). Moreover, even if C
code simply blocks without releasing anything, NO other Gambit thread can run
and NO collection can complete, for two independent structural reasons:**

1. **One OS thread executes everything.** With `___SINGLE_THREADED_VMS` and
   `___MAX_PROCESSORS=1` (Q1), all green threads are multiplexed by the
   scheduler onto the single OS thread that entered the runtime. While that
   OS thread is inside a foreign call, the scheduler is not running, so no
   other green thread can be dispatched. There is no second OS thread that
   could run them.
2. **No release-on-block exists** (Q2), so the blocked foreign call occupies
   the only processor until it returns.
3. **GC cannot run either.** Collection is driven by the running thread: at
   allocation points inside Scheme execution, or explicitly through
   `(##gc)` — whose primitive body calls the documented C API
   `___garbage_collect` (gambit.h:14772-14775; lib/_kernel.scm:2032-2069) —
   which is a synchronous barrier op over all processors
   (lib/setup.c:1181-1194, `on_all_processors`). With the only thread blocked
   in C, no allocation-driven GC happens and no thread exists to call
   `___garbage_collect`. The manual's own documentation of the C-interface
   corroborates the serialization: "This situation can be avoided by having
   only one Scheme thread that does Scheme to C to Scheme calls. Other Scheme
   threads are limited to simple Scheme to C calls that don't call back to
   Scheme" [txi §Continuations, the C-interface and threads,
   gambit.txi:19980-19991].

Mechanism summary (what makes it true/false): `___GET_REAL_PSTATE()` returns
the ONE fixed processor state `&___GSTATE->vmstate0.aligned_pstate[0].pstate`
and `___SET_REAL_PSTATE(ps)` is a no-op under `___SINGLE_THREADED_VMS`
[gambit.h:8606-8612] — there is exactly one execution context in the process
and no way to create another.

**Witness W2 (blocking-GC) — control PASS, blocked FAIL (decisive NO-GO
evidence for the `sa-foreign-procedure-blocking` row on this build).**
`p1a/witnesses/w2-blocking.scm` + `w2-fixture.c`; outputs
`results/w2-control.out`, `results/w2-blocked.out`.

- Control (non-blocking foreign calls + real GC from another thread): PASS.
  The runtime's own `*** GC:` report lines (enabled by `-:d5`, "At level 5
  and above garbage collection reports are displayed during program
  execution", gambit.txi:2236-2238) are the verbatim proof that REAL
  collections ran — the adapter's no-op `sa-gc-collect` cannot produce them
  (host/gambit/scheme-adapter-runtime.ss:81, `sa-gc-collect` returns `#f`).

```
W2-B: round 1 t=1795020328.917097 allocating + ##gc (runtime primitive)
*** GC: 507us, 93K alloc, 6.5M heap, 1.6M live (24% 69936+1607840)
W2-B: round 1 t=1795020328.918424 done (capi-gc-return=0)
...
W2-A: non-blocking foreign call 1 t=1795020328.920896
W2C: non-blocking foreign call entered+returned
...
W2-VERDICT: PASS (control: real collections completed while another thread made foreign calls; the *** GC: report lines above are the runtime's own collection evidence)
### exit=0
```

- Blocked: FAIL, exactly as predicted. Thread B is made runnable 0.3 s after
  thread A enters the blocking foreign call (6 s C-side deadline). During the
  entire blocked window B produces ZERO lines and ZERO `*** GC:` reports; B's
  rounds all appear after `W2C: foreign call RETURNING`:

```
W2: t=1795020329.854461 start
W2C: foreign call ENTERED, blocking on handshake (deadline 6s)
W2C: foreign call RETURNING after blocked interval
W2-B: round 1 t=1795020335.854959 allocating + ##gc (runtime primitive)
*** GC: 834us, 93K alloc, 6.5M heap, 1.6M live (24% 69472+1607840)
...
W2: blocked window from t=1795020329.854498 to t=1795020335.862667
W2-VERDICT: FAIL (blocked: no collection and no other-thread progress while the foreign call was blocked — every W2-B line above appears after 'W2C: foreign call RETURNING'; the VM has a single processor and 4.9.8 has no foreign-release mechanism, so the blocking row cannot be satisfied on this build)
### exit=0
```

The ~6.0 s gap between the blocked window start (…329.854) and B's first
round (…335.854) is the starvation measured directly. A Scheme-internal
watchdog cannot fire in this state (the whole VM is frozen), which is why
every run is wrapped in the external `watchdog.sh`; here the C-side deadline
produced the structured verdict, and `exit=0` is the witness program's own
exit, not a pass of the gate.

---

## Q4 — Rules for a previously unknown pthread entering Scheme

**Answer: there is NO documented protocol, and there is no usable mechanism
either. A previously unknown pthread may not run Scheme code on this build:
the empirically observed outcome of naive entry is a deterministic SIGSEGV
(and nondeterministic corruption for concurrent entry).**

- Doc tier 1 (manual): no protocol is documented. The c-define section
  documents only the single-threaded "server" pattern: initialize with
  `___setup` from the driving thread, terminate with `___cleanup`
  (gambit.txi:19448-19451; sample tests/server.scm + tests/client.c). The
  nesting section explicitly restricts multi-thread use: only ONE Scheme
  thread may perform Scheme→C→Scheme calls, others only simple Scheme→C calls
  (gambit.txi:19980-19991) — it says nothing about foreign OS threads.
- Doc tier 2 (headers): under `___SINGLE_THREADED_VMS` there is no way to
  associate a second OS thread with the runtime:
  `___GET_REAL_PSTATE()` returns the fixed global pstate and
  `___SET_REAL_PSTATE(ps)` is a NO-OP (gambit.h:8606-8612) — a foreign thread
  cannot even be bound to a processor state. `___setup_pstate`
  (gambit.h:14782-14784) exists, but on this build no second pstate can be
  created: the only creation path, `___vm_resize_pstate`, is compiled out
  (lib/setup.c:866-1013, body under `#ifndef ___SINGLE_THREADED_VMS`), and
  `___current_vm_resize` clamps to 1 (lib/setup.c:1163-1166). The generated
  c-define entry macros require a current processor state with no ownership
  check (`___processor_state ___ps=___PSTATE;` — gambit.h:10028-10044), so a
  foreign pthread that calls a c-define'd function silently shares the
  primordial's pstate.
- Implementation tier (the crash mechanism — gap justified: the docs do not
  describe what happens; the crash explains WHY no protocol is offered):
  the C→Scheme entry `___call` arms a setjmp catcher ON THE CALLING THREAD'S
  C STACK (`___BEGIN_TRY` sets `___ps->catcher = &___jbuf` with `___jbuf` a
  local — gambit.h:9966-9971) and, on the Scheme→C return, the return-to-C
  handler jumps back "inside ___call" with
  `___throw_error(___UNWIND_C_STACK)` (lib/_kernel.c:11772). The unwind
  target is the SHARED pstate's catcher chain, and the cross-processor guard
  in that handler is compiled out under `___SINGLE_THREADED_VMS`
  (lib/_kernel.c:11742-11755). After `___setup` returns on the primordial,
  the outermost catcher of that chain is NULL (`___setup_pstate` initializes
  `___ps->catcher = 0`, lib/setup.c:4755; `___run`'s catcher is a stack local
  restored on return, lib/setup.c:3389-3415). The observed macOS crash report
  for W3 phase1 matches exactly:

```
exception: EXC_BAD_ACCESS, SIGSEGV, KERN_INVALID_ADDRESS at 0x00000000000000b0
  libsystem_platform.dylib  longjmp
  w3.exe  ___call
  w3.exe  scheme_w3_add
  w3.exe  w3_worker_serialized
  libsystem_pthread.dylib  _pthread_start
```

  — the foreign thread's entry faults inside `longjmp` reading the NULL
  (0xb0 ≈ jmpbuf field offset) or foreign-stack catcher.

**Witness W3 (foreign-thread entry) — FAIL on every mode.**
`p1a/witnesses/w3-fthread.c` + `w3-server.scm` (the manual's documented
"Scheme server" build pattern, tests/makefile.in:166); outputs
`results/w3-phase1.out`, `w3-phase1-nobeat.out`, `w3-phase2-run1.out`,
`w3-phase2-run2.out`, `w3-phase3.out`.

- phase1 — raw pthread calls c-define'd Scheme procedures after `___setup`,
  primordial parked in `pthread_join` (serialized, heartbeat on): **SIGSEGV,
  exit 139, deterministically (3/3 runs across the session)**, before the
  worker's first Scheme call completes (no `W3-WORKER` line is ever printed):

```
W3: ___setup returned; runtime live (___VERSION=409008)
W3-PHASE1: spawning raw pthread (primordial will park in pthread_join)
W3-PHASE1: heartbeat interval = 0.010000
./watchdog.sh: line 21:  1511 Segmentation fault: 11  "$@"
### exit=139
```

- phase1-nobeat — same, with the heartbeat DISABLED via the undocumented
  `___set_heartbeat_interval(0)` (lib/os_time.c:937-948; used only to isolate
  the crash cause): **still SIGSEGV, exit 139** — the crash is not the
  heartbeat interrupt.

```
W3-PHASE1: heartbeat DISABLED for this run
./watchdog.sh: line 21:  1532 Segmentation fault: 11  "$@"
### exit=139
```

- phase2 — concurrent entry (worker calls Scheme while the primordial thread
  runs an allocating Scheme loop): **nondeterministic undefined behavior —
  observed exit 139 (SIGSEGV) in one session and exit 70 (silent runtime
  fatal exit, no message) twice in the recorded session; outcomes vary
  between runs of the same binary.**

```
W3-PHASE2: spawning raw pthread WHILE primordial runs scheme_w3_spin
### exit=70
```

- phase3 — owner Gambit thread parked inside a cfun (c-lambda) call while the
  worker enters (the shape under which W4-M4's callback survived): **still
  SIGSEGV, exit 139** — even the discriminating allocating entry
  (`scheme_w3_add_alloc`) never completes:

```
W3-PHASE3: owner Gambit thread parks INSIDE a cfun call while the worker pthread enters Scheme
./watchdog.sh: line 21:  1590 Segmentation fault: 11  "$@"
### exit=139
```

**Verdict for the contract row:** an unrelated C thread may NOT enter Scheme
on the provisioned 4.9.8 build. NO-GO for callbacks from an unrelated C
thread; the refusal row stays.

---

## Q5 — Root and processor-state obligations across leave/re-enter transitions

**Answer: there are no leave/re-enter transitions to service (Q2). The
obligations that DO exist are the ones around the two documented crossing
directions — Scheme→C (cfun/c-lambda) and C→Scheme (sfun/c-define) — and they
are all documented; they are also exactly why an uncoordinated foreign thread
cannot enter (no rooted context of its own).**

1. **Processor-state propagation through conversions.** Every conversion
   helper takes the current processor state and callers must propagate it
   with the `___PSD`/`___PSP` macros: "Note that the use of the `___PSD` macro
   in the parameter list of `SCMOBJ_to_POINT` and the `___PSP` macro in the
   calls ... are necessary to propagate the current processor state to that
   function" [txi §c-define-type example, gambit.txi:19726-19731]. The
   generated c-define entry pins this contract in the header:
   `___BEGIN_SFUN_*(proc)` begins with `___processor_state ___ps=___PSTATE;`
   [gambit.h:10028-10044]. There is no way to pass a DIFFERENT pstate — the
   current one is fixed (gambit.h:8606-8612).
2. **What must be rooted, and for how long.**
   - C→Scheme results allocate STILL objects on the C heap, reference-counted:
     "`___SCMOBJ ___make_pair(___processor_state ___ps, ___SCMOBJ car,
     ___SCMOBJ cdr);` ... A `NULL` `___ps` parameter will allocate the pair
     permanently ... Otherwise a 'still' object is allocated and the
     `___ps` parameter indicates the processor in whose heap the object is
     allocated ... Still objects are reference counted and initially have a
     reference count equal to 1. The call to `___release_scmobj` in the
     macros `___END_CFUN_..._to_SCMOBJ` and `___END_SFUN_..._to_SCMOBJ`
     decrement this reference count. A still object whose reference count is
     zero will be deallocated when a garbage collection is performed and
     there are no references to it from the Scheme world." [txi
     gambit.txi:19706-19724]. The corresponding documented macros:
     `___alloc_rc`/`___release_rc` used by every struct/union/type
     conversion (gambit.h:9814-9876, `___USE_RC_ALLOCATION_FOR_FOREIGN`).
   - The C→Scheme ENTRY must root the called procedure for the duration of
     the call: `___make_sfun_stack_marker` creates a heap vector holding the
     procedure, killed by `___kill_sfun_stack_marker` after the call
     (gambit.h:10028-10044; lib/c_intf.c:6511-6556; the marker is the
     "unwind destination" the return-to-C handler checks,
     lib/_kernel.c:11741-11772). The TODO in
     lib/c_intf.c:6528-6529 ("proc_or_false may have been GC'd at this
     point! protect it some way") documents the sharp edge the macro family
     papers over.
   - Scheme→C: the lifetime rule is that pointers to Scheme objects passed
     into C are valid only for the call's duration; C must not keep them.
     The manual documents the conversion-temporary contract ("The temporary
     memory allocated from the C heap for the conversion of the arguments
     and result will be reclaimed whether there is an error or not", txi
     §c-lambda, gambit.txi:19296-19300) and the `___AT_END` hook as the
     cleanup point after the result is converted (gambit.txi:19313-19319).
     The foreign-type `release-function` is invoked "at most once ... When
     the garbage collector detects that a foreign object is no longer
     reachable ... it will invoke the release-function" (gambit.txi:19022-19036).
   - Object identity across GC: the manual's release-function semantics are
     the documented rooting story for foreign objects; there is NO documented
     pinning API (relevant to `sa-lock-object`: the CONTRACT's non-moving
     collector exemption does not transfer — nothing in 4.9.8 documentation
     or headers pins a moving Scheme object).
3. **What must be saved/restored.** For the two documented directions, the
   generated macros do it all: cfun entry saves the Scheme registers to
   memory and restores them on exit (`___BEGIN_CFUN_CTX` = `___SET_STK`
   + `___W_ALL` ... `___END_CFUN_CTX` = `___R_ALL`, gambit.h:10310-10311), and
   the sfun entry builds/kills the stack marker (gambit.h:10028-10044). There
   is nothing for an integrator to save manually — and nothing the
   integrator CAN save manually, because the catcher/stack context is
   per-thread C-stack state held in the shared pstate (gambit.h:9966-9972;
   lib/setup.c:4755) — precisely the state a foreign pthread cannot
   legitimately own (Q4).

**Witness W1 (errno-atomicity, PASS)** — `p1a/witnesses/w1-errno.scm` +
`w1-fixture.c`; output `results/w1.out`. Exercises the conversion-boundary
obligations above (the astra essential sequence) plus nesting (the
documented one-thread C→Scheme→C→Scheme) and two-thread interleaving:

```
### cmd: ./watchdog.sh 120 ./w1.exe
=== W1 errno-atomicity witness ===
EAGAIN=35 EACCES=13 EIO=5
W1-CHECKS=4000
W1-FAILURES=0
W1-VERDICT: PASS (result+errno pair captured atomically at the shim; capture order proven by post-capture and ___AT_END clobbers; per-invocation capture proven by nesting and threads)
### exit=0
```

Mechanisms exercised: typed C shims capturing (result, errno) immediately
after the target (shapes A/B/C, 200 each); success preserving errno=42 (no
normalization); deliberate post-capture clobber (errno=7777) in every shim;
`___AT_END` clobber AFTER result conversion (shape D, 100); nested
re-entry capture (shape E, 100 — outer pair captured before the C→Scheme→C
round trip must still be (−3, EIO)); 2 Scheme threads × 400 interleaved
iterations each (a global "last errno" cell or deferred re-read fails these;
per-invocation capture passes). 4000/4000 assertions correct on macOS arm64.

---

## Witness W4 (callables) — modes that work and modes that do not

`p1a/witnesses/w4-callables.scm` + `w4-fixture.c`; outputs
`results/w4-mode1.out`, `w4-mode4-run{1,2,3}.out`, `w4-mode5.out`.

- **M1 same-thread callback (C fixture → c-define'd Scheme proc): PASS.**
  `w4_call_cb(4) -> 40` — the documented c-define path (gambit.txi:19396-19451).
- **M2 nested callbacks C→Scheme→C→Scheme on one thread: PASS.**
  `w4_nested_a(1) -> 1107` (chain a(1)→p(1)→b(2)→q(2)→…→1107). Documented as
  allowed for ONE thread (gambit.txi:19936-19991).
- **M3 callback from a second Gambit thread "during" a released blocking
  call: structurally impossible on this build.** Demonstrated: thread A
  blocks 2 s inside the foreign call, thread B attempts the same callback
  during the block — B's attempt and completion occur only AFTER A's call
  returned (probe `B-completed-during-A-block = 0`; B's log line t=…337.834
  vs A's return t=…337.534). Verdict PASS only in the serialized sense; the
  jolt requirement (progress during the foreign call) is covered by W2's FAIL.
- **M4 callback from a raw foreign pthread: PASS-QUALIFIED, NOT a supported
  mode.** The callback returned `1005` in 3/3 runs when the owner Gambit
  thread was parked inside the cfun call (serialized reuse of the single
  pstate). But the structurally closest sibling — W3 phase3, same owner-parked
  shape, worker calling a c-define'd procedure — SIGSEGVs 1/1, and W3 phase1
  SIGSEGVs 3/3. Survival here is an undocumented artifact of the exact
  frame state, not a contract: no protocol exists (Q4), nothing roots the
  worker's context, and the same witness family crashes one shape over.
  P1b must NOT advertise this mode; the refusal row stays.
- **M5 exception raised inside a callback: the process dies.** The error
  escapes the callback, prints `*** ERROR IN w4-m5 -- w4-cb-raise:
  deliberate exception 3` and exits with status 70 — the C caller gets no
  error code and no chance to handle it. Consequence for P1b: callback error
  handling must be INSIDE the callback body (with-exception-catcher), which
  is exactly what the manual's own server example does
  (`catch-all-errors`, tests/server.scm:15-19) — a bounded implementation
  should make this part of the callable contract; an uncaught callback
  exception must be treated as a host-fatal event, not a recoverable error.

```
### cmd: ./watchdog.sh 60 ./w4.exe mode5
=== W4 mode5: M5 exception inside a callback ===
W4-M5: calling w4_call_raise(3) — callback raises a Scheme error
*** ERROR IN w4-m5 -- w4-cb-raise: deliberate exception 3
### exit=70
```

---

## Other contract-relevant findings

1. **`(##gc)` is the real collection primitive** for the adapter's
   `sa-gc-collect` upgrade path: lib/_kernel.scm:2051-2069 calls the
   documented `___garbage_collect` (gambit.h:14772-14775). The adapter's
   current no-op (host/gambit/scheme-adapter-runtime.ss:81-82) can be
   replaced by `(##gc)` — W2's control run shows it produces real collections
   (the `*** GC:` report lines). This is safe within one processor's Scheme
   execution; it does NOT solve anything about blocking calls (Q3).
2. **`___setup_pstate`/`___setup_vmstate` are exported** (gambit.h:14776-14787)
   but unusable for foreign threads on this build (Q4): no second pstate can
   be created (resize compiled out), no TLS binding exists to install one.
3. **Variadic C functions are not supported by c-lambda** ("Variadic C
   functions are not supported", txi §c-lambda, gambit.txi:19297) — relevant
   to the jolt varargs-specialization path (astra's construction-path
   inventory).
4. **errno observation:** W1 proves the errno pair can be captured
   atomically in typed shims on this build (macOS errno values:
   EAGAIN=35, EACCES=13, EIO=5; the witness probes them at runtime so the
   assertions hold on Linux too).
5. **Watchdog requirement is structural:** a blocked foreign call freezes the
   whole VM (W2 blocked), so no in-process timeout can ever fire — every
   jolt-level witness driver that calls foreign code must be watchdogged
   externally (the Makefile does this for every run).

---

## GO / NO-GO recommendation for P1b (astra §5 criteria, verbatim application)

**NO-GO for P2/P3 — and PARTIAL-GO is available only for the basic tier.**
Applying astra's exact wording:

- "**NO-GO for P2/P3:** collection cannot complete while C is blocked" —
  PROVEN by W2 (blocked: zero collection, zero other-thread progress over the
  6 s blocked window, on the pinned runtime). This criterion is met, and it
  alone forces NO-GO for P2/P3, because "P2 remains Chez-only if P1 blocking
  is unqualified" and "Removing `:blocking` from crypto calls is not an
  acceptable workaround".
- "**unrelated C-thread entry cannot be made safe where required**" — PROVEN
  by W3 (deterministic SIGSEGV on serialized entry; nondeterministic
  SIGSEGV/exit-70 on concurrent entry; crash mechanism rooted in the shared
  pstate catcher chain, gambit.h:9966-9972 + lib/_kernel.c:11741-11772 +
  gambit.h:8606-8612).
- "**exact runtime ownership rules remain unknown**" — they are now known,
  and they say: one pstate, one OS thread, no release/claim, no foreign
  thread protocol. That knowledge closes the audit but confirms the rows
  cannot be qualified on this build.
- The worker-pool escape is pre-ruled by astra ("A worker pool is **not** a
  transparent generic fallback ... cannot masquerade as unrestricted
  `sa-foreign-procedure-blocking`") — and W3/W4 additionally show that even
  moving a call to another pthread does not give that thread a valid Scheme
  context (SIGSEGV), so the pool would have to run calls on the SAME (only)
  OS thread, which is precisely the serialization that defeats blocking.
- **Partial GO (astra's fallback ruling):** "memory, loading, ordinary calls,
  and errno may land independently when qualified." W1 (errno) PASSes; the
  ordinary-call tier is exercised throughout W1/W2-control/W4-M1/M2 via
  c-lambda/c-define with correct results; the memory/loader tier was not
  separately qualified here (dlopen/sa-foreign-alloc are NOT part of P1a's
  witness list — they are P1b implementation targets; nothing observed
  contradicts them, but they are unqualified by this audit).

**Bottom line:** the pinned Gambit 4.9.8 (mise default configure,
`--enable-single-host`, `___SINGLE_THREADED_VMS`, 1 processor) can support the
jolt FFI tier's basic surface (typed shims with atomic errno capture, ordinary
non-blocking calls, callbacks on the owning thread, real `(##gc)`), but it
CANNOT support `sa-foreign-procedure-blocking`'s contract (other threads' GC
must proceed while C is blocked) or callbacks from unrelated C threads, and
there is no runtime mechanism that could be used to build them. Per astra's
fallback ruling, those constructors must keep raising their message-carrying
unsupported errors and `CONTRACT.txt`/`TARGET-CONTRACT.md` must describe the
partial mode. The next decision on those rows is an explicit Gambit upgrade
or runtime patch through the upgrade gate (e.g. a build with
`--enable-multiple-threaded-vms` would still need a verified foreign-thread
attach protocol, which upstream does not document even for that build).

### Reproducing

```
cd ~/workspace/jolt-ffi-p1/p1a/witnesses
make clean && make all        # builds every witness, runs each under watchdog.sh, records results/*.out
```

Witness sources: `w0-config.scm`, `w1-errno.scm` + `w1-fixture.c`,
`w2-blocking.scm` + `w2-fixture.c`, `w3-fthread.c` + `w3-server.scm`,
`w4-callables.scm` + `w4-fixture.c`, `watchdog.sh`, `Makefile`. Recorded
verbatim outputs: `results/*.out` (one file per run, `### exit=` per run).
Toolchain: `/Users/sto/.local/share/mise/installs/gambit/4.9.8/bin/gsc`
(never bare `gsc`; that is Ghostscript).

### Open risks / limitations of this audit

- Witnesses ran on macOS arm64 (darwin 25.6.0). astra requires both macOS
  arm64 and Linux x86_64 for the pinned rows; the Linux leg is unexecuted in
  P1a. The structural evidence (configured header, compiled-out resize,
  shared-pstate catcher) is platform-independent, but the crash signatures
  (SIGSEGV in longjmp, exit-70) should be re-recorded on Linux before any
  document update that cites them.
- W3-phase2/W4-M4 outcomes are nondeterministic/fragile by nature; the
  recorded outputs are one sample of a nondeterministic distribution (two
  observed exit codes for phase2 across sessions). The deterministic rows
  (phase1/phase3 SIGSEGV) were reproduced 3/3 and 1/1 respectively.
- The out-of-tree differently-configured Gambit build (p1a/gambit-builds/)
  was NOT needed and NOT built: the audit's verdicts follow from the
  provisioned configuration itself; a multiple-threaded-vms build would not
  change the missing-protocol conclusion.
- `make clean` regenerates everything; committed sources only (no binaries,
  no generated .c files).
