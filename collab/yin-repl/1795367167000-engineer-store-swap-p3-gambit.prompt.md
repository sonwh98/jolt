Created-GMT: 2026-11-22 17:20:00 GMT
Created-Local: 2026-11-23 00:20:00 ICT (+07)
Coding-Agent: interactive (ZCode / glm-5.3-flash, orchestrator seat)
Session-ID: pending (codex provider-generated)

# Task: store-swap Slice 3 — Gambit honest degradation for (use-store ...)

Role: VM / Storage Engineer (implementation)

Implementers:
- Model: gpt-6.2-sol | Assigned: 2026-11-23 00:20 ICT | Status: active | Rationale: continuation of the store-swap track (slices 1-2 implemented by this lane and review-approved); Gambit overlay work needs the fork lineage

You are in the Jolt fork worktree /Users/sto/workspace/jolt-store-swap, branch
gambit-ffi-p1-store-swap, based on the gambit-ffi-p1c tip f22df3c7. The
yin.repl store-swap slices 1-2 landed in the datomworld side (yin.repl engine
+ composition) and are review-approved; this slice wires the Gambit side.

## Scope: implement Slice 3 EXACTLY as designed

The design contract is
collab/yin-repl/1795360785000-architect-store-swap-design.gemini-4-argon-high.findings.md
(in this worktree; see its Decision 5, the file spec item 6, and the failure
story transcript). Summary:

- host/gambit/yin/jolt/gambit/yin.jolt:
  - Require [dao.posix.file :as posix-file].
  - Define a plain-data dht-scheme descriptor {:prefix "dht:" :label
    "dht:<dir>" :type :dht :parse (fn [dir] {:type :dht :dir dir})} locally —
    NO require of yin.shell.dht or dao.stream.udp (they fail to load on Gambit;
    the P1e findings document why).
  - Keep CLI startup :parse-store-arg as-is (startup durable selection still
    fails with status 1 as P1e verified).
  - Provide :parse-swap-command (or equivalent composition hook the datomworld
    driver expects — read how yin.repl.main consumes :parse-store-command and
    match its contract; the composition map may need :composition-spec?
    (constantly true) and an :open that handles both) using
    (store/parse-arg target [dht-scheme]), refusing extra trailing options on
    :mem.
  - open-gambit: :mem → fresh mem store preserving jolt.ffi and dao.jing.mem
    host modules; :file/:dht spec with a dir → call
    (posix-file/realpath (:dir spec)) FIRST, which raises the exact C4
    blocking-FFI refusal (host/gambit/yin/dao/posix/file.jolt's refuse-blocking)
    before any java.io.File call and without loading yin.shell.dht.
- test/gambit/yin-repl-session.sh: extend the ordered transcript per the
  design's Decision 5 failure story (dirty quiesce refusal → reset →
  file:/dht: C4 refusal messages → (use-store "mem") success with host modules
  preserved → (+ 21 22) → 43 → (jolt.ffi/sizeof :int32) → 4 → quit exit 0).

## Boundaries

- Work ONLY in /Users/sto/workspace/jolt-store-swap, branch
  gambit-ffi-p1-store-swap. Do NOT touch the datomworld checkout or its
  jolt-toolchain.edn (the orchestrator owns the pin advance via the upgrade gate).
- Do not commit; leave changes uncommitted for review.
- C4 is binding: do NOT qualify blocking file FFI on Gambit. The refusal is
  the feature.

## Verification (foreground, explicit timeouts)

- make gambityinrepl (or the repo's documented equivalent) on macOS arm64 —
  the extended transcript must pass end to end with exit 0.
- Report the exact commands, the transcript tail, and the exit code.
- If the Linux x86_64 leg is not runnable from this seat, say so explicitly;
  it is verified later via the upgrade gate.

## Deliverable

Write your report to
collab/yin-repl/1795367167000-engineer-store-swap-p3-gambit.gpt-6.2-sol.findings.md
in this worktree: changes (file:line), exact commands + outcomes, the
transcript evidence, deviations with reasons, open questions. If the sandbox
blocks the write, stage at the worktree root under the same name and say so.

Begin the final response exactly with:
Completed-GMT: <YYYY-MM-DD HH:MM:SS GMT>
Completed-Local: <YYYY-MM-DD HH:MM:SS local-timezone-name>

Then: files changed, verification outcomes, deviations, findings path.
