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

DONE
