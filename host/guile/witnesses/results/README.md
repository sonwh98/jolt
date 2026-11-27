results/ — recorded witness outputs.

Overwritten ONLY by ../run-all.sh after a run under ../watchdog.sh, in the
p1a recording shape:

    ### cmd: ./watchdog.sh N guile --no-auto-compile .../wN.scm
    <verbatim witness output>
    ### exit=0

r2 run (2026-11-27, darwin-arm64, guile 3.0.11): 13/13 witnesses PASS
(RUN-ALL: PASS). The r1 staging session could not execute anything; the
first executed run found the witnesses broken; every defect was repaired
in r2 (see ../AUDIT.md, Run state) before this recording.
