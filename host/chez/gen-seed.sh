#!/bin/sh
# Stage both verified artifacts beside their destination before publishing.
set -eu
target=$1
chez=$2
case "$target" in
  gambit|guile) ;;
  *) echo "gen-seed: expected gambit or guile" >&2; exit 2 ;;
esac
out=${GEN_SEED_OUT_DIR:-host/$target/seed}
mkdir -p "$out"
stage=$(mktemp -d "$out/.mint.XXXXXX")
trap 'rm -rf "$stage"' EXIT
sh host/gambit/ffi/watchdog.sh 240 "$chez" --script host/chez/gen-seed.ss "$target" "$stage"
mv "$stage/prelude.ss" "$out/prelude.ss"
mv "$stage/image.ss" "$out/image.ss"
