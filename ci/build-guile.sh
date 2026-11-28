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
# Guile selects GNU or BSD date syntax at configure time, then looks up
# date again in the libpath.h recipe. Ubuntu's uutils date matches neither
# of those checks. Pin a compatible date for both phases.
date_tool=
for candidate in /usr/bin/gnudate /usr/bin/date /bin/date "$(command -v date || :)"; do
  case "$candidate" in /*) ;; *) continue ;; esac
  test -x "$candidate" || continue
  if "$candidate" --version 2>/dev/null | grep -q GNU; then
    "$candidate" -u -d @0 '+%s' >/dev/null 2>&1 || continue
  else
    "$candidate" -j -u -r 0 '+%s' >/dev/null 2>&1 || continue
  fi
  date_tool=$candidate
  break
done
if test -z "$date_tool"; then
  echo "build-guile: GNU or BSD date is required" >&2
  exit 1
fi
mkdir "$src/tools"
ln -s "$date_tool" "$src/tools/date"
PATH="$src/tools:$PATH"
export PATH
printf 'build-guile: using date from %s\n' "$date_tool"

./configure --prefix="$prefix" --disable-static
make -j"$jobs"
make install
