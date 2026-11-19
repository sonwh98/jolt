#!/bin/sh
set -eu
record="$(pwd)/host/gambit/ffi/TOOLCHAIN.sha256"
# This qualification record is for the provisioned macOS arm64 runtime only.
# A new platform/configuration must supply and qualify its own record.
cd "$1"
shasum -a 256 -c "$record"
