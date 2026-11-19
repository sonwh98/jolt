# P1b-ci: emitted heads, installation-local provenance, CI log audit

Completed-GMT: 2026-11-19 13:04:28 GMT
Completed-Local: 2026-11-19 20:04:28 ICT (+07)
Coding-Agent: Codex
Session-ID: 01a1f1f9-2d2b-71a2-b88a-1675b81dd975
Base: gambit-ffi-p1b @ 3ecd20cc. No push performed.

| Finding | Status | Implementation/evidence |
| --- | --- | --- |
| F-A: emitted-head hygiene | FIXED | `jolt-core/jolt/backend_scheme/names.clj:180` registers the two actual Gambit public helper heads. `ffi.clj:646,784` rewords parenthesized refusal prose instead of reserving fake procedure names `per-call` and `ftype`. Both compiler seeds were reminted. `Makefile:2193` includes `emittedheads` in `gambitffi`. |
| F-B: machine-specific toolchain pins | FIXED | `host/gambit/ffi/toolchain.py:42,64` records/compares the current installation under ignored build output. `verify-digests.sh:4` always checks committed bridge inputs first. `make-digests.sh:6` no longer indexes machine-local records; the two obsolete committed binary manifests are removed. `.github/workflows/tests.yml:43` explicitly records each runner's fresh/cached /opt/gambit installation before gates. |
| F-C: remaining Android rows | CONFIRMED; related skip regression FIXED | Retrieved run 44509339647 logs: Android shard 2's only failing gate was emittedheads; loader smoke passed and 71 checks had zero failures. Those are Chez rows, not Gambit qualification. Android shard 3 had no Gambit/prefix: its error was verifier usage, not a bionic binary mismatch. `Makefile:1946` restores the adapter gate's existing absent-Gambit skip before native bridge prerequisites. This also fixes Linux shard 4's makefilesmoke failure. Explicit gambitffi targets retain mandatory install/provenance checks. |

## Provenance contract

Committed `DIGESTS.txt` still checks all 13 in-repo bridge/generated/helper
inputs, including the verification/recording implementation; generator output
is checked separately. Recording a toolchain never changes this index.

`build/gambit-ffi/provenance/TOOLCHAIN.<platform>.json` records a format version,
computed platform, resolved install path, complete Gambit 4.9.8 `gsi -v` string,
configure-summary SHA256, and seven installed-file SHA256 values. The summary
is exactly the trailing quoted `./configure ...` field printed by `gsi -v`,
UTF-8 without surrounding double quotes or final newline. JSON is deterministic
and contains no additional recording timestamp. Unsupported version/configure
formats fail explicitly. Missing or stale local records fail with the exact
record command; verification never refreshes them. A legitimate fresh CI build
is accepted after explicitly recording that installation, irrespective of
developer-machine binary bytes. Subsequent changes to its bytes or metadata
refuse until intentionally re-recorded.

Platform keys accept Darwin/Linux on arm64/x86_64; aarch64 maps to arm64 and
amd64 to x86_64. Android/bionic's Linux/aarch64 uname selects linux-arm64;
there is no requirement to commit a platform manifest. Other keys refuse with
an explicit supported-platform message. This tests selector/record behavior,
not Android native ABI execution. Current Termux CI installs Chez only.

For an installed Linux Gambit, from the checkout root:

```sh
GAMBIT_PREFIX="$HOME/.local/share/mise/installs/gambit/4.9.8"
sh host/gambit/ffi/watchdog.sh 60 sh host/gambit/ffi/record-toolchain.sh "$GAMBIT_PREFIX"
make gambitffi-verify-digests GAMBIT_PREFIX="$GAMBIT_PREFIX"
```

The record step prints the computed platform and selected absolute build-record
path, then `gambitffi: recorded local toolchain provenance (7 inputs); source
digests unchanged`. Verification prints the same selection and `gambitffi:
local toolchain provenance verified (7 inputs)`. Source verification runs first.
The GitHub setup step uses the same watchdogged record command with /opt/gambit.

## Local verification

All commands ran in the authorized worktree with explicit native prefixes,
worktree-local TMPDIR and external process-group watchdogs. No downloads or
runtime-source modifications were needed. Logs remain under ignored
`build/p1b-ci/`.

1. After F-A: `host/chez/remint.sh` with JOLT_CHEZ set explicitly, watchdog 360s:
   converged after two passes and cross-minted the Gambit seed; exit 0.
2. After F-A: `make gambitffi emittedheads`, watchdog 480s: exit 0.
   `OK: 249 emitted heads, none shadowable (16 allowed)`; ABI 79/0, public 44/0,
   errno 9/0, load-failure 14/0; aggregate PASS.
3. Provenance: `python3 host/gambit/ffi/test-toolchain.py`, watchdog 90s:
   12 tests, all OK. Includes fresh-install acceptance after recording,
   missing/stale/wrong-field/input/configuration/path refusals, deterministic
   re-recording, incomplete-install atomicity, bionic uname normalization,
   unsupported-host/version refusal, and actual shell entry-point integration.
   The integration test confirms recording preserves committed source pins and
   source corruption fails even when local provenance is absent.
4. Recorded this macOS install's local provenance with watchdog 60s, exit 0.
5. Final regression, watchdog 900s: exit 0 for the exact target list below:

```sh
env JOLT_REQUIRE_GAMBIT=1 \
  JOLT_CHEZ=/Users/sto/.local/share/mise/installs/chezscheme/10.4.1/bin/scheme \
  make CHEZ=/Users/sto/.local/share/mise/installs/chezscheme/10.4.1/bin/scheme \
  GAMBIT_PREFIX=/Users/sto/.local/share/mise/installs/gambit/4.9.8 \
  TMPDIR="$PWD/build/p1b-ci/tmp" \
  gambitffi emittedheads makefilesmoke gambitcheck gambitkernel gambiteval \
  gambitseedcheck gambitgencheck gambittwins adaptercheck gambitvars gambitstatics
```

Final receipts: emittedheads 249/16, ABI 79/0, public 44/0, errno 9/0,
loader 14/0; gambitffi PASS. makefilesmoke PASS (including missing-Gambit skip
and mandatory-Gambit refusal). gambitcheck/kernel/eval: zero failures, PASS.
Seed/generated records current; twins 13 matched; adapter 149 names satisfied;
vars 4 allowlisted; statics 11 allowlisted. `git diff --check` passed.

## CI audit limits and next run

Read-only API/log retrieval used the fork explicitly:
`gh run view 44509339647 -R sonwh98/jolt --json jobs,conclusion,url` and
`--log-failed`, each watchdogged. Android shard 1 succeeded. Android shard 2's
only make target error was emittedheads; shard 3's only target error was
gambitffi-verify-digests with an empty GAMBIT_PREFIX. Linux shard 1 reported
six installed-file digest mismatches; shard 3 emittedheads; shard 4
makefilesmoke's no-Gambit path. All these source causes are addressed here.

The same run also had a Windows package-install checksum/transaction failure,
before its tests, and a cancelled macOS job. That infrastructure failure is
not changed here and this report does not claim the whole prior CI run green.
No Linux/Android native execution or new consumer/tier qualification is claimed.
The orchestrator must push and rerun the CI matrix, plus its independent Linux
native leg after recording that installation. Existing stage-1 refusals remain.

Gate summary: macOS gambitffi + emittedheads PASS after each fix; final full
local matrix PASS; provenance 12/12 PASS; CI rerun pending orchestrator push.
