#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
prefix=${1:-${GAMBIT_PREFIX:-}}
if [ -z "$prefix" ]; then
  echo "usage: verify-digests.sh GAMBIT_PREFIX (or set GAMBIT_PREFIX)" >&2
  exit 2
fi
sh host/gambit/ffi/verify-toolchain.sh "$prefix"
sh host/gambit/ffi/make-digests.sh --check
python3 host/gambit/ffi/generate-shims.py --check
