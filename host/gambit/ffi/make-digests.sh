#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
LC_ALL=C
export LC_ALL
digests() {
  shasum -a 256 host/gambit/ffi/joltffi-bridge.scm \
    host/gambit/ffi/generated-shims.scm host/gambit/ffi/shapes.json \
    host/gambit/ffi/generate-shims.py host/gambit/ffi/joltffi-fixture.c \
    host/gambit/ffi/joltffi-fixture2.c host/gambit/ffi/joltffi-dep.c \
    host/gambit/ffi/joltffi-unloadable.c host/gambit/ffi/toolchain.py \
    host/gambit/ffi/record-toolchain.sh host/gambit/ffi/verify-toolchain.sh \
    host/gambit/ffi/verify-digests.sh host/gambit/ffi/make-digests.sh
}
case ${1:-} in
  "") digests > host/gambit/ffi/DIGESTS.txt ;;
  --check)
    shasum -a 256 -c host/gambit/ffi/DIGESTS.txt
    if [ "$(digests)" != "$(cat host/gambit/ffi/DIGESTS.txt)" ]; then
      echo "gambitffi: pinned source catalog is stale; explicitly update the source digests" >&2
      exit 1
    fi
    ;;
  *) echo "usage: make-digests.sh [--check]" >&2; exit 2 ;;
esac
