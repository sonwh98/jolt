# Phase 2a Guile witnesses — host/guile/witnesses/

Semantics-audit witnesses for the Guile 3.0.11 port (branch `guile/audit`).
Method and recording contract follow the p1a precedent (`p1a/witnesses/`
on `origin/gambit-ffi-p1`): every run goes through the external
`watchdog.sh` (SIGKILL + exit 124 on timeout — a deadlock is a recorded
FAILURE, never a hang), outputs are recorded verbatim under `results/`
with `### cmd:` / `### exit=` lines, and each witness carries a negative
control proving it can fail.

## Running

```sh
cd host/guile/witnesses
sh run-all.sh                 # everything (w7 builds its C fixture itself)
sh run-all.sh w1-reader       # just one
GUILE=/path/to/guile sh run-all.sh
```

(The staging session could not run `chmod +x`; invoke through `sh` or
chmod the two scripts first.) `run-all.sh` verifies each expected
`Wn-VERDICT: PASS` marker and exits nonzero when one is missing or a
witness failed. `results/*.out` are overwritten only by this script.

## Witness map (audit area -> witness)

| witness | area | decides |
|---|---|---|
| w0-platform  | 10 | identity facts, feature set, SRFI-18 presence, gc-stats shape |
| w1-reader    | 1  | case sensitivity, brackets, comments, escapes, numbers, #vu8 |
| w2-threads   | 2  | parameter fork-inheritance, mutex kinds, no lost wakeups, ids |
| w3-escape    | 3  | one-shot escape wrapper (spent flag), dynamic-wind unwind |
| w4-errno     | 4  | errno at the FFI call boundary, dlopen error reporting |
| w5-blocking-gc | 4 | GC completes while a thread sits in a C call |
| w6-gc-pinning | 5 | non-moving stability, foreign memory, gc-stats, after-gc-hook |
| w7-fthread   | 4  | foreign pthread entering Scheme via scm_with_guile (+ raw-entry probe) |
| w8-files     | 6  | realpath, O_EXCL, fcntl locks, dir fsync, mtime-ms, subprocess |
| w9-net       | 6  | UDP, O_NONBLOCK + boundary errno, select poller, suspendable ports |
| w10-compile  | 7  | compile-file/.go, ccache, profile mapping, boot-file absence |
| w11-crypto   | 8  | libcrypto SHA-256 KAT, getentropy, Ed25519/BLAKE3 surface |
| w12-perf     | 9  | boot/eval/compiled timings |

Linux cross-check: copy the directory (or run from a checkout) on
linux-x86_64 with `GUILE=$(command -v guile) ./run-all.sh`; platform rows
(fcntl constant spellings, EAGAIN value, flock layout) are derived from
`uname` inside the witnesses.

## W8 on hosted Darwin arm64

The macos-15 qualification job sets `GUILE_W8_SKIP_DIRECT_FCNTL=1`.
IO3a1 prints a skip with the observed outcomes. The audit baseline
returned `-1/EFAULT`, while hosted run 46172518881 returned `0/0` from
the same fixed-arity Guile FFI call to variadic `fcntl`. Darwin arm64
passes the unnamed pointer argument on the stack. A fixed-arity call
passes it in a register, so the result depends on what the callee reads
from the stack.

The design leaves arbitrary variadics unsupported. W8 always qualifies
the audit's compiled C shim, including parent lock and unlock, child
exclusion, and child acquisition after release. The original direct-call
probe remains enabled in standalone runs by default.

## RUN-STATE at commit time (honesty record)

r1 staged these witnesses in a session whose permission mode denied
execution; the orchestrator's first run then found them broken (only w5
and w12 passed). r2 repaired every witness against the real 3.0.11, r3
fixed the 8 initial review findings, and r4 resolved all 11 findings
from `build/review-findings-r3.md` (`call-with-prompt` + `dynamic-wind`
every-exit invalidation, live cross-thread continuation barrier check,
C-side blocking-GC handshake + wall-clock/drain NC, standalone fence
publication, C-constructed `struct flock` + boundary errno + unlock
check, signed `time_t` + pre-epoch `utimensat`, occupied-heap
validation, pre-absent `ccache` check, child exit-status enforcement)
and re-ran the full suite: **13/13 PASS, recorded under `results/`** on
darwin-arm64 (`guile 3.0.11`, aarch64-apple-darwin25.4.0). Linux-x86_64
was NOT run.
