#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
shasum -a 256 host/gambit/ffi/joltffi-bridge.scm host/gambit/ffi/generated-shims.scm host/gambit/ffi/shapes.json host/gambit/ffi/generate-shims.py host/gambit/ffi/joltffi-fixture.c host/gambit/ffi/joltffi-fixture2.c host/gambit/ffi/joltffi-dep.c host/gambit/ffi/joltffi-unloadable.c host/gambit/ffi/TOOLCHAIN.sha256 > host/gambit/ffi/DIGESTS.txt
