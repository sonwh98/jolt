#!/bin/sh
# run-all.sh — run every Phase 2a Guile witness under the external watchdog,
# record verbatim outputs under results/, and verify the expected verdict
# markers (a missing or wrong marker fails the run).
#
# Usage:   sh run-all.sh [witness-name ...]   (no args = all)
# Env:     GUILE  (default /opt/homebrew/opt/guile/bin/guile; also read by
#          the witnesses themselves for self-spawning probes)
#
# w7-fthread.scm builds its own C fixture via cc + pkg-config guile-3.0.
#
# Recording contract (p1a precedent): results/*.out are overwritten ONLY by
# this script, and every recorded run is under watchdog.sh — a deadlock is
# a recorded failure (exit 124 line), never a hang.

set -u

GUILE="${GUILE:-/opt/homebrew/opt/guile/bin/guile}"
HERE=$(cd "$(dirname "$0")" && pwd)
RES="$HERE/results"
cd "$HERE"

mkdir -p "$RES"

# name:timeout:expected-marker — markers must contain no spaces/colons
# (they are grepped with -qF against results/<name>.out; every witness
# prints "<marker>: PASS" or "<marker>: FAIL ...").
ALL="\
w0-platform:60:W0-VERDICT\
 w1-reader:60:W1-VERDICT\
 w2-threads:120:W2-VERDICT\
 w3-escape:60:W3-VERDICT\
 w4-errno:60:W4-VERDICT\
 w5-blocking-gc:90:W5-VERDICT\
 w6-gc-pinning:60:W6-VERDICT\
 w7-fthread:90:W7-VERDICT\
 w8-files:60:W8-VERDICT\
 w9-net:90:W9-VERDICT\
 w10-compile:120:W10-VERDICT\
 w11-crypto:90:W11-VERDICT\
 w12-perf:120:W12-VERDICT\
"

# w7-fthread.scm builds its own C fixture (w7-fixture.c, via cc +
# pkg-config guile-3.0) and runs both modes itself; no special casing here.

# One recorded run: record <name> <timeout> <marker>
record() {
    name=$1; tmo=$2; marker=$3
    out="$RES/$name.out"
    echo "### cmd: ./watchdog.sh $tmo $GUILE --no-auto-compile $HERE/$name.scm" > "$out"
    ./watchdog.sh "$tmo" "$GUILE" --no-auto-compile "$HERE/$name.scm" >> "$out" 2>&1
    st=$?
    echo "### exit=$st" >> "$out"
    cat "$out"
    case $st in
        0) if grep -qF -- "$marker: PASS" "$out"; then
               echo "verify: OK   $name :: [$marker: PASS]"
           else
               echo "verify: FAIL $name :: missing [$marker: PASS]"
               FAIL=1
           fi ;;
        *) echo "verify: FAIL $name :: exit $st (watchdog/witness failure)"; FAIL=1 ;;
    esac
}

FAIL=0
if [ $# -eq 0 ]; then
    for spec in $ALL; do
        IFS=: read -r name tmo marker <<EOF
$spec
EOF
        record "$name" "$tmo" "$marker"
    done
else
    for want in "$@"; do
        for spec in $ALL; do
            IFS=: read -r name tmo marker <<EOF
$spec
EOF
            [ "$name" = "$want" ] || continue
            record "$name" "$tmo" "$marker"
        done
    done
fi

if [ "$FAIL" -ne 0 ]; then
    echo "RUN-ALL: FAIL (verdict markers missing or witness failures — see $RES/)"
    exit 1
fi
echo "RUN-ALL: PASS (every expected verdict marker present in $RES/)"
