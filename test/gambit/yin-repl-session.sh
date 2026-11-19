#!/bin/sh
# Drive the upstream Yin entry point. A shell exit status alone never passes.
set -eu

gsi=$1
yin_root=$2
transcript=$(mktemp)
trap 'rm -f "$transcript"' EXIT

status=0
sh host/gambit/ffi/watchdog.sh 240 "$gsi" host/gambit/yin-repl-main.ss \
  "$yin_root" --no-state --index-store mem >"$transcript" <<'FORMS' || status=$?
(+ 1 2)
((fn [x] (* x x)) 7)
(def p1c-score 100)
(+ p1c-score 1)
(lang :yang/python)
(require 'jolt.ffi)
(jolt.ffi/sizeof :int32)
(+ 21 22)
(quit)
FORMS
cat "$transcript"
if [ "$status" -ne 0 ]; then
  echo "gambityinrepl: a complete Yin session was not observed (status $status)" >&2
  exit 1
fi

# Each line must follow the previous one, with prompts on the actual replies.
awk '
  /^yin> 3$/ && step == 0 { step++; next }
  /^yin> 49$/ && step == 1 { step++; next }
  /^yin> 100$/ && step == 2 { step++; next }
  /^yin> 101$/ && step == 3 { step++; next }
  /^yin> Error: unavailable-parser: Yin REPL language :yang\/python/ && step == 4 { step++; next }
  /^yin> \047jolt[.]ffi$/ && step == 5 { step++; next }
  /^yin> 4$/ && step == 6 { step++; next }
  /^yin> 43$/ && step == 7 { step++; next }
  /^yin> Bye$/ && step == 8 { step++; next }
  /^yin> / { unexpected = 1 }
  END { exit !(step == 9 && !unexpected) }
' "$transcript" || {
  echo "gambityinrepl: the Yin session did not produce the expected replies" >&2
  exit 1
}
echo "gambityinrepl: PASS — Yin state, frontend refusal, FFI, and clean quit"
