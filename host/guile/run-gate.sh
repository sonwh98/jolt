#!/bin/sh
set -eu
gate=$1
guile=$2
case "$guile" in
  /*) ;;
  *) echo "$gate: Guile executable path must be absolute" >&2; exit 1 ;;
esac
mkdir -p "build/guile/$gate"
scratch=$(mktemp -d "build/guile/$gate/run.XXXXXX")
echo "$gate: output in $scratch"
profiles=full
case "$gate" in
  guilekernel) profiles=kernel ;;
  guileprofile) profiles="full repl kernel" ;;
  guiletwins)
    {
      grep -oE ':call "[^"]+"' jolt-core/jolt/op_registry.clj | sed 's/:call "//; s/"$//'
      grep -ohE '"jolt-[ln]([*+/<>=-][^" ]*)"' jolt-core/jolt/backend_scheme.clj jolt-core/jolt/backend_scheme/*.clj | tr -d '"'
    } | LC_ALL=C sort -u > "$scratch/heads"
    grep -oE ':value "[^"]+"' jolt-core/jolt/op_registry.clj |
      sed 's/:value "//; s/"$//' | LC_ALL=C sort -u > "$scratch/value-heads"
    export JOLT_GUILE_HEADS="$scratch/heads"
    export JOLT_GUILE_VALUE_HEADS="$scratch/value-heads"
    ;;
esac
export JOLT_GUILE_EMITTED="$scratch/emitted.ss"
driver=host/guile/gates.ss
seconds=180
case "$gate" in
  adaptercheck)
    driver=host/scheme-adapter/guile.ss
    profiles=kernel
    seconds=60
    ;;
  guilecheck)
    driver=host/guile/guilecheck.ss
    profiles=kernel
    seconds=120
    ;;
  guileunbound) driver=host/guile/unbound.ss ;;
esac
for profile in $profiles; do
  cache="$PWD/$scratch/$profile-cache"
  mkdir "$cache"
  log="$scratch/$profile.log"
  if ! JOLT_GUILE_PROFILE="$profile" XDG_CACHE_HOME="$cache" GUILE_LOAD_COMPILED_PATH= \
      sh host/guile/witnesses/watchdog.sh "$seconds" "$guile" --no-auto-compile -s "$driver" "$gate" \
      </dev/null >"$log" 2>&1; then
    cat "$log" >&2
    exit 1
  fi
  cat "$log"
  case "$gate" in
    adaptercheck) grep -Fxq 'adaptercheck (guile): guile adapter contract satisfied' "$log" ;;
    guilecheck) grep -Eq '^guilecheck summary: [1-9][0-9]* passed, 0 failed$' "$log" ;;
    *) grep -Fxq "$gate: PASS ($profile)" "$log" ;;
  esac
  if [ "$gate" = guileboot ]; then grep -Fxq BOOT-OK "$log"; fi
done
