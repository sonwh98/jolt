#!/bin/sh
# External deadline kills the gate process group. Keep stdin for the command.
exec python3 -c '
import os, signal, subprocess, sys
seconds = float(sys.argv[1])
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    status = p.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    print("WATCHDOG: TIMEOUT after %ss: %s" % (seconds, " ".join(sys.argv[2:])), file=sys.stderr)
    sys.exit(124)
sys.exit(status if status >= 0 else 128 - status)
' "$@"
