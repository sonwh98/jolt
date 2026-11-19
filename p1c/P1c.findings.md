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
