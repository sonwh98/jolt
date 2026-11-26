#!/bin/sh
# Run the stock launcher and the same composition with a diagnostic host module.
# Arguments are absolute paths. Build the bridge and compiled boot first.
set -eu

gsi=$1
datomworld=$2
export JOLT_GAMBIT_YIN_BOOT=$3
mode=${4:-both}
export JOLT_TRACE_SOURCE=1
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo"
mkdir -p build/gambit-dht
run=$(mktemp -d "$repo/build/gambit-dht/run.XXXXXX")
echo "gambitdht receipts: $run"

session() {
  name=$1
  status=0
  started=$(date +%s)
  sh "$repo/host/gambit/ffi/watchdog.sh" "${GAMBIT_DHT_TIMEOUT_SECONDS:-2400}" \
    "$gsi" "$repo/host/gambit/yin-repl-native.ss" "$datomworld" \
    --no-state --index-store dht: >"$run/$name.stdout" 2>"$run/$name.stderr" || status=$?
  echo "$status" >"$run/$name.status"
  cat "$run/$name.stdout"
  echo "$name launcher exit $status ($(($(date +%s) - started))s)"
  if [ "$status" -ne 0 ]; then
    tail -30 "$run/$name.stderr" >&2
    return "$status"
  fi
}

stock() {
  session stock <<'FORMS'
(+ 20 22)
(quit)
FORMS
  grep -Fx 'yin> 42' "$run/stock.stdout" >/dev/null
  grep -Fx 'yin> Bye' "$run/stock.stdout" >/dev/null
  test "$(grep -c '^yin> ' "$run/stock.stdout")" -eq 2
  grep -E 'ready dao[.]space[.]dht$' "$run/stock.stderr" >/dev/null
  echo "gambitdht: PASS — stock launcher opened dht: and quit"
}

diagnostics() {
  # Extend the session's host modules. The same native launcher and open-store
  # path initialize the session, and the fixture observes its actual handle.
  overlay="$run/jolt"
  mkdir -p "$overlay/host/gambit"
  cp -R "$repo/host/gambit/yin" "$overlay/host/gambit/yin"
  cat "$repo/test/gambit/fixtures/yin-dht-probe.jolt" >>"$overlay/host/gambit/yin/jolt/gambit/yin.jolt"
  for name in build stdlib jolt-core; do
    ln -s "$repo/$name" "$overlay/$name"
  done
  cd "$overlay"

  session diagnostics <<'FORMS'
(+ 20 22)
(require 'p1e.probe)
(p1e.probe/run :session-round-trip)
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

  awk '
    /^yin> 42$/ && step == 0 { step++; next }
    /^yin> \047p1e[.]probe$/ && step == 1 { step++; next }
    /^yin> \[ *:dht-index-put-get :segment\/blake3-[0-9a-f]+ \{:p1e "yin-dht-local-round-trip", :count 3\} *\]$/ && step == 2 { step++; next }
    /^yin> :memory-dht-handle-opened$/ && step == 3 { step++; next }
    /^yin> :segment\/blake3-[0-9a-f]+$/ && step == 4 { step++; next }
    /^yin> \{:p1e "yin-dht-local-round-trip", :count 3\}$/ && step == 5 { step++; next }
    /^yin> true$/ && step == 6 { step++; next }
    /^yin> \[ *:udp-loopback-ok "Kv8A" :closed *\]$/ && step == 7 { step++; next }
    /^yin> :socket-native-loaded$/ && step == 8 { step++; next }
    /^yin> Error: .*blocking ffi is unsupported on the gambit target/ && step == 9 { step++; next }
    /^yin> :closed$/ && step == 10 { step++; next }
    /^yin> 43$/ && step == 11 { step++; next }
    /^yin> Bye$/ && step == 12 { step++; next }
    /^yin> / { unexpected = 1 }
    END { exit !(step == 13 && !unexpected) }
  ' "$run/diagnostics.stdout" || {
    echo "gambitdht: the probe did not produce the expected replies" >&2
    exit 1
  }
  echo "gambitdht: PASS — selected DHT index put/get, portable replication request, UDP loopback and close, C4 refusal, clean quit"
}

case "$mode" in
  stock) stock ;;
  diagnostics) diagnostics ;;
  both) stock; diagnostics ;;
  *) echo "usage: $0 GSI DATOMWORLD_ROOT BOOT [stock|diagnostics|both]" >&2; exit 2 ;;
esac
