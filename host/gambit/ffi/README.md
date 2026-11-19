# Gambit native FFI: stage 1 (partial)

This tier implements native memory, scoped loading, registered ordinary calls,
invocation-local errno capture, and real `##gc`. It is qualified here only on
**macOS arm64, the provisioned single-threaded Gambit 4.9.8**. P2/P3 consumers
remain Chez-only. It does not provide GC-safe blocking or callbacks.

Run from the checkout root:

```sh
GAMBIT_PREFIX=/Users/sto/.local/share/mise/installs/gambit/4.9.8
make gambitffi gambitcheck gambitkernel gambiteval GAMBIT_PREFIX="$GAMBIT_PREFIX"
make gambitseedcheck CHEZ=/Users/sto/.local/share/mise/installs/chezscheme/10.4.1/bin/scheme
```

All new FFI gates fail if their toolchain or bridge is absent. `gambitcheck`
requires the bridge and runs both its adapter checks and the public-source
witness. The ABI target also runs that public witness. Every native artifact
is rebuilt on each make invocation, after input and toolchain digest checks.
A timed-out gate kills its process group and returns 124.

## Build and ABI identity

`shapes.json` is the reviewed stage-1 projection of the 44-shape inventory
`p1b-inv/shim-registry.edn` at fork `a6852ef8`. It includes ordinary procedure
shapes S01/S01b/S02/S03/S12/S12b/S13/S18/S19/S20/S21/S22/S22b/S22c/S23/
S26/S26b/S26c/S26d/S26e, the S32 declared-tail fixture (two fixed arguments),
and thirteen explicit scalar identity fixtures. S19 and S20 share one ABI.
Blocking/callable/pointer-call/aggregate/bare-varargs shapes are refused.
Other shapes are deliberately rejected; this is not unrestricted FFI.

`generate-shims.py` emits `generated-shims.scm` from that manifest. Identity
includes argument types, result type, capture mode, and **variadic boundary**.
Fixed `(int,int,int)` and variadic `(int,int,...)` must use different C types
on Apple arm64. Chez `integer-32` tokens map to Gambit `int32` conversions.
Pointers cross as exact integers; static assertions require LP64.

After an intentional input change:

```sh
python3 host/gambit/ffi/generate-shims.py
sh host/gambit/ffi/make-digests.sh
```

`DIGESTS.txt` pins source/generated inputs. `TOOLCHAIN.sha256` pins the
provisioned gsi/gsc, C build driver, header, and runtime/compiler libraries.
It intentionally rejects another runtime/configuration: a new platform leg
must establish a new qualification record. `build/gambit-ffi/` contains output
SHA256 records, compiler version, runtime hashes and retained generated C.
Binary digests are recorded, not claimed identical across machines/linkers.
No runtime sources or dependencies are modified or downloaded.

## Public path and limits

`gambitffi-public.ss` boots the fork's actual `host/gambit/boot.ss` and reminted
compiler seed, asserts `(jolt.backend-scheme.session/target) => :gambit`, then
runs jolt source through `jolt-compile-eval`. It covers host-owned `jolt.ffi`
memory/loader functions and the public compiler's low-level `__cfn` form:
ordinary, declared-tail variadic, nullable string, float, bool, exact-width and
errno-pair calls. It checks catchable layout, named-binding, blocking+errno,
aggregate, callable and bare-tail refusals, plus loader diagnostics.

Gambit eval cannot see unit-local macros. Emitted code therefore calls the
host's `joltffi-public-procedure`, which invokes the adapter's finite registry
constructors with literal type data and translates native errors into
message-carrying jolt exceptions. Adapter `sa-foreign-*` syntaxes remain
available to same-unit Scheme callers. No `c-lambda` is evaluated at runtime.
The `:gambit` primitive table explicitly selects the empty unsafe-op prefix.

This is the fork's compiler/eval gate path, not `bin/jolt build`: the build CLI,
AOT/FASL/subprocess, module/native dependency loading and complete stdlib
`jolt.ffi` namespace loading are not qualified on Gambit. Explicit library
loading works; pending `:jolt/native` discovery is not implemented. Public
jolt-array copy helpers remain refused because this boot excludes their
runtime; adapter u8vector bulk copies and public string-byte copies work.
String arguments remain refused; native copies via `string->ptr` work.
No Web/JS, Linux, MT, or native consumer parity is claimed.

The real collector witness clears an unreachable weak key. It does not test
collection during C execution. Bulk copies borrow Scheme storage only for a
short non-allocating synchronous call and retain no borrowed address.
Object pinning is refused.

## Errno proof

Every generated capture shim executes target call, immediate `saved = errno`,
then writes a caller-owned cell, before Gambit conversion or cleanup. The
adapter allocates one cell before the call and frees it with `dynamic-wind`,
including conversion failure; ordered `let*` reads only after the wrapper.
There is no shared last-errno slot.

The errno target builds the same generator output with
`JOLTFFI_CAPTURE_TEST`: every capture body clobbers errno *after* saving it.
The gate asserts that instrumentation is enabled. A deliberately wrong control
calls the same failing target and saves *after* an identical clobber; it must
observe 4242, while the actual shim must observe the target's EACCES. Success
with an errno-setting target, a preset-and-preserving C-frame control,
post-capture clobber, and 1000 alternating result pairs are checked too.
Alternating calls are stress coverage, not proof of native concurrency,
reentrant callbacks, or blocking-plus-errno.

## Inventory questions

- Q1/Q2: layout and by-value emission refuse before Chez ftype forms; named
  bindings use the registry, preserve variadic identity, and refuse with a
  message for unknown signatures. Public tests prevent unbound-name failures.
- Q3: parser worker destruction's unmarked join remains a consumer issue for
  P3. S18 only qualifies the ABI with a nonblocking fixture, not that consumer.
  Do not enable parser workers on this evidence; re-mark or separately qualify
  the wait before P3 adoption.
- Q4: explicit `:gambit {:unsafe-prefix ""}` entry implemented and reminted.
- Q5: both callable syntaxes added to CONTRACT.txt; refusal assertions retained.
- Q6: unmarked SSL waits remain unqualified; no libssl binding/consumer parity
  is established by ordinary-call shape support. Address marks in its consumer
  lane before adoption.

Rollback is a revert of the stage-1 commits, followed by removing the generated
`build/gambit-ffi/` directory. No installed Gambit runtime is changed.
