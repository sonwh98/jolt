# P1b assoc-deftype parity

Session-ID: 01a1f1f9-2d2b-71a2-b88a-1675b81dd975

Applied `b389f1a7fb553f63a3494d71f8fe3251790bf4d3` to `gambit-ffi-p1b`
at `88630634`. The source commit changed only `host/chez/records-coll.ss`.
The cherry-pick conflicted in its `jolt-assoc1` arm. The resolution uses the
current interface cache's record flag (slot 3) to restrict field and extension
map writes to records. Declared `assoc` handlers still dispatch first, and
typed record fields still use the current cached coercion flags. A plain
deftype falls through to the existing class-naming `ClassCastException`.

`test/chez/unit.edn` adds `records-assoc-refusal` and uses a `defrecord` for
`records-assoc-double`, where the previous `deftype` relied on the bug. The
new test also runs through native gsi in `host/gambit/eval-test.ss`.

```clojure
(do (deftype AssocRefusal [x])
    (let [t (AssocRefusal. 1)]
      [(associative? t)
       (try (assoc t :b 2)
            (catch ClassCastException e (ex-message e)))]))
```

```text
[false "class user.AssocRefusal cannot be cast to class clojure.lang.Associative"]
```

The typed catch requires a `ClassCastException`. The same expression on pinned
Clojure 1.12.5 with JDK 21 returned `false` and the same class-naming message
prefix, followed by JVM class-loader details. A separate Chez probe asserted
`[2 3 4]` from declared deftype `assoc`, record field replacement and record
extension-map insertion respectively.

`make gambitgen` regenerated a one-line change to `records-gambit.ss`.
`gambitgencheck`, `gambitseedcheck`, and Chez `selfhost` passed. All four seed
files matched their checked-in bytes, and the FFI source digest index matched
the base. Regenerated `records-gambit.ss` SHA256 is
`c1bf1d777976a30e17b3dd20afb7930655790b44f36a6aa8cb7d48926ac85bb2`.

All watchdogged gates passed on macOS arm64 with Gambit 4.9.8 and Chez
10.4.1. `gambitffi` passed ABI 79/79, public 44/44, errno 9/9, and loader
14/14. `gambitcheck`, `gambitkernel`, and `gambiteval` reported zero failures.
`emittedheads` checked 249 heads and `deadhost` checked 7,472 procedures.
The full Chez unit suite passed 2,512/2,512, including both assoc suites.
Gambit printed the exact refusal result above. The native, generation and
seed, and unit runs used deadlines of 720s, 360s, and 900s respectively.
Logs are under `build/p1b-assoc-parity/`. The branch commit is local.
