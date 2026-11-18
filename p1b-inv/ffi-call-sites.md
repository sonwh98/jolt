# p1b-inv/ffi-call-sites.md — FFI construction-site inventory (jolt fork, branch `gambit-ffi-inv` @ a6852ef8)

Produced by the P1b-prep static-analysis slice (Compiler & AST Engineer role).
Static analysis only: every claim carries `file:line` read on THIS fork SHA.
No builds, no test runs, no behavior changes.

Fork provenance: `~/workspace/jolt-ffi-inv`, branch `gambit-ffi-inv`, HEAD
`a6852ef8` ("Regenerate the checked-in seeds for the Sorted change"). The fork
is far past the SHA astra inspected (`b389f1a7`); astra's line citations were
cross-checked against this tree — see §5.

Legend — capability tiers (astra §2): `ordinary`, `blocking` (__collect_safe),
`native-error` (atomic errno capture), `callable`, `scoped-address` (call built
against a dlsym-resolved address), `varargs` (declared tail), `bare-varargs`
(per-call inferred tail), `aggregate` (by-value struct/union), `pointer-call`
(function-pointer target), `runtime-signature` (constructed at run time).

Routing verdicts use astra's rule (unregistered shapes raise deliberately):
- **shim** = the Gambit path routes it through a typed, generated C shim.
- **refuse** = the Gambit path raises a message-carrying
  `UnsupportedOperationException`-class error (adapter `sa-ffi-raise` shape).
- **audit** = the site itself is Chez-adapter-owned (lives under
  `host/chez/`), so the Gambit adapter file owns an equivalent or a refusal;
  it is listed for completeness because it is a foreign-call construction site.

---

## 1. Compile-time emission — the compiler's foreign-call constructors

Everything the back end emits is text; the construction happens when the
emitted text is expanded/compiled on the host. All compiler-side sites live in
one namespace split over two files on this SHA:

- `jolt-core/jolt/backend_scheme/ffi.clj` (772 lines) — all lowering
- `jolt-core/jolt/analyzer/ffi.clj` (237 lines) — literal signature validation
- dispatch wired at `jolt-core/jolt/analyzer.clj:1311-1327`
  (`__cfn` / `__cfn-pointer` / `__layout` / `__ccallable` special forms).

### 1.1 `emit-ffi-node` — the IR-op dispatcher

| Site | Tier | Emits | Gambit routing |
|---|---|---|---|
| `jolt-core/jolt/backend_scheme/ffi.clj:758-772` `emit-ffi-node` | all | case on `:op`: `:ffi-layout` → §1.6, `:ffi-fn` → §1.2-1.4, `:ffi-callable` → §1.5 | partial: guards only pointer-call fns (625-628) and by-value callables (763-771); see GAP G-1/G-2 in §1.7 |

### 1.2 `ffi-named-procedure-expr` — named symbol, three construction paths

`jolt-core/jolt/backend_scheme/ffi.clj:463-493`. Emits
`(or p (begin (set! p (or <scoped> <by-name>)) p))` — a lazy first-call binding
caching the resolved address/procedure in the binding's `p` cell.

| Sub-site | file:line | Tier | Emitted form (verbatim shape) | Chez-specific? | Gambit routing |
|---|---|---|---|---|---|
| by-name, capture | ffi.clj:476-478 | native-error (+ blocking, + varargs conv) | `(jolt-ffi-native-error-procedure (<capture-conv>) "<csym>" <sig>)` | expands via `host/chez/rt.ss:359-367` → `host/chez/scheme-adapter-runtime.ss:918-921` → `foreign-procedure __errno \| __get_last_error conv... name args res` | **shim** (typed shim must capture errno atomically at the call boundary; astra §2 wrapper sequence) |
| by-name, ordinary/blocking | ffi.clj:479-482 | ordinary \| blocking \| varargs (`conv` = `(__varargs_after n)` at 467) | `(sa-foreign-procedure [conv] "<csym>" <sig>)` / `(sa-foreign-procedure-blocking "<csym>" <sig>)` | expands via `host/chez/scheme-adapter-runtime.ss:898-908,930-932` → Chez `foreign-procedure` | **shim** (ordinary/blocking) / **refuse** (varargs until declared-tail shims exist; astra §2 lists varargs specialization in scope) |
| scoped-address, capture | ffi.clj:484-487 | native-error + scoped-address | `(let ((a (jolt-ffi-dlsym-native "<csym>"))) (and a (jolt-ffi-native-error-procedure (<capture-conv>) a <sig>)))` | `jolt-ffi-native-error-procedure` is the rt.ss macro (above) with an ADDRESS in `name` position | **shim** — same shim as by-name capture; the address feeds the shim |
| **scoped-address, raw** | **ffi.clj:488-491** | ordinary \| blocking \| varargs + scoped-address | `(let ((a (jolt-ffi-dlsym-native "<csym>"))) (and a (foreign-procedure[__collect_safe][(__varargs_after n)] a <sig>)))` | **YES — raw Chez `foreign-procedure` emitted verbatim**, bypassing the sa-foreign adapter syntaxes | **shim** — astra's §2 "Replace the raw Chez scoped-address emission ... with adapter operations". This is THE site astra cited (was backend_scheme.clj:2134; moved here) |

`capture-conv` decision at ffi.clj:468-475: blocking → `"__collect_safe"`;
varargs → `(__varargs_after n)`; blocking+varargs is refused at compile time
(§1.8), so blocking capture carries `__collect_safe` and varargs capture
carries the wrapped `(varargs_after n)` list "so the adapter receives it as one
datum" (comment 471-474).

### 1.3 `ffi-pointer-procedure-expr` — function-pointer target

`jolt-core/jolt/backend_scheme/ffi.clj:503-514`. Entry expression is
`(jolt-ffi-function-pointer function-pointer)` (null check at
`host/chez/java/ffi.ss:661-665`). **No caching — the procedure is built against
each call's pointer** (comment 496-502).

| Sub-site | file:line | Tier | Emitted form | Gambit routing |
|---|---|---|---|---|
| capture on pointer | ffi.clj:507-512 | native-error (+ blocking / + varargs) | `(jolt-ffi-native-error-procedure (__collect_safe \| (__varargs_after n) \| "") (jolt-ffi-function-pointer function-pointer) <sig>)` | **shim** (same capture shim; entry is the address) |
| blocking on pointer | ffi.clj:513 | blocking + pointer-call | `(sa-foreign-procedure-blocking (jolt-ffi-function-pointer function-pointer) <sig>)` | **shim** (after blocking qualification) else **refuse** |
| ordinary on pointer | ffi.clj:514 | pointer-call (+ varargs conv) | `(sa-foreign-procedure[ conv] (jolt-ffi-function-pointer function-pointer) <sig>)` | **shim** |

The comment at ffi.clj:501-502 states "The gambit target never reaches here
(emit-ffi-fn)": on `:gambit`, `emit-ffi-fn` (ffi.clj:621-628) short-circuits
every pointer-call binding to an emitted
`(lambda args (throw-jvm 'UnsupportedOperationException "jolt.ffi/pointer-fn: ffi is unsupported on the gambit target"))`
— a **deliberate refusal already in the compiler** (site: ffi.clj:625-628).

### 1.4 `emit-ffi-fixed-fn` — signature assembly, marshaling, aggregates

`jolt-core/jolt/backend_scheme/ffi.clj:559-608` (with `ffi-signature`
540-546, `ffi-aggregate-args` 526-535, `ffi-ftype-defs` 549-557,
`ffi-aggregate-pointer` 445-450, `ffi-kept-call` 245-252,
`ffi-capture-result` 275-278).

| Aspect | file:line | Tier | What is emitted | Chez-specific? | Gambit routing |
|---|---|---|---|---|---|
| by-value aggregate ARGUMENT | ffi.clj:576-583 + 445-450 | aggregate | `(define-ftype jolt_ffi_arg<N> (struct (f<i> <t>) …))` + `(make-ftype-pointer <ftype> addr)` after a null check that throws `NullPointerException` | YES — Chez `define-ftype`/`make-ftype-pointer` | **refuse** on gambit for callables (already guarded, §1.5); for named fns the aggregate path is NOT gambit-guarded — GAP G-2 |
| by-value aggregate RESULT | ffi.clj:567-572, 584-587, 597 | aggregate | destination-first calling convention: an extra `destination` parameter, `(& jolt_ffi_return)` signature position, `(begin call destination)` | YES — `(& ftype)` is Chez foreign-type syntax | **refuse** (unregistered shape raises) |
| :string argument copy | ffi.clj:236-240 + 593-595 | ordinary (all) | `(jolt-ffi-string-arg x)` — immobile u8* copy built by `host/chez/java/ffi.ss:763` | runtime helper, Chez-owned | **shim** (Gambit needs an immobile/anchored copy; astra §2 Memory) |
| keep-live around call | ffi.clj:245-252 | all | `(keep-live n)` bindings + `call-with-values` two-value plumbing for capture | `keep-live` is a Chez-form emitted bare (names.clj:203) | **shim** (equivalent rooting in the Gambit adapter) |
| float/bool/string boundary conversions | ffi.clj:226-231, 265-270 | all | `(jolt-ffi-string->c …)` `jolt-ffi-bool->c` `jolt-ffi-float->c` `jolt-ffi-c->string` `jolt-ffi-c->bool` `(make-jfloat …)` | runtime helpers (`host/chez/java/ffi.ss:748-804`) | **shim** (port the helpers into the Gambit adapter) |

### 1.5 `emit-ffi-callable` — C-calls-jolt constructors

`jolt-core/jolt/backend_scheme/ffi.clj:696-755` (+ wrapper 632-653, entry
counter 655-666).

| Sub-site | file:line | Tier | Emitted form | Chez-specific? | Gambit routing |
|---|---|---|---|---|---|
| plain callable | 743-751 | callable | `(jolt-ffi-register-callable! (sa-foreign-callable <target> (<args>) <res>))` | expands via `host/chez/scheme-adapter-runtime.ss:948-952` → Chez `foreign-callable` wrapped in `jolt-ffi-callable-body` (host/chez/java/ffi.ss:1523) | **shim** (Gambit `c-define` trampoline + explicit rooting; astra §2 Callbacks) |
| collect-safe callable | 743-751 (branch 744) | callable + foreign-thread | `(sa-foreign-callable-collect-safe <target> …)` → `host/chez/scheme-adapter-runtime.ss:962-966` → `(foreign-callable __collect_safe …)` | YES | **refuse** until foreign-thread entry is qualified (astra ruling: unqualified) |
| collect-safe entry counter | 655-666, 728-742 | callable | `(jolt-ffi-collect-safe-entry (lambda …(jolt-ffi-callback-enter!)…(jolt-ffi-callback-exit!) r))` | runtime helpers `host/chez/java/ffi.ss:1499-1503` (CAS counters) | audit — goes with the collect-safe refusal |
| aggregate callable (by-value arg/result) | 709-724, 746-750 | callable + aggregate | `(& ftype)` positions, destination-first for results, `(ftype-pointer-address param)` conversion 641-648 | YES | **refuse** — compiler ALREADY refuses on `:gambit` (ffi.clj:763-771 emits throw-jvm) |
| :collect-safe + :string result | 703-708 | compile-time refusal | `throw (ex-info …)` | n/a | stays (analyze-time, host-independent) |

### 1.6 `emit-ffi-layout` — aggregate/ftype metadata emission (astra's separate audit item)

`jolt-core/jolt/backend_scheme/ffi.clj:180-209`, ftype text builders
`emit-ffi-layout-ftype` 35-53 (struct/union/array), offset computation
`emit-layout-offsets` 148-155, stride/alignment 169-178.

| What is emitted | file:line | Chez-specific? | Gambit routing |
|---|---|---|---|
| `(define-ftype <name> (struct [f<i> <t>] …))`, `(define-ftype <align> (struct [prefix unsigned-8] [value <name>]))` | 170-177 | YES | **refuse** today (unbound on gambit); a Gambit path needs a layout engine or refusal — GAP G-1 |
| `(make-ftype-pointer <name> 0)`, `(ftype-&ref …)`, `(ftype-sizeof …)`, `(ftype-pointer-address …)` | 148-155, 197-209 | YES | same as above |
| the descriptor/offsets/strides jolt-hash-map assembly | 197-209 | the data shape is portable once computed | the computed `:jolt.ffi/layout` map (stdlib/jolt/ffi.clj:341-414 consumer side) is host-neutral |

### 1.7 Bare-varargs lowering — per-binding dispatcher over a runtime cache

`jolt-core/jolt/backend_scheme/ffi.clj:303-370` (`ffi-varargs-context`
303-318, arms 334-347 + 350-360, cache emission 362-370).

| Sub-site | file:line | Tier | Emitted form | Chez-specific? | Gambit routing |
|---|---|---|---|---|---|
| cache constructor | 364-367 | bare-varargs | `(jolt-ffi-varargs-cache "<csym>" '(<fixed chez types>) '<ret> <n> <capture?>)` | runtime helper `host/chez/java/ffi.ss:1276-1277` | **refuse** on gambit: a bare marker compiles a foreign procedure per observed tail shape at run time (`eval`, §2.1) — precisely the capability the bounded shim registry cannot claim |
| arity arms 0-3 | 334-347 | bare-varargs | case-lambda arms calling `(jolt-ffi-varargs-proc0..3 <cache> …)` | `host/chez/java/ffi.ss:1439-1464` | refuse with the binding (arms are inert without the cache) |
| rest arm | 350-360 | bare-varargs | `(apply (jolt-ffi-varargs-procedure <cache> <tail>) …)` + `(jolt-ffi-varargs-tail <tail>)` + `(jolt-ffi-varargs-arg v)` | `host/chez/java/ffi.ss:1348-1359` | refuse with the binding |

### 1.8 Compile-time refusals the compiler already raises (keep, port verbatim)

| Refusal | file:line | Rule |
|---|---|---|
| marker at position 0 (no fixed arg before it) | ffi.clj:394-396 | C requires a named parameter before the ellipsis |
| bare `:&` through a function pointer | ffi.clj:400-403 | per-shape cache is keyed by C symbol |
| bare `:&` with a fixed by-value aggregate | ffi.clj:404-409 | aggregate needs an ftype the binding declared |
| varargs + `:blocking` | ffi.clj:411-413 | `__collect_safe` cannot combine with a varargs convention |
| `:blocking` + `:string` argument | ffi.clj:424-435 | collector may move the string behind a deactivated thread |
| varargs + aggregate return | ffi.clj:436-438 | — |
| aggregate variadic arguments | ffi.clj:439-441 | — |
| capture + `:void` return | analyzer/ffi.clj:205-207 | no stable native result to pair |
| capture + by-value return | analyzer/ffi.clj:208-209 | — |
| union by value (alone or nested) | analyzer/ffi.clj:141-146 | register classification is member-dependent |
| callable signature shape | analyzer.clj:969 | — |
| pointer-call + gambit target | ffi.clj:625-628 | deliberate UnsupportedOperationException |
| by-value callable + gambit target | ffi.clj:763-771 | deliberate UnsupportedOperationException |

### 1.9 Compiler bare-name registry the emitted text leans on

`jolt-core/jolt/backend_scheme/names.clj:175-194` enumerates every bare head
the FFI lowering emits (shadow-guard set): `sa-foreign-procedure`,
`sa-foreign-procedure-blocking`, `sa-foreign-callable`,
`sa-foreign-callable-collect-safe`, `jolt-ffi-native-error-procedure`,
`jolt-ffi-function-pointer`, `define-ftype`, `make-ftype-pointer`,
`ftype-sizeof`, `ftype-&ref`, `ftype-pointer-address`, `struct`, `array`,
`foreign-procedure`, `__varargs_after` (193-194), `apply` (185),
`call-with-values` (179), `keep-live` (203). The `jolt-ffi-*` helper family is
caught by the `jolt-` prefix safety net (names.clj:274). A Gambit adapter must
either bind or deliberately intercept every one of these names in its
emission-target environment.

---

## 2. Runtime construction — foreign procedures built while the program runs

### 2.1 `ffi-varargs-compile` — the runtime-signature `eval` construction (DYNAMIC)

`host/chez/java/ffi.ss:1373-1386` (astra cited 1294 — moved; see §5):

```scheme
(eval (append (list 'foreign-procedure)
              (if (ffi-vc-capture? vc) (ffi-varargs-error-convention) '())  ; 1370-1371: (__errno) | (__get_last_error)
              (ffi-varargs-convention (ffi-vc-fixed-count vc))               ; 1364-1365: ((__varargs_after n)) | '() on windows
              (list (or (jolt-ffi-dlsym-native name) name)
                    (append (ffi-vc-fixed-types vc) shape-types)
                    (ffi-vc-ret vc))))
```

- **Entry point (DYNAMIC marker):** emitted binding's cache
  `(jolt-ffi-varargs-cache …)` (ffi.clj:364-367) → first call of a new tail
  shape → `ffi-varargs-miss` (ffi.ss:1416-1423, mutex-serialized, double-check)
  → `ffi-varargs-compile` (above).
- **Inputs:** fixed types from the compile-time literal signature; tail shape
  types from `ffi-varargs-carrier` (ffi.ss:1292-1311 — 0 = `integer-64`,
  1 = `double`, 2 = `u8*`), so the runtime shape space is exactly
  {integer/pointer/bool/nil, double, C-string} per tail position.
- **Tier:** varargs (bare), native-error optional, never blocking (refused at
  compile time, ffi.clj:411-413).
- **Gambit routing:** **refuse**. The construction compiles a new
  `foreign-procedure` per shape — the exact "arbitrary runtime signatures"
  capability astra §2 declines for the bounded tier; the compile step also
  requires Chez's compiler at run time (dce.ss note at ffi.ss:1392-1396).

### 2.2 `jolt-foreign-proc-safe` / `jolt-foreign-proc-blocking` — adapter-internal name-resolved constructors

`host/chez/rt.ss:83-118` (safe) and `host/chez/rt.ss:126-141` (blocking).
Two-branch macro: POSIX emits a **compiled** `(sa-foreign-procedure [conv] name args res)`
(or `sa-foreign-procedure-blocking`), guarded at creation; Windows emits
`(sa-foreign-procedure-runtime name args res [blocking])` (eval — a compiled
foreign reference is a load-time fasl relocation there, rt.ss:79-82).
Convention arm at rt.ss:101-118 for variadic libc entries (`(__varargs_after n)`).

Sites (count of `jolt-foreign-proc-safe`/`-blocking`/`sa-foreign-procedure-runtime`
uses per file, this SHA): `host/chez/java/process.ss` 48, `host/chez/java/io.ss` 29,
`host/chez/rt.ss` 24, `host/chez/java/nio-file.ss` 20,
`host/chez/java/concurrency.ss` 12, `host/chez/java/tz-primitives.ss` 8,
`host/chez/java/ffi.ss` 7, `host/chez/java/natives-str.ss` 6,
`host/chez/java/host-static-methods.ss` 4, `host/chez/loader.ss` 3,
`host/chez/java/io-streams.ss` 3, `host/chez/build.ss` 3,
`host/gambit/rt-core.ss` 2, `host/chez/java/zlib.ss` 2,
`host/scheme-adapter/guile.ss` 1 (comment), `host/gambit/prelude-shims.ss` 1
(comment).

- **Tier:** ordinary / blocking / varargs / runtime-signature (Windows arm).
- **Gambit routing:** audit — these are Chez host-runtime internals; the
  Gambit runtime files (`host/gambit/rt-core.ss` etc.) must supply their own
  or go without. Not consumer ABI shapes; excluded from the shim registry
  (they are the adapter's own bootstrap surface).

Notable individual sites worth their own rows:

| Site | file:line | Tier | Notes |
|---|---|---|---|
| `io-errno-loc` (`__error`/`__errno_location`/`__errno`) | host/chez/rt.ss:372-375 | ordinary | three accessor spellings; feeds `io-call+errno` (386-394) inside `disable-interrupts` |
| kernel 64-bit wraparound ops | host/chez/rt.ss:1358-1371 | ordinary, TWO conventions | `(sa-foreign-procedure __atomic __alloc name (scheme-object scheme-object) scheme-object)` for `(cs)s64_{add,sub,mul}_wrap`; Windows eval arm has no `__atomic` (comment 1354-1357). Chez-kernel-only symbols — Gambit must refuse these three |
| Windows CSPRNG | host/chez/rt.ss:3057-3073 | runtime-signature | BCryptGenRandom / SystemFunction036 via `sa-foreign-procedure-runtime` |
| Win32 std-stream probe | host/chez/rt.ss:171-172 | runtime-signature | GetStdHandle/GetFileType |
| Win32 W-entry points | host/chez/java/io.ss:1245-1252, macros `define-win32-proc` 1268-1272, `define-win32-proc-blocking` 1274-1277 | runtime-signature / blocking | every Win32 entry resolves through `win32-proc` → `sa-foreign-procedure-runtime` |
| zlib qualified bindings | host/chez/java/zlib.ss:85-94 (`zlib-fproc` macro), 130-147 | ordinary + runtime-signature | the runtime's own zlib surface astra's `gambitffi-zlib-native-smoke` gate protects |
| dlclose/dlopen/dlsym/dlerror | host/chez/java/ffi.ss:388-390, 452 | ordinary | loader bootstrap itself |
| stack-args probes | host/chez/java/ffi.ss:1827-1866 (`ffi-probe-compiles?` 1827, arm64 1829-1839, x86-64 1840-1864) | runtime-signature, probe-only | `eval` of `foreign-procedure`, `foreign-callable`, `foreign-callable-entry-point`, `lock-object`, `define-ftype` — Chez-ABI bug probe (#1091); `ffi-stack-args-correct?` 1867-1874 exported as `jolt.ffi/stack-args-correct?` (stdlib/jolt/ffi.clj:63-75 doc). Gambit: refuse or re-probe under Gambit's ABI |

### 2.3 The adapter's own direct `foreign-procedure` sites (target-owned file)

`host/chez/scheme-adapter-runtime.ss` — the file a Gambit adapter REPLACES
(TARGET-CONTRACT.md:134-135). Its internal construction sites are legal Chez
but enumerate behavior the Gambit adapter must reproduce or refuse:

| Site | file:line | Tier | Form |
|---|---|---|---|
| `sa-foreign-procedure` syntax (3 arities incl. two-convention) | 898-908 | ordinary/varargs | `foreign-procedure` |
| `sa-foreign-procedure-native-error` | 918-921 | native-error | `foreign-procedure error-convention conv... name args res` |
| `sa-foreign-procedure-blocking` | 930-932 | blocking | `foreign-procedure __collect_safe …` |
| `sa-foreign-callable` (incl. `(& ft)` aggregate arm) | 948-952 | callable/aggregate | `foreign-callable (jolt-ffi-callable-body proc …)` |
| `sa-foreign-callable-collect-safe` | 962-966 | callable + foreign-thread | `foreign-callable __collect_safe …` |
| `sa-foreign-procedure-runtime` | 977-980 | runtime-signature | `(eval (if blocking? \`(foreign-procedure __collect_safe ,name ,args ,res) …))` |
| memcpy/memset block moves | 1026-1034 | ordinary | direct `(foreign-procedure "memcpy" (u8* void* size_t) void*)` ×2, `(foreign-procedure "memset" (void* int size_t) void*)` — deliberately NOT `__collect_safe` (comment 1013-1016) |
| uname probe | 542-557 | ordinary | `(foreign-procedure "uname" (void*) int)` inline |
| sysctlbyname probe | 577-578 | ordinary | direct |
| environment access | 617-651 | ordinary/runtime-signature | GetEnvironmentStringsW/FreeEnvironmentStringsW (619-621, runtime), `_NSGetEnviron` (648-649), `environ` (650-651) |
| sched_yield / usleep | 1985, 2002 | blocking | `(foreign-procedure __collect_safe "sched_yield" () int)` etc. |
| Chez-internal terminal `(cs)ee_*` | 2070-2079 | ordinary | 5 entries — Chez-only, Gambit adapter refuses |
| data plane | 987, 992, 999, 1004, 1041-1074, 1079 | ordinary | foreign-alloc/free/ref/set!/sizeof + bytevector block-move fallback loops |
| pins | 1087, 1092 | ordinary | `lock-object`/`unlock-object` — astra §2: Gambit must NOT inherit the non-moving-collector no-op exemption |
| loader + probes | 1112-1129, 1135 | ordinary | load-shared-object (process handle loaded ONCE, 1111-1117), foreign-entry?, foreign-entry, foreign-callable-entry-point |

### 2.4 Scoped-address resolution chain (feeds §1.2 scoped branch)

| Site | file:line | Role |
|---|---|---|
| `jolt-ffi-dlsym-native` | host/chez/java/ffi.ss:638-655 | first-call resolution: loaded-handle dlsym → pending-native load → failure note; answers #f so the emitter falls back to by-name |
| `ffi-dlsym-loaded` / resolvers / definers | 608-618, 518-529, 542-547 | declaration-order resolution + duplicate-address detection (#731) |
| `jolt-ffi-load-native` | 412-442 | RTLD_LOCAL dlopen + ordered handle registry |
| `jolt-ffi-function-pointer` | 661-665 | null-pointer guard for pointer-call |
| duplicate report | 577-598 | JOLT_WARNINGS once-per-symbol report |

Astra's loader-policy invariants (§2 Loading and resolution) map onto exactly
these four sites; the Gambit adapter must reproduce scoped-before-global
resolution, distinct-address duplicate detection, and missing-vs-unloadable
reason preservation (ffi-note-load-failure! 455-457, ffi-load-failure-note
491-512).

### 2.5 Callable runtime machinery

| Site | file:line | Role |
|---|---|---|
| `jolt-ffi-register-callable!` | host/chez/java/ffi.ss:1487-1497 | entry-point → code-object eqv-table; the lock that keeps the collector from moving/reclaiming a callable |
| `jolt-ffi-callable-body` (syntax) | 1523-1532 | holds off fiber preemption while C frames are on the stack |
| `ffi-free-callable` | 1534-1555 | unlock + unregister |
| `jolt-ffi-callback-enter!/exit!` | 1499-1503 | collect-safe callback in/out CAS counters (GC-stall report #1046) |
| `ffi-export-table` / `jolt-ffi-register-export!` / `jolt-ffi-lookup-export` | 1557-1576 | `jolt build --library` export surface |
| library launcher emission | host/chez/build.ss:4647-4653 | emitted Chez code: `(foreign-callable jolt-ffi-lookup-export (string) uptr)` + `(foreign-procedure "jolt_set_lookup_addr" (void*) void)` — Chez-only text inside build output; Gambit AOT is refused independently, so this stays Chez-only |

---

## 3. The adapter contract surface (what a `:gambit` adapter must provide)

`host/scheme-adapter/CONTRACT.txt` tier `capability-ffi` (lines 226-270)
machine-readably lists **18** names:

```
sa-foreign-alloc sa-foreign-free sa-foreign-ref sa-foreign-set!
sa-foreign-bytes-ref! sa-foreign-bytes-set! sa-foreign-zero! sa-foreign-sizeof
sa-lock-object sa-unlock-object sa-load-shared-object
sa-foreign-entry? sa-foreign-entry-address sa-foreign-callable-entry-point
sa-foreign-procedure-runtime sa-foreign-procedure
sa-foreign-procedure-native-error sa-foreign-procedure-blocking
```

Two more constructor syntaxes are defined by both adapters but MISSING from
CONTRACT.txt (gap, flagged for the P1b designer): `sa-foreign-callable`
(`host/chez/scheme-adapter-runtime.ss:948`, `host/gambit/scheme-adapter-runtime.ss:358`)
and `sa-foreign-callable-collect-safe` (chez:962 / gambit:365). The narrative
`host/scheme-adapter/TARGET-CONTRACT.md:21-22` still says "the four
`sa-foreign-*` syntaxes" — the wording astra called INCOMPLETE. Actual
constructor surfaces a target must supply or refuse: 4 syntaxes +
`sa-foreign-procedure-native-error` + `sa-foreign-procedure-runtime` + 2
callable syntaxes = **7**, plus the target-internal `jolt-ffi-native-error-procedure`
convention selector (`host/chez/rt.ss:359-367`; Gambit adapter defines its own
refusing one at `host/gambit/scheme-adapter-runtime.ss:339-343`).

Gambit adapter status on this SHA (`host/gambit/scheme-adapter-runtime.ss`):
the entire ffi tier raises `sa-ffi-raise` (313-314) — sa-foreign-procedure
321-324, native-error 331-334, blocking 349-352, callable 358-360,
callable-collect-safe 365-367, procedure-runtime 374-375, data plane 381-420,
pins 428-435, loader 440-461. All message-carrying
(`"ffi is unsupported on the gambit target"`).

### Backend primitive table (astra §2 item)

`target-prims` moved from backend_scheme.clj to
`jolt-core/jolt/backend_scheme/session.clj:76-78`:

```clojure
(def ^:private target-prims
  {:chez {:unsafe-prefix "#3%"}})
(defn unsafe-prefix [] (get-in target-prims [(target) :unsafe-prefix]))
```

- Astra cited backend_scheme.clj:297 — moved (this file is 1714 lines; see §5).
- What a `:gambit` entry must carry: `{:unsafe-prefix ""}` — exactly astra's
  ruling. Today `:gambit` is absent and the lookup answers `nil`; every
  spelling site string-concatenates the prefix (`backend_scheme.clj:1248-1249`
  flonum cast window, `backend_scheme/calls.clj:152` PIC probe; seven sites
  per session.clj:70-74), so `(str nil)` degrades to the checked op by
  accident. `host/gambit/gen-seed.ss:34-35` documents the degradation;
  `host/gambit/eval-test.ss:269-279` pins that `^double` emission carries no
  `#3%`. The explicit `:gambit {:unsafe-prefix ""}` entry is still OPEN work
  (P1, not P1b).

---

## 4. What the Gambit target does TODAY with each construction path (static reading)

1. **Pointer-call bindings** — refused at compile time with a jolt-level
   message (ffi.clj:625-628). Good.
2. **By-value callables** — refused at compile time (ffi.clj:763-771). Good.
3. **Scalar callables** — emit `(jolt-ffi-register-callable! (sa-foreign-callable …))`;
   on gambit `sa-foreign-callable` is the refusing macro
   (gambit adapter:358-360) and is evaluated before the unbound register call
   (argument evaluation first), so the documented refusal fires. Good — but
   only because of evaluation order, not by construction.
4. **Named scalar/aggregate fns** — the emitted `(or p …)` first-call body
   references `jolt-ffi-dlsym-native` and bare `foreign-procedure` (ffi.clj:483-491).
   The gambit boot manifest excludes `host/chez/java/ffi.ss` entirely
   (host/gambit/boot.ss ##include list, lines 47-104: regex-translate,
   jdk-interfaces, class-hierarchy, records-interop, host-class, java-parse,
   math, class-model, string-builder, dot-forms, jutil-colls, tree-map,
   byte-buffer — no ffi.ss), and gsi has no `foreign-procedure` form. **First
   call therefore dies on an UNBOUND VARIABLE, not the documented
   message-carrying unsupported error.** GAP G-3: the compiler needs a
   `:gambit` arm in `ffi-named-procedure-expr` (or an adapter-bound
   `foreign-procedure` that raises the documented way) so unregistered shapes
   "raise deliberately, rather than reach an unbound Chez identifier"
   (astra §2, verbatim requirement).
5. **Layouts (`:ffi-layout`)** — emitted `(define-ftype …)` /
   `(make-ftype-pointer …)` are unbound on gambit; a `(def … (ffi/layout …))`
   on the gambit target raises unbound at namespace load. GAP G-1: no gambit
   guard in `emit-ffi-node` for `:ffi-layout` (ffi.clj:758-772 guards only
   pointer fns and by-value callables).
6. **Bare varargs** — the cache constructor references
   `jolt-ffi-varargs-cache` (unbound on gambit); first call raises unbound.
   Covered by the same GAP G-3 arm.
7. **`jolt build --library` launcher** — build.ss:4647-4653 emits Chez-only
   callable/foreign-procedure text; stays Chez-only (AOT refused on gambit).

---

## 5. Cross-check of astra's citations against THIS fork SHA

| Astra citation | Status on a6852ef8 | Actual |
|---|---|---|
| `backend_scheme.clj:2134` scoped symbol calls emit raw Chez `foreign-procedure` | MOVED (backend_scheme.clj is 1714 lines) | `jolt-core/jolt/backend_scheme/ffi.clj:488-491` (`ffi-named-procedure-expr`, scoped branch); file split into `backend_scheme/` subdirectory |
| `backend_scheme.clj:297` only-Chez primitive-table entry | MOVED | `jolt-core/jolt/backend_scheme/session.clj:76-78` (`target-prims` `{:chez {:unsafe-prefix "#3%"}}`) |
| `host/chez/java/ffi.ss:1294` runtime varargs eval construction | MOVED (line is now inside the carrier comment block) | `host/chez/java/ffi.ss:1373-1386` (`ffi-varargs-compile`); convention helpers 1364-1371 |
| `host/gambit/scheme-adapter-runtime.ss:321-459` refusals | HOLDS (±2 lines) | refusal tier spans 307-461; `sa-foreign-procedure` refusal starts at 321, `sa-foreign-callable-entry-point` ends at 461 |
| `sa-gc-collect` no-op ~81 | HOLDS EXACTLY | `host/gambit/scheme-adapter-runtime.ss:81-82` — `(define (sa-gc-collect) #f)` |
| "Gambit's boot excludes the FFI runtime" | HOLDS | gambit boot ##include list has no java/ffi.ss (host/gambit/boot.ss:47-104); adapter comment at gambit adapter:17-19 states the manifest exclusion |
| "four sa-foreign-* syntaxes" contract wording | HOLDS — and is worse | TARGET-CONTRACT.md:21-22 still says four; actual constructor surfaces are 7 (§3); CONTRACT.txt's capability-ffi tier additionally OMITS sa-foreign-callable / -collect-safe |

## 6. Site counts (headline)

- Compiler construction sites (§1): **22** sub-sites across 8 constructors
  (named×3, pointer×3, fixed-fn assembly, bare-varargs×3, callable×5,
  layout×1) + 13 compile-time refusal rows (§1.8) + 17 shadow-guard names (§1.9).
- Runtime construction sites (§2): **2** dynamic `eval` constructors
  (ffi-varargs-compile; sa-foreign-procedure-runtime) + **2** adapter-internal
  constructor macros (jolt-foreign-proc-safe/-blocking) + ~180 adapter-internal
  bootstrap binding sites (16 files) + **16** direct foreign-procedure sites
  inside the Chez adapter file + scoped-address chain (4 sites) + callable
  machinery (6 sites).
- Adapter contract surface: 18 CONTRACT.txt names + 2 unlisted callable
  syntaxes + 1 target-internal convention selector.
