# P1b-ci r2: deadhost and the JS-link collector boundary

Session-ID: 01a1f1f9-2d2b-71a2-b88a-1675b81dd975
Completed-GMT: 2026-11-19 14:26:53 GMT
Completed-Local: 2026-11-19 21:26:53 ICT (+07)
Coding-Agent: Codex
Base: gambit-ffi-p1b @ f1a5c9f3. No push authorized or performed.
Completion: both findings fixed; every requested local gate passed.

| Finding | Source change |
| --- | --- |
| F-A: two dead host procedures | Removed the unused exact-message checker preceding `host/gambit/ffi/ffi-harness.ss:38` and unused identity return conversion preceding `host/gambit/scheme-adapter-runtime.ss:535`. Repository-wide searches found no callers or emitted-name stems. The checker scans source irrespective of installed Gambit, so these were genuinely dead on both kinds of host. No dummy references or deadhost exceptions added. `Makefile:2193` now includes deadhost alongside emittedheads in the local gambitffi aggregate. |
| F-B: missing static JS-link entry | `host/gambit/unbound-allowlist.txt:26` documents and includes only `##gc`, the native collector primitive absent from the JS runtime. All 32 native bridge entries remain unchanged. This is a target-runtime distinction, not a changed native installation manifest or var-cell set. Native `sa-gc-collect` still calls real `##gc`. |
| Local audit scratch boundary | `host/gambit/unbound-check.sh:46` passes an explicit mktemp template under TMPDIR. macOS's default mktemp directory otherwise escaped the worktree-local TMPDIR requested for this run. Linker and stale/unbound-name assertions are unchanged. |

## CI diagnosis

Retrieved the actual requested job with a 90s watchdog:

```sh
gh run view --repo sonwh98/jolt --job 135581591607 --log
```

[CI job](https://github.com/sonwh98/jolt/actions/runs/44530323133/job/135581591607)
reported 7474 host procedures and exactly the two dead names above. Its full
JS-link audit reported 468 names, 408 record-generated, 60 unbound. The only
unallowlisted name was `##gc`; there were no stale entries or uninterned-name
errors. The prior allowlist held 59 names; adding the one documented native
primitive makes 60. No per-install relaxation, wildcard allowances, automatic
regeneration, or new bridge exports are involved.

The official Gambit v4.9.8 `lib/_kernel.scm` defines `##gc` through
`##c-code` invoking `___garbage_collect`; the JS runtime entry source
`lib/_univlib.scm` has no such export. The native collection/weak-key assertions
in gambitcheck are the execution proof. This allowlist entry provides no JS
explicit-collection qualification. gambitvars inspects jolt var cells and
cannot establish binding of a Scheme runtime primitive.

## Local gates already completed

All gate commands use explicit native prefixes and process-group watchdogs.
Logs are retained under ignored `build/p1b-ci-r2/`.

- `make gambitffi deadhost emittedheads gambitcheck`, 480s watchdog: exit 0.
  Emitted heads 249, none shadowable, 16 allowed. ABI 79/0, public 44/0,
  errno 9/0, loader 14/0; aggregate PASS. deadhost 7472 procedures, four built
  names, PASS. gambitcheck zero failures, including real collector execution
  and clearing an unreachable weak key; its public run also passed 44/0.
- `make deadhost` with GAMBIT_PREFIX pointing at an absent worktree path,
  90s watchdog: exit 0, 7472 procedures, four built names, PASS.
- `make gambitvars`, 120s watchdog: exit 0, 3625 cells, four unbound,
  four allowlisted; PASS, matching the reported provisioned-machine baseline.
- After adding deadhost to the aggregate: `make gambitffi deadhost emittedheads`,
  480s watchdog: exit 0. Both hygiene gates ran as prerequisites; ABI 79/0,
  public 44/0, errno 9/0, loader 14/0, aggregate PASS. Shell syntax and
  `git diff --check` also passed.

## Full local JS audit and its prerequisite

This macOS installation is C-only: it has `_gambit.c` but no `_gambit.js` linker
base. The earlier stage-1 findings already recorded that prerequisite gap.
The first full audit this round hit its 480s external compilation deadline.
A retry with the JS base available hit its 1200s deadline just after beginning
JS output generation (the partial file's birth time is 20:59:05 local and its
last write 20:59:06). Neither attempt is counted as a passing gate. A final
retry uses a 3600s watchdog and `-verbose` compiler progress diagnostics, with
the same default compactness and dependency checks.

To run the full requested JS audit without altering any installed toolchain,
downloaded and extracted the official v4.9.8 source entirely into ignored
worktree build output:

- Tag commit: `2228e4d163582733a3a67a5efcb22f8ebe93c02b`.
- Archive: `https://codeload.github.com/gambit/gambit/tar.gz/refs/tags/v4.9.8`.
- Archive SHA256: `0ec19b755dbda6c540e9e60b7235d801f26f40c2f211ddfb729b756218bcc873`.
- JS base compilation follows `lib/makefile.in`'s GAMBIT_LIB_js rule: installed
  gsc, `-f -target js -prelude '(##include "header.scm")' -label-namespace ''
  -c -o ../_gambit.js _univlib.scm`, run from the extracted lib directory.
  A 600s watchdog and minimum compiler heap of 100M are used.
  Compilation completed with exit 0. Generated `_gambit.js` SHA256:
  `1f17005ac220a408fbbfda8cabb9525bbdfbee0515ee57503b2b74537dce85f7`.
- The worktree-local `gsc-js-audit.sh` invokes that same native installed gsc,
  with a 1G minimum compiler heap. On the real link invocation it adds
  `-l <extracted-source>/_gambit`. It supplies no fake definitions or output.
  `make gambitunbound` is rerun with this path as GAMBIT_GSC and a 3600s
  watchdog. Native gsi and provenance continue using the original prefix.

The compiler wrapper is solely a local prerequisite adapter; its complete
behavior is:

```sh
#!/bin/sh
set -eu
audit_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
native_gsc=/Users/sto/.local/share/mise/installs/gambit/4.9.8/bin/gsc
for arg do
  if [ "$arg" = -link ]; then
    exec "$native_gsc" -:m1G -l "$audit_dir/gambit-4.9.8/_gambit" "$@"
  fi
done
exec "$native_gsc" -:m1G -verbose "$@"
```

The full gate uses the normal Makefile recipe, with only GAMBIT_GSC overridden
to that wrapper. Its final verdict still comes from the existing real linker
report, record-name subtraction and exact allowlist/stale/gensym checks.

A separate real compiled JS probe calls only `##gc`. Linking it against this
base produces exactly that one warning attributable to the probe; warnings
from the base alone are excluded by the audit's existing convention. External
30s compile/link deadlines and a 15s assertive verdict check passed:
`GC JS boundary: PASS — real linker reports only ##gc from the probe`.
Gambit requires `-l` before input filenames; the local wrapper supplies it
before the gate's original arguments. No installed files were changed.

Full JS audit verdict: PASS, exit 0 under the 3600s watchdog, using the real
provisioned compiler, default compactness 9, and its matching source-built
v4.9.8 JS base. Actual receipts:

```text
gambitboot: full-profile boot OK on gsi
gambit unbound: 468 name(s) reported by the linker, 408 record-generated, 60 unbound
gambit unbound: passed (60 allowlisted)
```

The final run took about 26 minutes. Progress diagnostics showed parsing,
procedure generation, then a JS unit exceeding 47 MB before normal link/check
completion. The gate removed its worktree-local temporary directory on success.
The old 75-second compile estimates in Makefile/unbound-check.sh are removed.
A compaction-level experiment was discarded: Gambit correctly refused a
level-0 probe against a level-9 base, and the optional level-0 base build was
stopped. No compaction override or optimization relaxation is used in the
passing full gate. The failed shorter attempts remain failed receipts.

Exact passing full-gate invocation (after building the genuine JS base and
the local wrapper above):

```sh
sh host/gambit/ffi/watchdog.sh 3600 env JOLT_REQUIRE_GAMBIT=1 \
  JOLT_CHEZ=/Users/sto/.local/share/mise/installs/chezscheme/10.4.1/bin/scheme \
  make CHEZ=/Users/sto/.local/share/mise/installs/chezscheme/10.4.1/bin/scheme \
  GAMBIT_PREFIX=/Users/sto/.local/share/mise/installs/gambit/4.9.8 \
  GAMBIT_GSC="$PWD/build/p1b-ci-r2/gsc-js-audit.sh" \
  TMPDIR="$PWD/build/p1b-ci-r2/tmp" gambitunbound
```

This is a full static JS-link audit, not JS execution or FFI qualification.
Native qualified paths remain proved separately by actual gsi execution.
No Linux/Android execution was performed locally; the orchestrator pushes and
reruns CI. No sources outside this worktree or installed toolchains were
modified. The task's aborted pre-TMPDIR-fix scratch directory was cleaned up.

Gate summary: macOS gambitffi + deadhost + gambitunbound + emittedheads PASS;
native collection/public adapter and gambitvars PASS; no push performed.
