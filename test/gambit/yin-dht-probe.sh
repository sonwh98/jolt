#!/bin/sh
# Capture the stock CLI and then probe each underlying path in a live Yin REPL.
# Arguments are absolute paths. Build the bridge and compiled boot first.
set -eu

gsi=$1
datomworld=$2
export JOLT_GAMBIT_YIN_BOOT=$3
export JOLT_TRACE_SOURCE=1
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo"
mkdir -p build/p1e
run=$(mktemp -d "$repo/build/p1e/run.XXXXXX")
echo "P1e receipts: $run"
mkdir "$run/store"
export JOLT_P1E_STORE="$run/store"

session() {
  name=$1
  shift
  status=0
  started=$(date +%s)
  sh "$repo/host/gambit/ffi/watchdog.sh" "${P1E_TIMEOUT_SECONDS:-900}" \
    "$gsi" "$repo/host/gambit/yin-repl-native.ss" "$datomworld" \
    --no-state --index-store "$@" >"$run/$name.stdout" 2>"$run/$name.stderr" || status=$?
  echo "$status" >"$run/$name.status"
  cat "$run/$name.stdout"
  echo "$name launcher exit $status ($(($(date +%s) - started))s)"
}

session stock "dht:$JOLT_P1E_STORE" <<'FORMS'
(+ 20 22)
(quit)
FORMS

# Only the entry composition is extended, inside a scratch source root. The
# launcher, other host adapters, boot, and Datomworld source stay the same.
overlay="$run/jolt"
mkdir -p "$overlay/host/gambit"
cp -R "$repo/host/gambit/yin" "$overlay/host/gambit/yin"
cat "$repo/test/gambit/fixtures/yin-dht-probe.jolt" >>"$overlay/host/gambit/yin/jolt/gambit/yin.jolt"
for name in build stdlib jolt-core; do
  ln -s "$repo/$name" "$overlay/$name"
done
cd "$overlay"

session diagnostics mem <<'FORMS'
(+ 20 22)
(require 'p1e.probe)
(p1e.probe/run :shell-open)
(p1e.probe/run :durable-put)
(p1e.probe/run :durable-get)
(p1e.probe/run :directory-open)
(p1e.probe/run :memory-open)
(p1e.probe/run :memory-put)
(p1e.probe/run :memory-get)
(p1e.probe/run :replicate-request)
(p1e.probe/run :udp-loopback)
(p1e.probe/run :udp-native-load)
(p1e.probe/run :c4-control)
(p1e.probe/run :close)
(+ 40 3)
(quit)
FORMS

# An expected capability refusal is an observation. Missing replies, a crash,
# or the watchdog deadline make the evidence run fail.
test "$(cat "$run/diagnostics.status")" -eq 0
test "$(cat "$run/stock.status")" -lt 124
test "$(grep -c '^yin> ' "$run/diagnostics.stdout")" -eq 16
grep -Fx "yin> 'p1e.probe" "$run/diagnostics.stdout" >/dev/null
grep -Fx 'yin> 43' "$run/diagnostics.stdout" >/dev/null
grep -Fx 'yin> Bye' "$run/diagnostics.stdout" >/dev/null
