# P1c findings

## Round 2

- Completed-GMT: 2026-11-19 17:49:07 GMT
- Completed-Local: 2026-11-20 00:49:07 ICT (+07)
- Created-GMT: 2026-11-19 17:36:21 GMT
- Coding-Agent: Codex
- Base: `gambit-ffi-p1c` at `f8741162ed46d9852b42c886c01cc86ababe6e2e`
- Datomworld source: `ff274a4eb56340110f0e338ed237ffcd1aad5656`

Round 1 is recorded in the datomworld checkout at
`collab/jolt/1795110000000-engineer-p1c-yin-repl-gambit.gpt-6.2-sol.findings.md`.
Round 2 is recorded here to keep the companion checkout read-only.

| Blocker | Status | Evidence |
| --- | --- | --- |
| B1 — long namespace docstring | Fixed | `jolt-core/jolt/backend_scheme/names.clj:22` joins escaped characters into a Scheme literal. `host/gambit/rt-core.ss:1248` writes the pieces to a string port with bounded call arity. The original emitter raised `Number of arguments exceeds implementation limit` on the 9,000-character namespace docstring in a native probe with the baseline image. `host/gambit/eval-test.ss:48` now verifies the complete namespace metadata, including non-ASCII and escaped characters, on the normal eval path. Both compiler images were regenerated. |
| B2 — `bytes?` and Dao byte storage | Fixed | `host/gambit/host-vars.ss:266` uses Gambit `u8vector` storage, the same carrier as the native FFI copy rows in `host/gambit/scheme-adapter-runtime.ss:730`. Jolt reads signed bytes and Dao exposes unsigned octets. `test/gambit/unit.edn:2` checks the core predicate and signed array operations. `test/gambit/unit.edn:10` exercises the real `dao.host.bytes` namespace for allocation, mutation, fresh slices, equality, overlapping copies in both directions, and refusal without mutation. `make gambitdaobytes` passed. |
| B3 — delay in loaded source | Fixed | `host/gambit/host-vars.ss:241` implements `make-delay`, `delay?` and deref support for the existing `force` overlay. Forcing caches the result or exception under the object's monitor. `host/gambit/eval-test.ss:109` forces a top-level definition, checks laziness and memoization of nil and exceptions, and checks pass-through of an ordinary value. `test/gambit/fixtures/source-load/p1c/source_entry.cljc:4` also forces a delay defined at the top level of a loaded file. |
| Yin prompt and scripted replies | Blocked | The stock entry loads past the `jolt.ffi` delay and fails while loading Dao's text host. The error comes from the eager `scheme/proc "string-length"` call in datomworld's `src/jolt/dao/host/text.jolt:41` and the always-absent global lookup in `host/gambit/scheme-adapter-runtime.ss:849`. A diagnostic launcher resolving real Gambit globals through `eval` reached the next eager lookup, `string-normalize-nfc` at `src/jolt/dao/host/text.jolt:48`, and failed there. |

The stock memory-store session also depends on `dao.host.hash`, whose Jolt
adapter declares blocking crypto entry points in
datomworld's `src/jolt/dao/host/hash.jolt:68–78`. The C4 blocking boundary
is enforced by `host/gambit/scheme-adapter-runtime.ss:628`. An adapter-level
subprocess call produced the documented refusal in `gambitcheck`. The Yin
gate still needs a live session to demonstrate inline frontend refusal and
guest FFI. The Python row specifically checks the parser-unavailable
diagnostic.

`host/gambit/ffi/watchdog.sh:3` preserves caller stdin for gsi. A stdin
round-trip through the watchdog passed. The Yin script also has a separate
division-by-zero row before its language-switch check
(`test/gambit/yin-repl-session.sh:17`).

### Yin gate output

`make gambityinrepl` used the stock datomworld entry point and the
existing watchdogs on native Gambit 4.9.8, macOS arm64.

```text
yin.repl startup failed: no top-level Scheme binding: string-length
boot: backend target -> :gambit
gambityinrepl: a complete Yin session was not observed (status 1)
make: *** [gambityinrepl] Error 1
```

### Regression results

The round-one Stage‑1 matrix passed on native macOS arm64 under foreground
watchdogs. It included `gambitffi` (ABI 79/0, public 44/0, errno 9/0,
loader 14/0), `gambitcheck`, `gambitkernel`, `gambiteval`,
`gambitseedcheck`, `gambitgencheck`, `gambittwins`, `adaptercheck`,
and `gambitsourceload`. The new `gambitdaobytes` gate and the supplemental
`deadhost`, `emittedheads`, `gambitboot` and `gambitvars` runs passed.
The unchanged qualified FFI tier is exercised by the Stage‑1 public gate.
Local receipts are under `build/p1c-r2/`.

DONE

## Round 3

- Created-GMT: 2026-11-19 17:51:19 GMT
- Coding-Agent: Codex
- Base: `gambit-ffi-p1c` at `b77eea9a`
- Datomworld source: `ff274a4eb56340110f0e338ed237ffcd1aad5656`

### F-A — Loaded-source binding audit

`clojure -M test/gambit/yin-source-closure.clj ../datomworld` selects :jolt
and :clj reader branches and uses the launcher's stock source-root order.
It found 164 source namespaces reachable from `yin.repl.main`, with
`clojure.core` supplied by the boot. The `--gambit` pass found 154 source
namespaces for the local composition, with core and the stage-1
`jolt.ffi` supplied by the boot. These are static namespace-declaration
closures. `JOLT_YIN_AUDIT=1` runs the shared `gambitvars` var-cell scan
before and after the actual Gambit load and reports the delta. It also
reports the partial delta when a load throws.

The stock closure contained the following 41 distinct literal
`jolt.scheme/proc` and `jolt.scheme/call` names. All failed through the
old always-absent lookup. The first four groups already exist in native
Gambit. There are unit rows for each name in `test/gambit/unit.edn`.

| Binding names | Provider |
| --- | --- |
| `string-length`, `string-ref`, `char->integer`, `integer->char`, `string->utf8`, `bytevector-length`, `bytevector-u8-ref` | Native Gambit procedures, surfaced by `sa-baked-global`. The Dao text layer converts scalar indexing to JVM UTF-16 units. |
| `number?`, `exact?`, `integer?`, `flonum?`, `inexact`, `exact`, `flnan?`, `flinfinite?`, `flfinite?`, `flinteger?`, `fltruncate` | Native Gambit procedures, surfaced by `sa-baked-global`. |
| `+`, `-`, `*`, `/`, `<`, `<=`, `=`, `quotient`, `remainder`, `abs`, `numerator`, `denominator`, `gcd` | Native Gambit procedures, surfaced by `sa-baked-global`. |
| `number->string`, `string->number`, `string-downcase` | Native Gambit procedures, surfaced by `sa-baked-global`. |
| `logand`, `logor`, `logxor`, `ash`, `bitwise-length`, `scheme-version` | Aliases in `host/gambit/scheme-adapter-runtime.ss` for Gambit's bitwise operators, arithmetic shift, integer length and system version. |
| `string-normalize-nfc` | `host/gambit/unicode-nfc.ss`, using Unicode 16.0.0 canonical data and algorithmic Hangul composition. [Unicode 16.0.0](https://www.unicode.org/versions/Unicode16.0.0/) |

The two literal `jolt.scheme/eval-string` sites in `dao.host.float` also
need `bytevector-ieee-double-set!`, `bytevector-ieee-double-ref`,
`bytevector-u64-ref`, `bytevector-u32-set!` and `endianness`. The bytevector
operations are in `scheme-adapter-runtime.ss`. The source loader handles
R6RS brackets and endianness syntax before Gambit evaluates the text.
`make-bytevector` already exists. Both IEEE directions have unit rows
using the same forms as Dao, with negative values and the high bit set.

The next exposed top-level load failure was the B-tree's `object-array`.
`host-vars.ss` supplies object arrays, clones and `to-array`, and connects
object storage to count, nth, seq, aget, aset and alength. `host-statics.ss`
supplies overlapping `System/arraycopy` and stable `Arrays/sort` for the
Dao array boundary. The independent normalization comparison matched
33,163 Unicode 16 cases.

### F-B — Local memory store

The local profile opens the ordinary `yin.repl.store/open :mem` store.
Yin computes BLAKE3 addresses eagerly for its primitive profiles and during
ordinary indexing. `host/gambit/yin/blake3.ss` computes those addresses in
Scheme and matched the ten unkeyed known answers in Datomworld's
`blake3-vectors.edn`. The SHA-256 host operation still reaches the C4
refusal when invoked. The acceptance corpus requires the
`dao.jing.mem` host module, calls `dao.jing/materialize!` with SHA-256 and
expects a refusal followed by successful arithmetic in the same session.
The local composition also admits the stage-1 `jolt.ffi/sizeof` export
through Yin's module registry. [BLAKE3 specification](https://c2sp.org/BLAKE3)

The launcher reads Datomworld from the companion checkout and supplies
Gambit adapters for local terminal input, entropy, unavailable network and
native parser operations, and file and signing boundaries. The companion
checkout is read in place.

### Verification

Native macOS arm64 and Gambit 4.9.8. The Stage 1 matrix passed
`gambitffi`, `gambitcheck`, `gambitkernel`, `gambiteval`,
`gambitseedcheck`, `gambitgencheck`, `gambitvars`, `emittedheads`,
and `deadhost`. Receipts and the source-load transcripts are in
`build/p1c-r3/`.

The 57 binding and Dao rows passed. The SHA-256 row verifies the documented
C4 message and successful arithmetic immediately after the caught refusal.
The terminal adapter also passed its separate native two-line and EOF probe.

The end-to-end Yin corpus remains under verification. The standard
`gambityinrepl` run has loaded DaoJing and entered the B-tree dependency
under `yin.vm`. A `yin>` reply has yet to be observed.

## Linux compiled Yin boot

Session-ID: 01a1f1f9-2d2b-71a2-b88a-1675b81dd975

The shiva run at `e28f40b6` used `~/ci/jolt-ffi-linux`, whose default
`DATOMWORLD_ROOT=../datomworld` resolves to an absent checkout. With that path
the original launcher printed the boot marker and exited 2 in 0.29s, with
95,424 KiB peak RSS. The same launcher with either `-:h4000` or
`-:max-heap=4M` exited 70 in under 0.01s at `##cte-lookup`, before the boot
marker, with 10,944 KiB peak RSS. In Gambit 4.9.8, `h` sets a maximum and a
bare number denotes KiB. `-:min-heap=128M` sets a floor. Runtime options go
before the script name.

The existing 31,545,888-byte Linux `kernel.o1` completed with default runtime
options, `-:p1`, and explicit 128 MiB and 256 MiB minimums. The boot-only
default run took 0.22s with 95,040 KiB peak RSS. A forced collection after it
reported a 17,332,608-byte heap and 6,147,520 live bytes. The 128 MiB and
256 MiB floor probes reached the same live size (about 6.15 MB) with peak RSS
of 122,496 and 123,072 KiB respectively. The full-launch phase probe separately
recorded kernel return at 0.222s, followed by all four driver includes and the
FFI bridge by 0.223s. The last-GC heap was 17,323,416 bytes, of which
5,966,712 were live at that collection. Process RSS began to rise during
Yin source loading, reaching 413,320 KiB at 129s in a separate run.

`gambityinrepl` now checks the source entry before building or loading the Yin
kernel and prints the path and the `DATOMWORLD_ROOT` override on failure. The
successful launcher receives the same resolved path and Gambit arguments.
The missing-root assertion passed with status 2 and no kernel boot marker.

With `/home/sto/workspace/datomworld` at `472d8ac2`, the original Linux
launcher completed the 12-line gate corpus using the default heap. The source
trace reached 138 namespace-ready markers, then all 12 expected replies in
order including `yin> Bye`. `/usr/bin/time` measured 722,836 KiB peak RSS
and 299.46s elapsed, with launcher status 0. The gate's own AWK assertions
passed on that transcript. The shorter diagnostic deadlines expired during
ordinary namespace loading. The successful run establishes bounded resource
use for this acceptance corpus with Gambit's default heap growth. It provides
no basis for imposing a minimum heap or changing Gambit's evaluator.

For the orchestrator's shiva matrix, supply the actual source root explicitly:

```sh
make gambityinrepl DATOMWORLD_ROOT=/home/sto/workspace/datomworld \
  GAMBIT_PREFIX="$HOME/.local/share/mise/installs/gambit/4.9.8"
```

The watchdog in the gate covers the whole session. The default-heap trace and
failure comparison are under `build/p1c-linux/`.

On macOS arm64, `gambityinrepl` passed before and after the preflight with the
same cached kernel and Datomworld `27f207c0`. Both watchdogged runs produced
the same 12 `yin>` replies byte for byte. `gambitsourceload` also passed.
