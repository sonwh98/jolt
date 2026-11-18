# P1a-MT build configuration record — multithreaded 4.9.8 (codex experiment)

Experiment lane: P1a-MT (VM Runtime Engineer, glm-5.3-flash), jolt FFI track.
Source pin: Gambit `/Users/sto/workspace/gambit-v4.9.8-src` at commit
`2228e4d163582733a3a67a5efcb22f8ebe93c02b` (git tag `v4.9.8` exactly).
Worktree: `/Users/sto/workspace/jolt-ffi-mt` branch `gambit-ffi-mt` (base `a6852ef8`).
Build tree (out-of-tree, source tree never modified): `p1a-mt/gambit-builds/mt/`.

## 1. Configure invocation (review step 1)

Run from `p1a-mt/gambit-builds/mt` (empty dir), configure from the source tree:

```
/Users/sto/workspace/gambit-v4.9.8-src/configure \
  --enable-single-host \
  --enable-multiple-threaded-vms \
  --enable-smp \
  --enable-max-processors=8
```

- `--enable-single-host` mirrors the provisioned mise build (the mise plugin
  passes exactly `--enable-single-host` and nothing else — review Q3), so the
  ONLY intended variables vs the provisioned build are the three threading
  options. It is code-generation config only, not the cause of single-threaded
  VMs (review Q3).
- `--enable-multiple-threaded-vms` → substitutes `___MULTIPLE_THREADED_VMS`
  into the generated gambit.h (configure.ac:1267-1283; default NO).
- `--enable-smp` → selects the SMP Scheme scheduler (configure.ac:1287-1299;
  `cond-expand` feature `enable-smp` in lib/_thread.scm:9).
- `--enable-max-processors=8` → `___MAX_PROCESSORS 8` (configure.ac:1303-1316;
  the value only takes effect with multiple-threaded-vms; default 64, provisioned
  build is clamped to 1).
- There is NO `--enable-multiprocessor` option in this source (verified).
- Compiler: Apple clang 21.0.0 (clang-2100.4.1.1), target arm64-apple-darwin25.6.0.
  Configure warns single-host+clang is slow; accepted for comparability.
- Build: `make -j8` under a 3600s external watchdog
  (`p1a-mt/gambit-builds/build-watchdog.sh`, log `p1a-mt/gambit-builds/make.log`).
- Platform: macOS 26.6.2 (Darwin 25.6.0), arm64, 8 CPUs (6 performance cores).
- No `make install`; witnesses use this build's own `bin/gsc`.

## 2. Out-of-tree build fixes (applied ONLY inside the build tree)

Gambit 4.9.8's generated makefiles are broken for VPATH builds in two places;
both fixed by writing into the build tree, never the source tree:

1. `dummy-gsc-boot` rule copies `gsc-boot.bat.windows` / `gsc-boot.unix` by
   bare relative path, which resolves to the build root where they don't
   exist. Fix: copied both files from the source root into
   `p1a-mt/gambit-builds/mt/`. (The source is exactly at tag v4.9.8, so the
   dummy gsc-boot path is the correct bootstrap: the repo's precompiled .c
   files are used, gsc-boot is a no-op script.)
2. `GAMBITDIR_INCLUDE = $(srcdirpfx)$(rootfromhere)/include` (and the
   `$(srcdirpfx)$(rootfromhere)/include/gambit.h` dependency lines) resolve to
   the SOURCE include dir, which holds only `gambit.h.in`; the configure-
   generated `gambit.h` lives in the BUILD tree's `include/`. Fix: rewrote
   those to the absolute build include path
   `/Users/sto/workspace/jolt-ffi-mt/p1a-mt/gambit-builds/mt/include` in
   `lib/makefile`, `gsi/makefile`, `gsc/makefile` (+ tests, bench for
   GAMBITDIR_INCLUDE).
3. `_kernel.c:5876` includes `stamp-release.h`, which is a checked-in source
   file in the source `include/` dir that the rewritten `-I` no longer covers.
   Fix: copied `stamp-release.h` from the source `include/` into the build
   tree's `include/` (checked-in release-stamp file, unmodified).
4. The flat runtime link file `_gambit.c` is needed in `~~lib` for `gsc -exe`
   linking; the build tree's `lib/` lacks it. Fix: copied `_gambit.c` (+ the
   symbol table `_gambit#.scm`) from the source `lib/` into the build tree's
   `lib/`.

## 2b. CRITICAL: the prebuilt lib .c files carry the NON-SMP scheduler

The Gambit git repo at tag v4.9.8 ships PRE-COMPILED `lib/*.c` files generated
with the DEFAULT feature set — `lib/_thread.c` in the repo is the NON-SMP
cooperative scheduler (no `##thread-schedule-with-acquired-processor!`).
`configure --enable-smp` only injects `(define-cond-expand-feature|enable-smp|)`
into `PRELUDE_OPT` (lib/makefile.in:173), which is consumed when the .scm
sources are (RE)GENERATED into .c. The stock build's "dummy gsc-boot"
deliberately skips regeneration (gsc-boot.unix), so the resulting runtime has
___MULTIPLE_THREADED_VMS but the NON-SMP scheduler. An intermediate run with
this configuration is recorded in `witnesses/results-nonsmp/` (thread B is
never scheduled on the idle second processor while processor 0 is blocked in
the foreign call — "SMP scheduler" evidence: both threads' pids = 0).

Getting the REAL SMP scheduler required a full bootstrap, all inside the
build tree:

1. A plain bootstrap compiler: `boot/` copy of the pinned source via
   `git archive HEAD` (in-tree configure + `make bootstrap` inside `boot/` —
   the boot copy has no `.git`, so Gambit's own bootstrap path works there).
   NOTE: the top-level `make bootstrap` in the OUT-OF-TREE build cannot be
   used: the `gsc-boot` git check and `boot-most-recent-release-gsc-boot`'s
   `git archive tags/v4.9.8` run inside the build dir, which sits in the
   jolt-ffi-mt worktree, so git resolves the WRONG repository and the chain
   falls back to the dummy compiler.
2. Regenerate the 10 runtime modules (`_kernel _system _num _std _eval
   _module _io _nonstd _thread _repl`) with the boot compiler and the exact
   `PRELUDE_OPT` from the generated `lib/makefile` (features incl.
   `enable-smp` + `##include header.scm`), writing the .c files into the
   BUILD tree with explicit `-o`. NEVER rely on the makefile's .c rules:
   `gsc -c` writes the output NEXT TO THE INPUT, and the rules pass
   `$(srcdirpfx)$*.scm` — a successful regeneration would OVERWRITE THE
   SOURCE TREE's checked-in .c files. (An earlier failed regeneration
   attempt did truncate 6 source .c files before the process died; they
   were restored immediately with `git checkout --` and `git status` was
   re-verified clean at the pin before anything else was run.)
3. Compile the 10 regenerated .c into .o with the build tree's flags — the
   generated `.o` rules hard-code `BUILD_OBJ_INPUT_FILENAMES_PARAM =
   $(srcdirpfx)$*.c` (the SOURCE .c), so make cannot pick up the
   build-local regenerated .c; the compile is done explicitly, then
   `make libgambit.a` re-archives, and gsi/gsc are relinked.

Verification: the regenerated `lib/_thread.c` contains the SMP scheduler
(91 occurrences of `schedule_2d_with_2d_acquired`); the archived
`_thread.o` member matches. The boot compiler itself (`boot/gsc/gsc`) is a
plain default-features build and is used ONLY as the bootstrap/regeneration
compiler (`mt/gsc-boot`).

## 2c. MT runtime startup/heap fragility (side findings recorded verbatim)

- Stock DEFAULT parallelism (0 → 50% of CPUs = 4 here) fails to boot:
  `*** FATAL ERROR -- Heap overflow` (gsi and compiled programs alike).
  Recorded: `witnesses/results/mt-default-parallelism.out`.
- With `-:p2` the default heap boots for small programs; the gsc COMPILER
  needs an explicit min-heap (`min-heap=256M,max-heap=1G` in GSCOPTS).
- Heap GROWTH under -:p2 crashed the compiler deterministically during
  `gsc -exe` of a multi-module program (SIGSEGV in `___H___gvm` on the
  primordial thread, data-abort writing near-NULL while processor 1 idles
  in the scheduler — macOS crash report `gsc-2026-11-19-003559.ips`);
  a large initial min-heap avoids growth and the crash disappears.
  Witnesses therefore run with explicit `min-heap=64M,max-heap=512M`.

## 3. Generated gambit.h threading macros (review step 1 record)

Build tree `p1a-mt/gambit-builds/mt/include/gambit.h`:

- line 1471: `#define ___MULTIPLE_THREADED_VMS` (inside the
  `#ifndef ___SINGLE_THREADED_VMS` / `#ifndef ___MULTIPLE_THREADED_VMS`
  substitution block)
- line 1490: `#define ___MAX_PROCESSORS 8`
- line 1527: `#define ___THREAD_LOCAL_STORAGE_CLASS __thread` — and because a
  static (non-shared) build does not define `___USE_THREAD_LOCAL_STORAGE_GETTER_SETTER`,
  the pstate TLS mechanism is the DIRECT thread-local storage class:
  `___GET_REAL_PSTATE()` reads `___tls_ptr` (gambit.h.in:8689-8692), defined in
  `lib/os_thread.c:802` (`__thread void *___tls_ptr`), bound only by
  `___thread_set_pstate` (os_thread.c:697-708).

Installed provisioned single-threaded build
`~/.local/share/mise/installs/gambit/4.9.8/include/gambit.h` (comparison,
review step 1 requirement — the macros DIFFER as expected):

- `___SINGLE_THREADED_VMS` defined; `___MULTIPLE_THREADED_VMS` not;
  `___MAX_PROCESSORS 1` (clamped by configure.ac:1313-1315).
- pstate access is the direct static address `&___GSTATE->vmstate0.aligned_pstate[0].pstate`
  (gambit.h.in:8607-8612), no TLS at all.

The verbatim header grep for both builds is recorded in
`witnesses/results/build-configure.txt` (regenerated by `make record-build-config`),
and W0MT reports the macros as seen by a program compiled against the MT
headers at runtime (`witnesses/results/w0mt.out`).

## 4. Explicit runtime parallelism (review step 2)

- W0MT / W2MT (gsc-compiled programs): started with the runtime option
  `-:p2` (and `-:p2,d5` when GC reports are wanted) — the gsi/gsc driver
  parses `-:p` into `setup_params.parallelism_level` (lib/main.c:46-49,647).
- W3MT (C-driven server pattern): `setup_params.parallelism_level = 2` set
  explicitly in `w3mt-main.c` before `___setup` — the library-program
  equivalent of `-:p2` (same consumed field; `___setup_params_reset` would
  otherwise default it to 0, setup.c:4908-4912). GC-report verbosity
  (`-:d5` equivalent) via `setup_params.debug_settings = 5 | (1<<4) | (2<<5)`.
- The W0 resize trick `(##current-vm-resize #f 4)` is NOT used anywhere
  (review warning: new processors execute the supplied thunk,
  setup.c:810-835 `start_processor_execution` / setup.c:992-994).

## 5. Library/threading-relevant source facts this experiment relies on

All verified by reading `/Users/sto/workspace/gambit-v4.9.8-src` at the pin:

- `___garbage_collect` (setup.c:1182-1196) issues `OP_GARBAGE_COLLECT` via
  `on_all_processors` (setup.c:1132-1149) which raises `INTR_SYNC_OP` on every
  pstate `0..processor_count-1` (setup.c:95-104 `___raise_interrupt_vmstate`)
  and enters the tree barrier over `___vms->processor_count` participants
  (setup.c:500-580). A processor blocked inside an ordinary synchronous C
  call does not execute `service_sync_op` and is not exempt by the FFI macros
  (gambit.h:10310-10334 save/restore registers only) — no absence/release
  mechanism exists anywhere in the source or headers (grepped: release,
  claim, suspend, detach, absent, leave, reclaim).
- Runtime-created processors: `___current_vm_resize`/startup creates OS
  threads with `start_fn = start_processor_execution` (setup.c:992-996),
  which bind TLS via `___thread_set_pstate` (setup.c:819) and then RUN THE
  SUPPLIED THUNK (setup.c:810-835).
- The primordial processor's OS thread gets its TLS bound inside `___setup`
  (setup.c:6383-6406) — so the documented server pattern's owner thread can
  call c-define'd functions from C on MT builds.
- SMP scheduler: `lib/_thread.scm:9-24` (cond-expand enable-smp branch);
  `##startup-processor!` starts thread scheduling on each processor
  (_thread.scm:3110-3125); cross-processor C-return guard
  `_kernel.c:11743-11755` routes returns via `##c-return-on-other-processor-hook`
  → `##thread-migrate-to!` (_thread.scm, SMP branch).
- GC scan work distribution and live-word accounting iterate ONLY
  `pstates 0..processor_count-1` (mem.c:6269-6280, 6611, 6638, 6678-6702,
  6970) — pstates at array slots >= `processor_count` are invisible to
  collections run by other processors, and never receive interrupts
  (setup.c:95-104).

## 6. Deliverable map

- `p1a-mt/BUILD-CONFIG.md` — this file.
- `p1a-mt/gambit-builds/mt/` — the out-of-tree build tree (NOT committed
  except `build-watchdog.sh` + `make.log` excerpt; the tree itself is
  machine-local, rebuildable from this record).
- `p1a-mt/witnesses/` — witness sources + Makefile + watchdog.sh.
- `p1a-mt/witnesses/results/` — verbatim recorded outputs (`*.out`,
  `build-configure.txt`, `w3mt-generated-signatures.txt`).
- Linux x86_64 leg: PENDING (review step 5 follow-up; not run in this lane).
