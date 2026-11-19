#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
shasum -a 256 -c host/gambit/ffi/DIGESTS.txt
python3 host/gambit/ffi/generate-shims.py --check
