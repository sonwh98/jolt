#!/bin/sh
# watchdog.sh N CMD... — run CMD under an external watchdog (p1a precedent).
#
# If CMD has not exited within N seconds it is SIGKILLed, the script prints
# "WATCHDOG: TIMEOUT ..." on stderr and exits 124, so a deadlock is a
# recorded FAILURE, never a hang.  The watchdog is external to the witness
# process on purpose: a witness that deadlocks the runtime cannot time
# itself out.
#
# Used by run-all.sh for every Phase 2a witness run.

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
