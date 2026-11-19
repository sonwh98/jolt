Completed-GMT: 2026-11-19 10:27:04 GMT
Completed-Local: 2026-11-19 17:27:04 ICT (+07)
Coding-Agent: Codex
Session-ID: 01a1f1f9-2d2b-71a2-b88a-1675b81dd975
Created-GMT: 2026-11-19 10:17:41 GMT
Role: VM Runtime Engineer — platform-qualified provenance fix
Base: 1e5e6331 on gambit-ffi-p1b

The previous manifest pinned a macOS installation globally. The new selector
computes the running OS/architecture via os.uname(), normalizes the key, and
chooses only `host/gambit/ffi/TOOLCHAIN.<platform>.sha256`. The existing seven
Darwin digests are preserved exactly in `TOOLCHAIN.darwin-arm64.sha256`; only
the filename and explicit version/platform header changed. No Linux pins were
invented or recorded on this machine.

| Surface | Change |
|---|---|
| toolchain.py:19/29 | Host-derived platform selection; prints platform and selected manifest |
| toolchain.py:51/93 | Fail-closed header, exact seven-path schema and installed-file digest checks; no fallback or auto-recording |
| record-toolchain.sh:3 / toolchain.py:73 | Explicit deterministic recorder; hashes all inputs first, writes atomically, refreshes the source/manifest index |
| make-digests.sh:6 | Pins verifier/recorder implementation and every platform manifest in C-locale order; --check rejects missing or unindexed catalog entries |
| verify-digests.sh:5 / Makefile:2087 | One full verification path with explicit prefix (or GAMBIT_PREFIX environment for the script); source and toolchain checks both required |
| README.md:45/69 | Manifest format, recording/review process and exact Linux commands |

The manifest header is exactly:

```text
# joltffi toolchain manifest v1
# platform: linux-x86_64
```

Seven ordered SHA256 rows follow, naming bin/gsi, bin/gsc, bin/gambuild-C,
include/gambit.h, lib/libgambit.a, lib/libgambitgsi.a, lib/libgambitgsc.a.
There are no timestamps or absolute installation paths. Architecture aliases
amd64 and aarch64 normalize to x86_64 and arm64. There is no CLI/environment
override that can select another platform's manifest. Unknown/unrecorded
platforms fail closed. A Darwin manifest renamed to Linux fails its header
check even before binary hashes are compared.

The explicit record command intentionally updates trust inputs: operators must
review/commit the manifest and DIGESTS.txt diff, then run qualification. Verify
never records or refreshes pins. An interrupted/missing-input recording cannot
leave a partial manifest. Catalog verification requires the exact pinned file
set as well as matching hashes, so adding an unindexed manifest fails too.

Linux orchestrator commands, after bringing this commit to shiva:

```sh
cd "$HOME/ci/jolt-ffi-linux"
sh host/gambit/ffi/record-toolchain.sh "$HOME/.local/share/mise/installs/gambit/4.9.8"
make gambitffi-verify-digests GAMBIT_PREFIX="$HOME/.local/share/mise/installs/gambit/4.9.8"
```

The recorder must print:

```text
gambitffi: platform=linux-x86_64 manifest=host/gambit/ffi/TOOLCHAIN.linux-x86_64.sha256
gambitffi: recorded 7 toolchain inputs
gambitffi: refreshed host/gambit/ffi/DIGESTS.txt
```

Verification must print the same selected key/file, OK for all seven installed
inputs, `gambitffi: toolchain verified (7 inputs)`, and successful source/index
checks. Until the real Linux manifest is recorded, Linux verification must
fail for that missing manifest. Recording it also refreshes DIGESTS.txt; no
second manual digest command is needed.

Validation on this macOS arm64 host (all external watchdogs, logs retained in
`evidence/platform-pins/`):

- Ten standard-library unit/integration checks passed (120s watchdog). Linux
  host metadata and install files in these checks are synthetic fixtures,
  not Linux execution or qualification. They exercise acceptance of an
  explicitly recorded Linux manifest; rejection of missing Linux pins despite
  existing Darwin pins; wrong header; changed binary; missing/duplicate/extra
  rows; unknown/invalid platform; deterministic content-only recording;
  no replacement after a missing input; and unindexed manifest rejection.
- Original Darwin pin comparison passed (15s watchdog): all seven old digests
  preserved, not replaced with different pins.
- `make gambitffi` passed (300s watchdog, JOLT_REQUIRE_GAMBIT=1), selecting the
  Darwin manifest and checking every source/manifest digest before builds.

```text
gambitffi: platform=darwin-arm64 manifest=host/gambit/ffi/TOOLCHAIN.darwin-arm64.sha256
gambitffi: toolchain verified (7 inputs)
gambitffi-abi: 78 check(s), 0 failure(s)
gambitffi-public: 44 check(s), 0 failure(s)
gambitffi-errno-check: 9 check(s), 0 failure(s)
gambitffi-load-failure-smoke: 14 check(s), 0 failure(s)
gambitffi: PASS — all stage-1 qualified-tier gates green
```

No Linux runtime, ABI or consumer qualification is claimed. The orchestrator
records actual shiva pins and reruns its Linux matrix. A likely next Linux
build issue remains visible in the existing fixture recipes: Darwin-specific
`cc -dynamiclib` flags. This change intentionally addresses provenance only;
those recipes and platform-specific witnesses still need their Linux leg.
All callback/blocking and other stage-1 refusals remain unchanged. No push.

## Linux r2 — platform-conditional fixture link flags

Completed-GMT: 2026-11-19 10:35:29 GMT
Completed-Local: 2026-11-19 17:35:29 ICT (+07)
Coding-Agent: Codex
Session-ID: 01a1f1f9-2d2b-71a2-b88a-1675b81dd975
Created-GMT: 2026-11-19 10:32:05 GMT
Local base: be0710cd. The orchestrator reports Linux pins recorded separately
on shiva in f5920f1f; this fix changes no pin manifests or DIGESTS.txt.

Makefile:2087 selects the fixture link flags from uname -s:

- Darwin: -dynamiclib, preserving the existing complete expanded commands.
- Linux: -shared -fPIC.
- Other host OS names: an explicit unsupported fixture-link platform error
  when the fixture recipe is expanded, without breaking unrelated targets.

All four fixture C link lines use the selector: main fixture (Makefile:2119),
duplicate-symbol fixture (:2128), missing dependency (:2140), and unloadable
fixture (:2141). The audit found no other literal -dynamiclib link command in
Makefile or host/gambit/ffi. Bridge and errno-test compilation continue through
the provisioned gsc driver's native platform settings. Fixture filenames and
paths, source files, options outside the shared-library flags, and all FFI
capability/refusal semantics remain unchanged.

Verification:

```text
Darwin: PASS — all four expanded fixture link commands are byte-identical
Linux plan: PASS — all four fixture commands select -shared -fPIC (no Linux execution)
Unsupported platform: PASS — make refuses with the explicit fixture-link error
gambitffi-abi: 78 check(s), 0 failure(s)
gambitffi-public: 44 check(s), 0 failure(s)
gambitffi-errno-check: 9 check(s), 0 failure(s)
gambitffi-load-failure-smoke: 14 check(s), 0 failure(s)
gambitffi: PASS — all stage-1 qualified-tier gates green
```

Before/after Darwin dry-run plans compare complete command text, including
continuation lines, source paths and output paths. Linux and FreeBSD branches
were simulated through a make variable override in dry-run mode only; these
are link-plan checks, not execution on Linux. The retained checker asserts
four commands, exact Darwin equality, exact Linux substitution, and a nonzero
unsupported-platform status with the intended message. Its watchdog is 90s
(20s per make plan). The macOS make gambitffi regression ran with
JOLT_REQUIRE_GAMBIT=1 under a 300s external watchdog. Raw plans, the checker,
state-derived verdicts and the full native output are in
`evidence/fixture-link-flags/`.

Orchestrator rerun on shiva, after applying this fix to the existing branch
while retaining f5920f1f's Linux manifest and digest-index changes:

```sh
cd "$HOME/ci/jolt-ffi-linux"
mkdir -p build/p1b-linux-r2/tmp
JOLT_REQUIRE_GAMBIT=1 sh host/gambit/ffi/watchdog.sh 600 make \
  gambitffi gambitcheck gambitkernel gambiteval \
  GAMBIT_PREFIX="$HOME/.local/share/mise/installs/gambit/4.9.8" \
  TMPDIR="$PWD/build/p1b-linux-r2/tmp"
```

Use the already configured Linux Chez setting if that lane supplies one.
gambitffi forces all four fixture rebuilds, then runs ABI/public, errno and
loader gates; gambitcheck retains supported-row and refusal assertions. Do not
re-record pins merely to pass a mismatch. Linux execution/ABI qualification is
still the orchestrator's independent leg; only the macOS regression and Linux
link-plan selection were verified here. No push.

## Linux r3 — platform errno accessor and fixture portability

Completed-GMT: 2026-11-19 10:48:09 GMT
Completed-Local: 2026-11-19 17:48:09 ICT (+07)
Coding-Agent: Codex
Session-ID: 01a1f1f9-2d2b-71a2-b88a-1675b81dd975
Created-GMT: 2026-11-19 10:42:35 GMT
Base: 434dc2f9 (includes shiva's f5920f1f Linux provenance pins).

Verified dereference semantics from primary sources:

- [Apple's XNU errno header](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/errno.h)
  declares `extern int * __error(void)` and defines errno by dereferencing its
  result. The installed macOS SDK independently agrees at
  `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sys/errno.h:80–81`.
- [glibc's errno header](https://github.com/bminor/glibc/blob/master/stdlib/errno.h)
  declares `int *__errno_location(void)` and defines errno by dereferencing its
  result; the [implementation](https://github.com/bminor/glibc/blob/master/csu/errno-loc.c)
  returns `&errno`. The [Linux errno manual](https://man7.org/linux/man-pages/man3/errno.3.html)
  describes the slot as a thread-local modifiable int.

Thus both accessors return int*, not a direct int on Darwin, and both need
exactly one int load. The Scheme binding remains the registered `() -> void*`
pointer shape (S20); there is no platform-specific extra pointer level.

Makefile:2090/2093 selects __error for Darwin and __errno_location for Linux in
the existing host-OS branches, passing JOLT_FFI_ERRNO_ACCESSOR to the ABI gate.
Unsupported hosts and missing/unsupported selections refuse explicitly. The
gate's original Darwin by-name path still selects __error with the same
signature and nonzero-pointer assertion.

The fixture's errno-location shape now returns the actual &errno. A new
`joltffi_fx_errno_deref` witness uses the already registered S02 shape
`(void*, size_t) -> int`: it checks location == &errno, presets errno to the
supplied 7777, and immediately loads one int through location in the same C
frame. Wrong addresses return -1 without dereferencing them. This prevents
intervening Scheme allocation/conversion from corrupting a separate preset.
No adapter, bridge, shim registry, native-error capture tier or refusal changed.
Only the changed fixture source digest was refreshed; Darwin and Linux
toolchain manifests and their pins remain unchanged.

Exact Linux expectations:

| Row | Expected |
|---|---|
| Selected process-global symbol | __errno_location |
| Accessor ABI | int * function(void), carried as () -> void* by S20 |
| Accessor result | Nonzero exact address of this native thread's errno |
| Fixture read through that address | 7777 (one int dereference, after preset in the same C call) |

Audit of the FFI directory also corrected the public per-OS library-map witness
to contain both :darwin and :linux keys with the same existing fixture path.
The loader's missing-file predicate compares a lowercase copy of the message
so glibc's capitalization does not fail it; the actual diagnostic remains
unaltered. Shared fixture `.dylib` filenames remain intentional on both hosts.
Other uses of darwin in provenance fixtures are negative tests or explicit
manifest metadata. Common libc symbols strerror/malloc and existing native
loader flag selection remain unchanged.

Validation (watchdogged; raw records in `evidence/errno-accessor/`):

```text
Darwin selector: PASS — __error; all four Darwin fixture link commands remain byte-identical
Linux selector plan: PASS — __errno_location (no Linux execution)
gambitffi-abi: 79 check(s), 0 failure(s)
gambitffi-public: 44 check(s), 0 failure(s)
gambitffi-errno-check: 9 check(s), 0 failure(s)
gambitffi-load-failure-smoke: 14 check(s), 0 failure(s)
gambitffi: PASS — all stage-1 qualified-tier gates green
```

The native macOS regression ran make gambitffi with JOLT_REQUIRE_GAMBIT=1 and
the pinned absolute Gambit/Chez paths under a 300s process-group watchdog.
The selector/unchanged-link-plan checker used a 90s watchdog (20s per make
plan). Linux selection was only a make dry-run, not Linux execution.

After applying this commit on shiva, keep the existing Linux pins and rerun:

```sh
cd "$HOME/ci/jolt-ffi-linux"
mkdir -p build/p1b-linux-r3/tmp
JOLT_REQUIRE_GAMBIT=1 sh host/gambit/ffi/watchdog.sh 600 make \
  gambitffi gambitcheck gambitkernel gambiteval \
  GAMBIT_PREFIX="$HOME/.local/share/mise/installs/gambit/4.9.8" \
  TMPDIR="$PWD/build/p1b-linux-r3/tmp"
```

Use the lane's configured Linux Chez setting if supplied. The ABI output must
pass `by-name errno accessor (__errno_location, s20)` and
`by-name errno accessor __errno_location int* dereference` (expected value 7777).
No Linux execution/ABI or consumer qualification is claimed here. No push.

DONE
