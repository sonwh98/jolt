#!/bin/sh
# watchdog.sh N CMD... — run CMD under an external watchdog.
#
# If CMD has not exited within N seconds it is SIGKILLed, the script prints
# "WATCHDOG: TIMEOUT ..." on stderr and exits 124, so a deadlock (e.g. the
# whole Gambit VM frozen inside a blocking foreign call) is a recorded
# FAILURE, never a hang.
#
# The Gambit VM has exactly one OS thread running Scheme execution in the
# provisioned build, so a Scheme-internal timeout CANNOT fire while a foreign
# call is blocked — the watchdog must be external to the witness process.

n="$1"; shift

"$@" &
pid=$!

( sleep "$n"; kill -9 "$pid" 2>/dev/null ) &
wd_pid=$!

wait "$pid"
st=$?

kill "$wd_pid" 2>/dev/null
wait "$wd_pid" 2>/dev/null

if [ "$st" -eq 137 ]; then
  echo "WATCHDOG: TIMEOUT after ${n}s — SIGKILLed: $*" >&2
  exit 124
fi
exit "$st"
