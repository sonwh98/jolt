#!/bin/sh
# Qualify the pinned runtime without overwriting the checked-in Darwin baseline.
set -eu
out=$1
shift
mkdir -p "$out"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

GUILE="${GUILE_PREFIX:?}/bin/guile"
case "$GUILE" in /*) ;; *) echo "GUILE_PREFIX must be absolute" >&2; exit 1 ;; esac
PKG_CONFIG_PATH="$GUILE_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export GUILE PKG_CONFIG_PATH
export XDG_CACHE_HOME="$scratch/cache"
export TMPDIR="$scratch"
cp host/guile/witnesses/*.scm host/guile/witnesses/*.c host/guile/witnesses/*.sh "$scratch/"

{
  uname -a
  "$GUILE" --version
  test "$("$GUILE" --no-auto-compile -c '(display (version))')" = 3.0.11
  cc --version
  test "$(pkg-config --modversion guile-3.0)" = 3.0.11
  pkg-config --modversion guile-3.0 libffi
  pkg-config --cflags --libs guile-3.0 libffi
} >"$out/toolchain.log" 2>&1
cat "$out/toolchain.log"

status=0
sh "$scratch/run-all.sh" "$@" >"$out/witnesses.log" 2>&1 || status=$?
printf '### run-all exit=%s\n' "$status" >>"$out/witnesses.log"
cat "$out/witnesses.log"
exit "$status"
