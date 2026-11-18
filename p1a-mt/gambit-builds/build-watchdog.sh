#!/bin/sh
# build under external watchdog: kill after N seconds, record exit
n="$1"; shift
log="$1"; shift
cd /Users/sto/workspace/jolt-ffi-mt/p1a-mt/gambit-builds/mt
( /usr/bin/time -p make -j8 core ) > "$log" 2>&1 &
pid=$!
( sleep "$n"; kill -9 "$pid" 2>/dev/null; echo "BUILD-WATCHDOG: TIMEOUT after ${n}s" >> "$log" ) &
wd=$!
wait "$pid"; st=$?
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
echo "### make-exit=$st" >> "$log"
echo "make exit=$st"
