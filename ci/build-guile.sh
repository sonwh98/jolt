#!/bin/sh
# Build the interpreter and its matching pkg-config metadata and headers.
set -eu
prefix=$1
jobs=$2
src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
curl --fail --location --retry 3 --max-time 120 \
  https://ftp.gnu.org/gnu/guile/guile-3.0.11.tar.xz -o "$src/guile.tar.xz"
(
  cd "$src"
  printf '%s  %s\n' 818c79d236657a7fa96fb364137cc7b41b3bdee0d65c6174ca03769559579460 guile.tar.xz |
    shasum -a 256 -c -
)
tar -xJf "$src/guile.tar.xz" -C "$src"
cd "$src/guile-3.0.11"
./configure --prefix="$prefix" --disable-static
make -j"$jobs"
make install
