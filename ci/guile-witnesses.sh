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
if [ "$(uname -s)" = Linux ]; then
  # The fixture linker uses pkg-config. Give the runtime loader the same
  # pinned library directory, ahead of any inherited paths.
  test -r "$GUILE_PREFIX/lib/pkgconfig/guile-3.0.pc"
  guile_libdir=$(pkg-config --variable=libdir guile-3.0)
  case "$guile_libdir" in
    /*) ;;
    *) echo "Invalid Guile libdir: $guile_libdir" >&2; exit 1 ;;
  esac
  if [ "$(id -u)" -eq 0 ] && command -v ldconfig >/dev/null 2>&1; then
    ldconfig -n "$guile_libdir"
  fi
  export LD_LIBRARY_PATH="$guile_libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
export XDG_CACHE_HOME="$scratch/cache"
export TMPDIR="$scratch"
cp host/guile/witnesses/*.scm host/guile/witnesses/*.c host/guile/witnesses/*.sh "$scratch/"

{
  uname -a
  if [ "$(uname -s)" = Linux ]; then printf 'Guile libdir: %s\n' "$guile_libdir"; fi
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
