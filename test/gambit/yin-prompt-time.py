"""Record wall time to the first visible Yin prompt and preserve output bytes."""
import os
import subprocess
import sys
import time

prompt = b"yin> "
tail = b""
seen = False
started = time.monotonic()
with subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE) as child:
    while chunk := os.read(child.stdout.fileno(), 65536):
        if not seen:
            window = tail + chunk
            if prompt in window:
                seen = True
                print(f"Yin first prompt: {time.monotonic() - started:.3f}s",
                      file=sys.stderr, flush=True)
            else:
                tail = window[-(len(prompt) - 1):]
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
    sys.exit(child.wait())
