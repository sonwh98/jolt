Created-GMT: 2026-11-22 17:08:37 GMT
Created-Local: 2026-11-23 00:08:37 ICT (+07)
Completed-GMT: 2026-11-22 17:48:30 GMT
Completed-Local: 2026-11-23 00:48:30 ICT (+07)
Coding-Agent: agy
Session-ID: a65337a3-0946-411f-abd2-32736aa26803

# Task: store-swap Slice 3 — Gambit honest degradation for `(use-store ...)`

Role: VM / Storage Engineer (implementation)

Implementers:
- Model: gemini-4-argon-high (fallback for gpt-6.2-sol after provider usage limit) | Assigned: 2026-11-23 00:08 ICT | Status: completed | Rationale: continuation of the store-swap track in the Jolt fork worktree `gambit-ffi-p1-store-swap`

---

## 1. Changes Made (`file:line`)

### [yin.jolt](file:///Users/sto/workspace/jolt-store-swap/host/gambit/yin/jolt/gambit/yin.jolt)
- **Line 4**: Added `[dao.posix.file :as posix-file]` to `:require` (loads `host/gambit/yin/dao/posix/file.jolt`, which routes all durable file calls to `joltffi-public-blocking-raise`). No require of `yin.shell.dht` or `dao.stream.udp`.
- **Lines 11–15**: Defined plain-data `dht-scheme` descriptor `{:prefix "dht:" :label "dht:<dir>" :type :dht :parse (fn [dir] {:type :dht :dir dir})}`.
- **Lines 38–42**: Added `open-gambit [spec opts]`:
  - When `(= :mem spec)`: delegates to `(open-memory spec opts)` so a fresh `:mem` store is opened and `:engine-inputs {:host-modules {'jolt.ffi activate-ffi 'dao.jing.mem activate-store}}` is preserved across the swap.
  - Otherwise (`:file` or `:dht` carrying `:dir`): calls `(posix-file/realpath (:dir spec))` first, which invokes `host/gambit/yin/dao/posix/file.jolt`'s `refuse-blocking` (`joltffi-public-blocking-raise`) and raises the C4 blocking-FFI refusal before any `java.io.File` constructor or `yin.shell.dht` load.
- **Lines 44–49**: Retained `parse-store` unchanged for CLI startup `:parse-store-arg` (startup `--index-store file:...` or `dht:...` continues to fail startup with exit status 1).
- **Lines 51–67**: Added `parse-swap-command` matching `yin.repl.main/swap-store`'s `:parse-store-command` contract:
  - Validates non-empty arguments and `:mem` / string target.
  - Parses target via `(store/parse-arg target [dht-scheme])`.
  - Validates trailing keyword-value pair structure and refuses trailing options when `(not= :dht (:type spec))` (including `:mem` and `:file`).
  - Returns `{:spec spec :label target}`.
- **Lines 69–73**: Updated `-main` composition map to `{:composition-spec? (constantly true) :parse-store-arg parse-store :parse-store-command parse-swap-command :open open-gambit}`.

### [yin-repl-session.sh](file:///Users/sto/workspace/jolt-store-swap/test/gambit/yin-repl-session.sh)
- **Lines 24–32**: Extended input forms after `(dao.jing.mem/materialize-sha256 {:witness 1})` with the Decision 5 store-swap transcript:
  1. `(use-store "file:/tmp/gambit-nope")` on dirty session → quiesce refusal.
  2. `(+ p1c-score 1)` → `101` (verifies session state survives the refused swap).
  3. `(reset)` → `SemanticVM reset`.
  4. `(use-store "file:/tmp/gambit-nope")` → C4 blocking-FFI refusal.
  5. `(use-store "dht:/tmp/gambit-nope")` → C4 blocking-FFI refusal.
  6. `(use-store "mem")` → `Switched index store to mem (code index cleared)`.
  7. `(+ 21 22)` → `43`.
  8. `(require 'jolt.ffi)` → `'jolt.ffi` and `(jolt.ffi/sizeof :int32)` → `4` (verifies `jolt.ffi` host module registration survived the `:mem` store swap).
  9. `(quit)` → `Bye`.
- **Lines 53–69**: Extended the ordered `awk` state machine from 12 steps to 20 steps (`step == 20 && !unexpected`) and updated the pass banner.

---

## 2. Verification Commands & Outcomes

### Platform: macOS arm64 (`darwin-arm64`)

1. **Record Gambit toolchain provenance & initialize submodules in the worktree**:
   ```sh
   sh host/gambit/ffi/record-toolchain.sh /Users/sto/.local/share/mise/installs/gambit/4.9.8
   make submodules
   ```
   - Outcome: exit 0 (`recorded local toolchain provenance (7 inputs); source digests unchanged`, 7 vendor submodules checked out).

2. **Run `make gambityinrepl` against `../datomworld-store-swap` (where Slices 1–2 are staged)**:
   ```sh
   make gambityinrepl GAMBIT_PREFIX=/Users/sto/.local/share/mise/installs/gambit/4.9.8 DATOMWORLD_ROOT=../datomworld-store-swap
   ```
   - Outcome: **PASS (exit code 0)**.

### Transcript Output

```text
boot: backend target -> :gambit
Host: jolt / Gambit v4.9.8
python: unavailable-parser (the native parser library is missing or incompatible; bb build:jolt-native)
yin> 3
Warning: this round's code is not in the published code index (project failed)
yin> 49
Warning: this round's code is not in the published code index (project failed)
yin> 100
Warning: this round's code is not in the published code index (project failed)
yin> 101
Warning: this round's code is not in the published code index (project failed)
yin> Error: Divide by zero
Warning: this round's code is not in the published code index (project failed)
yin> Error: unavailable-parser: Yin REPL language :yang/python is not in the frontend catalog; installed: :clojure (ids :yang/clojure)
yin> 'jolt.ffi
Warning: this round's code is not in the published code index (project failed)
yin> 4
Warning: this round's code is not in the published code index (project failed)
yin> 'dao.jing.mem
Warning: this round's code is not in the published code index (project failed)
yin> Error: blocking ffi is unsupported on the gambit target — GC-safe blocking is unqualified on Gambit 4.9.8 (no verified release/claim transition)
Warning: this round's code is not in the published code index (project failed)
yin> Error: cannot switch index store while the session holds evaluated state; run (reset) first
yin> 101
Warning: this round's code is not in the published code index (project failed)
yin> SemanticVM reset
yin> Error: blocking ffi is unsupported on the gambit target — GC-safe blocking is unqualified on Gambit 4.9.8 (no verified release/claim transition)
yin> Error: blocking ffi is unsupported on the gambit target — GC-safe blocking is unqualified on Gambit 4.9.8 (no verified release/claim transition)
yin> Switched index store to mem (code index cleared)
yin> 43
Warning: this round's code is not in the published code index (project failed)
yin> 'jolt.ffi
Warning: this round's code is not in the published code index (project failed)
yin> 4
Warning: this round's code is not in the published code index (project failed)
yin> Bye

gambityinrepl: PASS — Yin state, evaluation error, frontend refusal, FFI, blocking refusal, store swap, and clean quit
```

### Platform: Linux x86_64
- Not runnable from this macOS arm64 seat; to be verified via the orchestrator's Linux x86_64 / upgrade gate leg.

---

## 3. Deviations & Reasons

1. **`(require 'jolt.ffi)` before post-swap `(jolt.ffi/sizeof :int32)` in `test/gambit/yin-repl-session.sh`**:
   - Because `(use-store "mem")` rebuilds a fresh VM session (`make-session` -> `make-vm`), the VM's active symbol environment starts clean while `:host-modules` populates the VM's module registry (`:modules`). Just as after `(reset)` in `test/yin/repl/dht_test.cljc:2836`, guest code must evaluate `(require 'jolt.ffi)` in the new session to link the registered host module before calling `(jolt.ffi/sizeof :int32)`. Without `:host-modules` preserved by `open-gambit`, `(require 'jolt.ffi)` would fail/park; with `open-gambit` preserving `:host-modules`, `(require 'jolt.ffi)` returns `'jolt.ffi` immediately and `(jolt.ffi/sizeof :int32)` returns `4`.
2. **Added `(+ p1c-score 1)` → `101` immediately after the dirty `(use-store "file:/tmp/gambit-nope")` refusal**:
   - Explicitly verifies that the dirty-session quiesce refusal leaves existing VM bindings intact before `(reset)` is called, matching Decision 5's failure story.

---

## 4. Open Questions

- None. All changes in `/Users/sto/workspace/jolt-store-swap` are left uncommitted on branch `gambit-ffi-p1-store-swap` as instructed, and `/Users/sto/workspace/datomworld-store-swap` was not modified.
