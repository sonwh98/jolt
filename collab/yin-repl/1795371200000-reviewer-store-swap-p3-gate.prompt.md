Created-GMT: 2026-11-22 17:55:00 GMT
Created-Local: 2026-11-23 00:55:00 ICT (+07)
Coding-Agent: interactive (ZCode / glm-5.3-flash, orchestrator seat)
Session-ID: 1ba02c6c-a8d3-4eea-8377-14aff23bf770

# Task: store-swap Slice 3 — adversarial implementation review (Gambit overlay)

Role: Review (adversarial)

Implementers:
- Model: glm-5.3 | Assigned: 2026-11-23 00:55 ICT | Status: active | Rationale: different family from the Gemini author (reviewer independence); flat subscription

You are reviewing UNCOMMITTED changes in the Jolt fork worktree
/Users/sto/workspace/jolt-store-swap, branch gambit-ffi-p1-store-swap:
- git diff   (run it yourself; two files: host/gambit/yin/jolt/gambit/yin.jolt,
  test/gambit/yin-repl-session.sh)

Read first (in this worktree):
- collab/yin-repl/1795360785000-architect-store-swap-design.gemini-4-argon-high.findings.md
  (the design contract; Decision 5 and file-spec item 6 cover this slice)
- collab/yin-repl/1795367167000-engineer-store-swap-p3-gambit.gemini-4-argon-high.findings.md
  (the implementer's report, including declared deviations and the PASS transcript)

Adjudicate:
1. Fidelity to Decision 5: dht-scheme as plain data with no yin.shell.dht /
   dao.stream.udp require; startup :parse-store-arg unchanged; open-gambit
   calling (posix-file/realpath dir) BEFORE any java.io.File call on :file/:dht
   specs; :mem path preserving jolt.ffi and dao.jing.mem host modules;
   :composition-spec? (constantly true) implications — check this does not
   hijack startup behavior or break non-swap paths on Gambit.
2. The parse-swap-command contract vs what the datomworld driver
   (yin.repl.main/swap-store, branch store-swap-p1) expects (:parse-store-command
   returning {:spec spec :opts opts :label label}) — argument-grammar parity
   with the design's grammar for the Gambit subset (no trailing opts on :mem).
3. The transcript state machine: does each step assert what the design's
   Decision 5 failure story requires (quiesce refusal + survival, exact C4
   message for both file: and dht:, mem swap success, host-module availability
   after the rebuild, clean exit 0)? Are the implementer's two declared
   deviations acceptable?
4. Defect hunt: double-open/double-close on the mem swap path; error swallowing
   that could turn the C4 refusal into a crash; anything that weakens the C4
   boundary (the refusal is the feature — no blocking-FFI qualification).

Verification already done (do NOT re-run the build): make gambityinrepl PASS on
macOS arm64, exit 0, transcript per the implementer's findings. The Linux x86_64
leg is deferred to the upgrade gate. Do not edit any file.

## Deliverable

Write findings to
collab/yin-repl/1795371200000-reviewer-store-swap-p3-gate.glm-5.3.findings.md
in this worktree. Format: severity | file:line | evidence | recommended
correction. End with an explicit verdict line: APPROVED or CHANGES-REQUIRED.

If you cannot write the file, print the complete findings in your final
response instead and say that you could not write it.

Begin the final response exactly with:
Completed-GMT: <YYYY-MM-DD HH:MM:SS GMT>
Completed-Local: <YYYY-MM-DD HH:MM:SS local-timezone-name>

Then: findings summary and the verdict line.
