# P1a AUDIT — Gambit 4.9.8 runtime: the mechanisms the jolt FFI contract needs

- Auditor: glm-5.3-flash (VM Runtime Engineer delegate), P1a slice, Gambit FFI track
- Date: 2026-11-18 (+07)
- Ruling followed: DOC-FIRST (owner ruling 2026-11-18) — manual chapter/section
  first, then the documented C API in the installed headers, runtime
  implementation `file:line` only where the docs underdetermine the pinned
  semantics, with the doc gap named.
- Scope: audit + witnesses ONLY. No jolt adapter code was written.
- Revision p1a-r2 (2026-11-19, same lane): witnesses W1/W2/W3 repaired and
  this document corrected per the ACCEPTED codex review findings F1-F5
  (`collab/jolt/1795030000000-reviewer-p1a-audit-codex.gpt-6.1-sol.findings.md`).
  Per-finding repairs: F1 — W3 exported one argument to two-formal procedures
  (and a third same-class defect: `scheme_w3_phase3` declared `(int)` against
  zero formals); both add entries are now `(int int)`, the generated C is
  verified `___NARGS 2` at build time, an owner-thread control gates every
  phase, and survival is recorded as REFUSAL-NOT-REPRODUCED, never success.
  F2 — every W1 shim now captures `int saved = errno;` immediately after the
  target, before ANY malloc/conversion/re-entry, targets own their errno, and
  intervening-clobber negative controls (shapes F/G) make capture order
  load-bearing. F3 — W2 gained the `qualify` mode: both participants
  synchronized before the foreign call blocks, the C release handshake is
  actually called from Scheme after B completes real collections, and every
  verdict is derived from observed state; the P1a `blocked` mode is kept as a
  documented starvation demonstration. F4 — the categorical all-configuration
  claims are withdrawn and restated configuration-scoped with the
  multiple-threaded-VMs barrier analysis cited. F5 — the citation errors are
  corrected (manual 19305-19307 and 19328-19332; c_intf.c:6530; setup.c
  1169-1170 and :1196; the Threads chapter DOES discuss OS threads and
  multiprocessors). The verdict is amended per the reviewer: NO-GO for P2/P3
  on the provisioned build confirmed; the foreign-entry-impossible claim is
  WITHDRAWN; PARTIAL-GO per capability.

## Sources cited

- `[txi §...]` = the official manual shipped in the source clone,
  `~/workspace/gambit-v4.9.8-src/doc/gambit.txi` (line numbers of the current
  checkout, tag v4.9.8, commit 2228e4d).
- `[gambit.h:N]` = the installed configured header
  `~/.local/share/mise/installs/gambit/4.9.8/include/gambit.h`.
- `[lib/file.c:N]` = `~/workspace/gambit-v4.9.8-src/lib/...` (implementation
  tier, cited only to resolve a documented gap).
- Witness outputs are recorded verbatim in `p1a/witnesses/results/*.out`
  (tracked; refreshed by `make record-tracked` only after a full verified
  PASS run); scratch recordings and all build artifacts live under
  `p1a/witnesses/build/` (`build/results/` holds the reviewer-comparison
  copies and the working recordings). Each run is under the external watchdog
  `p1a/witnesses/watchdog.sh` (SIGKILL + exit 124 on timeout, so a deadlock is
  a recorded failure, independently of any in-process verdict).
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
     gambit.txi:10105-10114]. The chapter's OPENING explicitly relates Scheme
     threads to OS threads and multiprocessors — "managed entirely by Gambit's
     runtime and are not related to the host operating system's threads" and
     the runtime "does not currently take advantage of multiprocessors (i.e.
     at most one thread is running)" [gambit.txi:9843-9847]. (p1a-r2
     correction, review finding F5: the P1a text here wrongly said the
     Threads chapter mentions no OS threads/processors.) The chapter's model
     remains one object space multiplexed by the scheduler; note that this
     manual text also omits the source's optional multiple-threaded-VMs and
     SMP variants (configure.ac:1271-1316) — the omission is the manual's, not
     the source's (see the Q2 amendment for what that changes).
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
   the clamp is at lib/setup.c:1169-1170 — p1a-r2 correction, review finding
   F5; the resize machinery itself is compiled out entirely under
   `___SINGLE_THREADED_VMS`, lib/setup.c:884-1013]. The documented
   garbage-collect entry is a barrier sync over processors [gambit.h:14772-
   14775; lib/setup.c:1182-1199 — the `on_all_processors` call is at :1196,
   p1a-r2 correction, review finding F5].
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

**Answer (configuration-scoped — p1a-r2 amendment of review finding F4, the
categorical all-configuration claim is WITHDRAWN): no release/claim mechanism
is documented or present in the PROVISIONED configuration
(`___SINGLE_THREADED_VMS`, one processor). There is no entry point by which
the code inside a foreign call releases the processor for other threads and
re-claims it afterwards on that build. The 4.9.8 source DOES contain materially
different TLS, processor-startup, SMP-scheduling and cross-processor-return
paths in the multiple-threaded-VMs / SMP configurations; they are analyzed
below at source level (review Q3) but are NOT qualified by executed evidence,
so the build question is closed for the provisioned configuration only.**

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
- What changes in the multiple-threaded-VMs configuration (source-level
  analysis, review Q3 — NOT an executed qualification; cited because the
  withdrawn categorical claim must be replaced by a scoped one): configure
  independently selects `--enable-multiple-threaded-vms` (configure.ac:1271-
  1283), `--enable-smp` (configure.ac:1289-1299) and `--enable-max-processors=N`
  (configure.ac:1306-1316, effective only with multiple-threaded VMs —
  `CONF_MAX_PROCESSORS=1` otherwise, configure.ac:1313). Processor lookup
  moves from the fixed primordial pstate to per-thread state
  (include/gambit.h.in:8607-8612 single-threaded vs the TLS getter/setter or
  TLS variable at :8673-8686). TLS selection SUPPLIES a processor-state
  address; it is NOT a release/claim protocol: the FFI macros still only
  save/restore Scheme registers around C execution (gambit.h:10310-10334) and
  do not mark that processor absent from GC participation. Collection still
  proceeds through `on_all_processors` (lib/setup.c:1132-1149 raises the
  interrupt and enters the synchronization loop; the `___garbage_collect`
  call is at :1196), and the multithreaded barrier waits for ALL
  `vms->processor_count` participants (SYNC_GET_MSG wait at lib/setup.c:498-
  513; the tree barrier at :554-580; operation selection at :1028-1068,
  1098-1099; the collector's own barrier at lib/mem.c:7002). A processor
  stuck in an ordinary synchronous C call does not execute
  `service_sync_op`, so additional processors may permit Scheme progress
  BEFORE a collection request but do not establish collection COMPLETION
  while that call remains blocked. The separate SMP scheduler must not be
  equated with multiple-threaded VMs: lib/_thread.scm:9-24 selects it and
  `##startup-processor!` (:3110-3125) starts scheduling on additional
  processors only under it. Runtime-created processors DO bind their OS
  thread to a pstate (`___thread_set_pstate`, lib/os_thread.c:697-708, called
  from `start_processor_execution`, lib/setup.c:805-835; membership changes
  synchronized at lib/setup.c:940-996) — but those operations are not a
  documented recipe for attaching an arbitrary caller, and the
  cross-processor C-return guard (lib/_kernel.c:11743-11755) protects return
  routing, not attachment.

Consequence for the jolt blocking transition (astra §2 steps 4 and 6 — "Leave
runtime execution through the verified mechanism" / "Re-enter the runtime
through its required claim mechanism"): **there is no verified mechanism to
use on the provisioned build, and none is documented for any 4.9.8
configuration; the multithreaded-VMs variant additionally retains the
all-processor GC barrier obstacle above. Any proposed bridge must identify
the exact transition and root-update rules it uses.**

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
   (lib/setup.c:1182-1199; the `on_all_processors` call is at :1196 — p1a-r2
   correction, review finding F5). With the only thread blocked
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

**Witness W2 (blocking-GC, p1a-r2) — control PASS (derived), qualify FAIL
with the observed-state facts (the qualification witness), blocked
STARVATION-DEMONSTRATED (kept as diagnostic). Decisive NO-GO evidence for the
`sa-foreign-procedure-blocking` row on this build.**
`p1a/witnesses/w2-blocking.scm` + `w2-fixture.c`; outputs
`results/w2-control.out`, `results/w2-qualify.out`, `results/w2-blocked.out`.
p1a-r2 repairs (review finding F3): both participants are STARTED AND
SYNCHRONIZED before the foreign call blocks (B is proven executing via a flag
its first action sets, observed by A before A enters C); the C release
handshake is actually CALLED FROM SCHEME (via c-lambda) and only after B
completes a REAL collection that mutates a live rooted witness object; every
verdict is DERIVED from observed state (completion counters, the C fixture's
own in-block flag, handshake counters, witness-object slots) — nothing is
printed unconditionally; wrong values, absent handshakes and inconsistent
observations are FAILURES; the external watchdog's exit 124 is the independent
timeout detection and is always a recorded failure.

- Control (non-blocking foreign calls + real GC from another thread): PASS,
  derived from observed state (B executed; 3/3 real-GC rounds started while A
  had completed <3 calls; witness-object mutations intact). The runtime's own
  `*** GC:` report lines (enabled by `-:d5`, "At level 5 and above garbage
  collection reports are displayed during program execution",
  gambit.txi:2236-2238) are the verbatim proof that REAL collections ran —
  the adapter's no-op `sa-gc-collect` cannot produce them
  (host/gambit/scheme-adapter-runtime.ss:81, `sa-gc-collect` returns `#f`).

```
W2-B: round 1 t=1795023506.574176 start (c-in-block=0 a-calls-done=0)
*** GC: 543us, 99K alloc, 6.5M heap, 1.6M live (24% 70016+1607864)
W2-B: round 1 t=1795023506.575742 done (capi-gc-return=0)
...
W2-A: non-blocking foreign call 1 t=1795023506.579131
W2C: non-blocking foreign call entered+returned
...
W2: observed state: b-executed=#t rounds-overlapping-a-calls=3 witness-object=(last-round=3 round-count=3)
W2-CONTROL-VERDICT: PASS (derived from observed state: B executed, 3 of 3 real-GC rounds started while A had completed <3 foreign calls, witness-object mutations intact after real collections; the *** GC: report lines above are the runtime's own collection evidence)
### exit=0
### w2-outcome: run completed (verdict derived inside; see the W2-CONTROL-VERDICT line)
```

- Qualify (THE qualification witness for the blocking row): FAIL, derived
  from observed state. Thread B is proven executing on the runtime BEFORE A
  enters C (its first action sets the flag; A's log line "OBSERVED B
  executing" precedes A's entry line). A enters the blocking foreign call
  (6 s C-side deadline). B — which on this build cannot execute during the
  block — completes its real GC rounds only after C returns, and calls the
  release handshake from Scheme after round 1's real collection; the C
  fixture records that the handshake arrived AFTER the wait ended
  (`handshake-during-block=0`, `release-cause=deadline`):

```
W2-B: EXECUTING on the runtime t=1795023507.521979
W2-A: OBSERVED B executing on the runtime (synchronized) t=1795023507.534523
W2-A: entering blocking foreign call (B synchronized and executing) t=1795023507.534609
W2C: foreign call ENTERED, blocking on handshake (deadline 6s)
W2C: foreign call RETURNING (cause=deadline, blocked 6000ms)
W2-B: observed A's entry signal; starting real GC rounds t=1795023513.535334
...
W2-B: calling the C release handshake FROM SCHEME after round 1 (real collection completed) t=1795023513.536965
...
W2: observed state: release-cause=deadline rounds-during-block=0 rounds-after=3 handshake-called-from-scheme=#t capi-handshake-calls=1 handshake-during-block=0 blocked-ms=6000 witness-object=(last-round=3 round-count=3)
W2-QUALIFY-VERDICT: FAIL (blocking unqualified on this build: release-cause=deadline, rounds-during-block=0, handshake-during-block=0; B was synchronized and provably executing BEFORE A entered C, but completed all rounds only AFTER the foreign call returned — the handshake was called from Scheme only after B's real collections, which on this build can only happen after C returned; astra §2 'actual collection and another Scheme thread's progress while C remains blocked' is not satisfied)
### exit=0
### w2-outcome: run completed (verdict derived from observed state; see the W2-QUALIFY-VERDICT line)
```

  This is the reusable success/failure discriminator the P1a witness lacked:
  on a build where the contender CAN run during the block, the same witness
  requires `release-cause=handshake`, `rounds-during-block>=1` and
  `handshake-during-block=1` to print PASS — and per the Q2 amendment, a
  hypothetical multithreaded-VMs build would instead be expected to HANG in
  B's `##gc` (the all-processor barrier cannot complete while A's processor
  is inside the synchronous foreign call), which the watchdog records as
  exit 124 = failure. Internal-consistency guards (round totals, one
  handshake call, witness-object slots) turn any incoherent observation into
  `FAIL-INCONSISTENT` with a nonzero exit.

- Blocked (the P1a variant, kept as a documented starvation demonstration):
  B is started only AFTER A enters the blocking call; the verdict is derived
  from the same counters:

```
W2C: foreign call RETURNING (cause=deadline, blocked 6000ms)
W2-A: foreign call returned t=1795023519.576507 release-cause=deadline
W2-B: executing (started AFTER A entered — starvation demo) t=1795023519.576941
...
W2: observed state: rounds-during-block=0 rounds-after=3 blocked-ms=6000 witness-object=(last-round=3 round-count=3)
W2-STARVATION-DEMO-VERDICT: STARVATION-DEMONSTRATED (derived: 0 rounds started while the C fixture's in-block flag was set; blocked 6000ms — the whole deadline; every W2-B line above appears after 'W2C: foreign call RETURNING'; the qualification witness is the w2-qualify mode, not this diagnostic)
### exit=0
```

The ~6.0 s block with zero B progress is the starvation measured directly.
A Scheme-internal watchdog cannot fire in this state (the whole VM is
frozen), which is why every run is wrapped in the external `watchdog.sh`;
the C-side deadline produces the structured evidence, and `exit=0` is the
witness program's own exit after deriving its verdict — not a pass of the
gate (the verdict line says FAIL for the capability).

---

## Q4 — Rules for a previously unknown pthread entering Scheme

**Answer: there is NO documented protocol, and no mechanism that would make
entry LEGITIMATE. p1a-r2 amendment (review finding F1): the P1a claim that
naive entry "deterministically SIGSEGVs" was an artifact of a malformed
fixture — the P1a c-define exports declared `(int)` for two-formal procedures,
so the generated C converted ONE argument for a procedure requiring TWO and
the 3/3 crashes reproduced that malformed entry, not foreign-thread entry
itself. With the repaired two-argument entries the observed outcome on the
provisioned build is: serialized entry while the owner thread is parked
(pthread_join or a cfun frame) SURVIVES with correct values (3/3 runs) — the
same undocumented serialized-reuse artifact as W4-M4 — while CONCURRENT entry
while the owner thread is actively running Scheme crashes with fatal signals
(exit 139/138 across all runs). Survival is never qualification: no protocol
exists, nothing roots the worker's context, and the repair withdrew the
"foreign-entry-impossible" experimental inference.**

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
  `___current_vm_resize` clamps to 1 (lib/setup.c:1169-1170). The generated
  c-define entry macros require a current processor state with no ownership
  check (`___processor_state ___ps=___PSTATE;` — gambit.h:10028-10044), so a
  foreign pthread that calls a c-define'd function silently shares the
  primordial's pstate.
- Implementation tier (the mechanism — gap justified: the docs do not
  describe what happens): the C→Scheme entry `___call` arms a setjmp catcher
  ON THE CALLING THREAD'S C STACK (`___BEGIN_TRY` sets
  `___ps->catcher = &___jbuf` with `___jbuf` a local — gambit.h:9966-9971)
  and, on the Scheme→C return, the return-to-C handler jumps back "inside
  ___call" with `___throw_error(___UNWIND_C_STACK)` (lib/_kernel.c:11772).
  The unwind target is the SHARED pstate's catcher chain, and the
  cross-processor guard in that handler is compiled out under
  `___SINGLE_THREADED_VMS` (lib/_kernel.c:11742-11755). After `___setup`
  returns on the primordial, the outermost catcher of that chain is NULL
  (`___setup_pstate` initializes `___ps->catcher = 0`, lib/setup.c:4755;
  `___run`'s catcher is a stack local restored on return,
  lib/setup.c:3389-3415). (p1a-r2 correction: the P1a text attributed the
  W3 phase1 macOS crash report — SIGSEGV in `longjmp` inside `___call` — to
  this mechanism; that attribution is WITHDRAWN per review finding F1,
  because the P1a phase1 fixture was malformed — a one-argument entry for a
  two-formal procedure — so that crash is not evidence about the mechanism.
  The repaired witness's CONCURRENT phase still crashes with fatal signals,
  which remains consistent with two threads sharing one pstate, but no fresh
  crash report was captured for attribution in this revision.)

**Witness W3 (foreign-thread entry, p1a-r2) — owner-thread control PASS;
serialized owner-parked shapes survive (REFUSAL-NOT-REPRODUCED — 3/3 across
repetitions for each shape, and in each recorded run); concurrent entry
crashes (UNSAFE-ENTRY-REPRODUCED, fatal 139 in both recorded runs and 3/3
across repetitions).**
`p1a/witnesses/w3-fthread.c` + `w3-server.scm` (the manual's documented
"Scheme server" build pattern, tests/makefile.in:166); outputs
`results/w3-control.out`, `results/w3-phase1.out`, `w3-phase1-nobeat.out`,
`w3-phase2-run1.out`, `w3-phase2-run2.out`, `w3-phase3.out`.

p1a-r2 repairs (review finding F1): BOTH add entries now declare `(int int)`
matching their two Scheme formals — the P1a fixtures declared `(int)`, so the
generated C converted ONE argument for two-formal procedures and the 3/3
SIGSEGVs reproduced a malformed entry fixture; a third same-class defect was
also fixed (`scheme_w3_phase3` declared `(int)` against zero formals, called
with no arguments by the C fixture — now `()`/`___NARGS 0`). The Makefile
regenerates with `gsc -keep-temp` and VERIFIES the generated C shows two C
arguments and `___NARGS 2` for both add entries (and `___NARGS 0` for
phase3) BEFORE any run — `VERIFY-W3-C: OK`. An owner-thread control runs
inside EVERY mode before any foreign-thread phase; a wrong value aborts the
run. Verdict semantics are the reviewer-mandated nondeterminism caveat:
fatal exits (70, 134, 138, 139) are all the documented refusal-failure —
never a success — and survival is REFUSAL-NOT-REPRODUCED, also never a
success.

- control — the Gambit thread that ran `___setup` drives the SAME c-define
  entries the worker will use: **PASS with exact values**:

```
W3-CONTROL: scheme_w3_add(20,22) = 42 (expected 42)
W3-CONTROL: scheme_w3_add_alloc(50,22) = 1072 (expected 1072)
W3-CONTROL: scheme_w3_gc_rounds(2) = 2 (expected 2; real collections on the owner thread)
W3-CONTROL-VERDICT: PASS (owner Gambit thread drives the same c-define entries with correct values before any foreign-thread phase)
### exit=0
### w3-outcome: CONTROL-PASS (owner-thread callbacks through the same c-define entries succeeded before any foreign-thread phase)
```

- phase1 — raw pthread calls the (now two-argument) c-define'd Scheme
  procedures after `___setup`, primordial parked in `pthread_join`
  (serialized, heartbeat on): **the worker SURVIVED with correct values in
  the recorded run (and 3/3 across repetitions), driving 3 real collections
  from the foreign pthread** — the same undocumented serialized-reuse
  artifact as W4-M4, recorded as REFUSAL-NOT-REPRODUCED, never
  qualification. (With the P1a malformed one-argument entry this phase
  SIGSEGV'd 3/3 — that crash attribution is withdrawn.)

```
W3-CONTROL-VERDICT: PASS (owner Gambit thread drives the same c-define entries with correct values before any foreign-thread phase)
W3-PHASE1: spawning raw pthread (primordial will park in pthread_join)
W3-PHASE1: heartbeat interval = 0.010000
W3-WORKER: scheme_w3_add_alloc(50,22) = 1072 (expected 1072)
W3-WORKER: scheme_w3_add(20,22) = 42
W3-WORKER: scheme_w3_add(21,22) = 43
W3-WORKER: scheme_w3_add(22,22) = 44
W3-WORKER: drove 3 real gc rounds (runtime *** GC: reports below with -:d5)
W3-WORKER: final scheme_w3_add(1,1) = 2
W3-PHASE1-VERDICT: REFUSAL-NOT-REPRODUCED (worker survived with correct values — undocumented serialized reuse of the single pstate; a nondeterminism caveat, NEVER qualification of foreign-thread entry)
### exit=0
### w3-outcome: REFUSAL-NOT-REPRODUCED (worker survived — undocumented serialized reuse of the single pstate, never qualification of foreign-thread entry)
```

- phase1-nobeat — same serialized shape with the heartbeat DISABLED via the
  undocumented `___set_heartbeat_interval(0)` (lib/os_time.c:937-948): the
  recorded run also survived (`REFUSAL-NOT-REPRODUCED`, 3/3 across
  repetitions) — the heartbeat is not the discriminator.

- phase2 — concurrent entry (worker calls Scheme WHILE the primordial thread
  runs an allocating Scheme loop): **UNSAFE-ENTRY-REPRODUCED — fatal exit 139
  (SIGSEGV) in both recorded runs and 3/3 across repetitions (139, 138
  SIGBUS, 139)** — with a VALID two-argument fixture. Two threads on one
  processor state, one Scheme stack chain and one allocator is undefined
  behavior; this is the documented refusal-failure, never a success (exit 70
  observed in the P1a session counts the same):

```
W3-CONTROL-VERDICT: PASS (owner Gambit thread drives the same c-define entries with correct values before any foreign-thread phase)
W3-PHASE2: spawning raw pthread WHILE primordial runs scheme_w3_spin
./watchdog.sh: line 21:  35996 Segmentation fault: 11  "$@"
### exit=139
### w3-outcome: UNSAFE-ENTRY-REPRODUCED (documented refusal-failure: exit 139 = the foreign pthread could not safely enter Scheme; never a success)
```

- phase3 — owner Gambit thread parked inside a cfun (c-lambda) call while the
  worker enters (the shape under which W4-M4's callback survived): **the
  worker SURVIVED with correct values in the recorded run (3/3 across
  repetitions)** — same artifact class as phase1/W4-M4, recorded as
  REFUSAL-NOT-REPRODUCED, never qualification. (The P1a phase3 SIGSEGV'd 1/1
  with the malformed fixture; that attribution is withdrawn.)

**Verdict for the contract row (amended):** the repaired W3 does NOT prove
"unrelated entry cannot be made safe" — that claim is WITHDRAWN (review
finding F1; the P1a crashes were the malformed fixture). What it
establishes on the provisioned build: (a) the same c-define entries behave
correctly on the owner thread (control); (b) CONCURRENT foreign-thread entry
while the owner runs Scheme is unsafe (fatal 139/138 with a valid fixture);
(c) serialized owner-parked reuse survives but is an undocumented artifact
with no protocol behind it — nothing roots the worker's context, and Q2/Q3
identify no release/claim mechanism. The refusal row for callbacks from an
unrelated C thread stays NO-GO on protocol grounds, not on the withdrawn
experimental inference.

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
     lib/_kernel.c:11741-11772). The TODO at lib/c_intf.c:6530
     ("proc_or_false may have been GC'd at this point! protect it some way")
     documents the sharp edge the macro family papers over. (p1a-r2
     correction, review finding F5: previously cited as :6528-6529.)
   - Scheme→C: the lifetime rule is that pointers to Scheme objects passed
     into C are valid only for the call's duration; C must not keep them.
     The manual documents the conversion-temporary contract ("The temporary
     memory allocated from the C heap for the conversion of the arguments
     and result will be reclaimed whether there is an error or not", txi
     §c-lambda, gambit.txi:19305-19307) and the `___AT_END` hook as the
     cleanup point after the result is converted (gambit.txi:19328-19332).
     (p1a-r2 correction, review finding F5: previously cited as
     19296-19300 and 19313-19319.)
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

**Witness W1 (errno-atomicity, PASS — p1a-r2)** — `p1a/witnesses/w1-errno.scm`
+ `w1-fixture.c`; output `results/w1.out`. Exercises the conversion-boundary
obligations above (the astra essential sequence) plus nesting (the
documented one-thread C→Scheme→C→Scheme) and two-thread interleaving.
p1a-r2 repairs (review finding F2): EVERY shim now captures
`int saved = errno;` IMMEDIATELY after the target call, before ANY
malloc/conversion/cleanup/re-entry (the P1a shims read errno after malloc);
shapes A/C preserve the TARGET's real errno (the targets set EAGAIN/EACCES
themselves, like real syscalls) instead of manufacturing it after the fact;
and the intervening-clobber negative controls make capture order
load-bearing — shape F writes `errno = 4242` BETWEEN the target call and the
use of the captured value (the immediate capture must defeat it) while shape
G is a deliberately WRONG shim that captures AFTER the clobber (the witness
asserts it reports the clobbered value, proving the assertions can
distinguish capture order at all):

```
### cmd: ./watchdog.sh 120 ./w1.exe
=== W1 errno-atomicity witness (p1a-r2: capture-before-allocation + negative controls) ===
EAGAIN=35 EACCES=13 EIO=5 intervening-clobber=4242
W1-NEGATIVE-CONTROL: OK (shape G captured AFTER the intervening clobber and reported it — the assertions distinguish capture order, so the immediate-capture shapes are load-bearing)
W1-CHECKS=5901
W1-FAILURES=0
W1-VERDICT: PASS (every shim captured (result,errno) immediately after the target, before ANY allocation/conversion/re-entry: shapes A/C preserve the target's own errno, shape B preserves errno=42 on success, shape E captures before the nested Scheme re-entry, shape F defeats an intervening clobber written between target and capture; shape G proves the assertions distinguish capture order; the ___AT_END clobber (shape D) and the two-thread interleave add conversion-boundary and scheduling pressure)
### exit=0
```

Mechanisms exercised: negative control FIRST (shape G must report the
clobber — an insensitive harness fails here); typed C shims capturing
(result, errno) immediately after the target (shapes A/B/C, 200 each);
success preserving errno=42 (no normalization); deliberate post-capture
clobber (errno=7777) in every shim; intervening-clobber defeated (shape F,
200); late-capture negative control (shape G, 100); `___AT_END` clobber
AFTER result conversion (shape D, 100); nested re-entry capture (shape E,
100 — outer pair captured before the C→Scheme→C round trip must still be
(−3, EIO)); 2 Scheme threads × 400 interleaved iterations × 6 shapes each (a
global "last errno" cell, a deferred re-read, or a capture-after-malloc
order fails these; per-invocation capture-before-allocation passes).
5901/5901 assertions correct on macOS arm64.

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
  pstate). The p1a-r2 W3 repair CONFIRMS this artifact class rather than
  contrasting with it: the repaired W3 phase3 and phase1 — same owner-parked
  shapes, now with VALID two-argument entries — also survive 3/3 (the P1a
  W3 crashes that suggested a discriminating frame state were the malformed
  one-argument fixture, review finding F1). Survival remains an undocumented
  artifact, not a contract: no protocol exists (Q4), nothing roots the
  worker's context, and concurrent entry (W3 phase2) still crashes with
  fatal signals. P1b must NOT advertise this mode; the refusal row stays.
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
4. **errno observation:** W1 (p1a-r2) proves the errno pair can be captured
   atomically in typed shims on this build with capture BEFORE any
   allocation, conversion or re-entry, including an intervening-clobber
   negative control that the immediate capture defeats and a deliberately
   late-capturing control that the assertions detect (macOS errno values:
   EAGAIN=35, EACCES=13, EIO=5; the witness probes them at runtime so the
   assertions hold on Linux too).
5. **Watchdog requirement is structural:** a blocked foreign call freezes the
   whole VM (W2 blocked), so no in-process timeout can ever fire — every
   jolt-level witness driver that calls foreign code must be watchdogged
   externally (the Makefile does this for every run).

---

## GO / NO-GO recommendation for P1b (astra §5 criteria, verbatim application)

**VERDICT-AMENDED (p1a-r2, adopting the reviewer's amended verdict): NO-GO
for P2/P3 on the provisioned build CONFIRMED; a multithreaded 4.9.8
configuration remains unqualified and does not clear that verdict; the
"foreign-entry-impossible" claim is WITHDRAWN; PARTIAL-GO permits bounded
P1b work only as each capability is independently qualified.** Applying
astra's exact wording:

- "**NO-GO for P2/P3:** collection cannot complete while C is blocked" —
  ESTABLISHED by the repaired W2 on the pinned runtime: the qualify witness
  synchronizes both participants before the block, B is proven executing,
  the release handshake IS called from Scheme after B's real collections,
  and the OBSERVED state is still `release-cause=deadline`,
  `rounds-during-block=0`, `handshake-during-block=0` over the 6 s blocked
  window. This criterion alone forces NO-GO for P2/P3, because "P2 remains
  Chez-only if P1 blocking is unqualified" and "Removing `:blocking` from
  crypto calls is not an acceptable workaround".
- "**unrelated C-thread entry cannot be made safe where required**" — the
  P1a claim that W3 PROVED this is WITHDRAWN (review finding F1: the P1a
  fixture exported one argument to two-formal procedures, so its 3/3 crashes
  reproduced a malformed entry fixture). The refusal row instead rests on:
  no documented foreign-pthread attach protocol for any 4.9.8 configuration
  (Q4), no release/claim mechanism (Q2, configuration-scoped), and the
  repaired W3's fresh evidence — concurrent foreign-thread entry while the
  owner runs Scheme crashes with fatal signals (139/138, valid fixture,
  3/3), while serialized owner-parked survival is an undocumented artifact
  that nothing makes legitimate (no rooted context, no membership, no TLS
  binding). That supports NO-GO without the withdrawn inference.
- "**exact runtime ownership rules remain unknown**" — the provisioned
  build's rules are known (one pstate, one OS thread, no release/claim, no
  foreign-thread protocol), which closes the audit for that configuration;
  the multiple-threaded-VMs/SMP variants carry materially different TLS,
  startup, scheduling and barrier paths (Q2 amendment) that remain
  UNQUALIFIED — configuration-only adoption does not close the gate (review
  Q3/Q4).
- The worker-pool escape is pre-ruled by astra ("A worker pool is **not** a
  transparent generic fallback ... cannot masquerade as unrestricted
  `sa-foreign-procedure-blocking`"). The p1a-r2 evidence sharpens it: a
  foreign pthread CAN survive serialized owner-parked reuse (W3 phase1/3,
  W4-M4 — artifact), but there is no protocol making that legitimate, and
  concurrent use crashes — so a pool would still have to run calls on the
  SAME (only) Scheme-executing OS thread, which is precisely the
  serialization that defeats blocking.
- **Partial GO (astra's fallback ruling):** "memory, loading, ordinary calls,
  and errno may land independently when qualified." W1 (errno, repaired:
  capture-before-allocation with negative controls) PASSes; the ordinary-call
  tier is exercised throughout W1/W2-control/W3-control/W4-M1/M2 via
  c-lambda/c-define with correct results; the memory/loader tier was not
  separately qualified here (dlopen/sa-foreign-alloc are NOT part of P1a's
  witness list — they are P1b implementation targets; nothing observed
  contradicts them, but they are unqualified by this audit). This is
  authorization to pursue a bounded P1b, not acceptance of the complete
  basic tier.

**Bottom line (configuration-scoped):** the pinned Gambit 4.9.8 (mise default
configure, `--enable-single-host`, `___SINGLE_THREADED_VMS`, 1 processor) can
support the jolt FFI tier's basic surface (typed shims with atomic
capture-before-allocation errno capture, ordinary non-blocking calls,
callbacks on the owning thread, real `(##gc)`), but it CANNOT support
`sa-foreign-procedure-blocking`'s contract (other threads' GC must proceed
while C is blocked) and callbacks from unrelated C threads have no protocol
that would make them legitimate. Per astra's fallback ruling, those
constructors must keep raising their message-carrying unsupported errors and
`CONTRACT.txt`/`TARGET-CONTRACT.md` must describe the partial mode. The next
decision on those rows is an explicit Gambit upgrade or runtime patch through
the upgrade gate; adopting a differently-configured 4.9.8 build is not itself
a runtime patch but reopens configuration-specific P1 evidence and requires
explicit provisioning and qualification (including the all-processor GC
barrier obstacle described in the Q2 amendment).

### Reproducing

```
cd ~/workspace/jolt-ffi-p1/p1a/witnesses
make clean && make all        # builds every witness under build/ (byte-identical
                              # source copies), runs each under build/watchdog.sh,
                              # records build/results/*.out (one file per run,
                              # ### exit= plus an outcome-classification line),
                              # then VERIFYs every expected verdict marker —
                              # a missing or wrong marker fails the build
make record-tracked           # AFTER a full PASS-verified run: copies the repaired
                              # witnesses' fresh outputs into the tracked results/
```

The W3 build additionally regenerates with `gsc -keep-temp` and VERIFIES the
generated C (`VERIFY-W3-C: OK`): both add entries must declare two C
arguments and carry `___NARGS 2`, and `scheme_w3_phase3` must carry
`___NARGS 0` — enforced BEFORE any run (review finding F1).

Witness sources: `w0-config.scm`, `w1-errno.scm` + `w1-fixture.c`,
`w2-blocking.scm` + `w2-fixture.c`, `w3-fthread.c` + `w3-server.scm`,
`w4-callables.scm` + `w4-fixture.c`, `watchdog.sh`, `Makefile`. Recorded
verbatim outputs: `results/*.out` (tracked; the p1a-r2 refresh covers the
repaired witnesses — w1, w2-control/qualify/blocked, w3-control + all w3
phases — while `results/w0.out` and `results/w4-*.out` remain the P1a
recordings of unchanged sources; fresh equivalents of those also live in
`build/results/`). All build artifacts stay under `build/`; `make clean`
never touches the tracked `results/`. Toolchain:
`/Users/sto/.local/share/mise/installs/gambit/4.9.8/bin/gsc`
(never bare `gsc`; that is Ghostscript).

### Open risks / limitations of this audit

- Witnesses ran on macOS arm64 (darwin 25.6.0). astra requires both macOS
  arm64 and Linux x86_64 for the pinned rows; the Linux leg is unexecuted in
  P1a. The structural evidence (configured header, compiled-out resize,
  shared-pstate catcher) is platform-independent, but the crash signatures
  (W3 phase2 fatal 139/138; exit-70 in the P1a session) should be re-recorded
  on Linux before any document update that cites them.
- W3 phase outcomes are nondeterministic by nature and the witness now says
  so explicitly: the recorded outputs are one sample of a distribution (the
  repaired serialized owner-parked shapes survived 3/3 across repetitions
  and 2/2 recorded; concurrent entry crashed 3/3 across repetitions and 2/2
  recorded, with 139/138 fatal signals). Survival is recorded as
  REFUSAL-NOT-REPRODUCED — a caveat, never a success.
- The out-of-tree differently-configured Gambit build (p1a/gambit-builds/)
  was NOT built in P1a or p1a-r2: the verdicts above are scoped to the
  provisioned configuration. A differently-configured build WOULD change the
  evidence base — configuration-only adoption reopens configuration-specific
  P1 evidence (review Q3/Q4); the Q2 amendment's barrier analysis for the
  multiple-threaded-VMs variant is source-level, not an executed result.
- p1a-r2 kept the P1a crash report (SIGSEGV in `longjmp` via `___call`) out
  of the evidence chain: it was produced by the malformed one-argument
  fixture (review finding F1). No fresh crash report was captured for the
  repaired phase2 crash; capturing one is cheap follow-up work if attribution
  is ever needed.
- `make clean` regenerates everything under build/; committed sources only
  (no binaries, no generated .c files).
