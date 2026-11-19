#!/usr/bin/env python3
"""Record or verify the running platform's explicit Gambit provenance pins."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

MANIFEST_DIR = Path(__file__).resolve().parent
PATHS = (
    "bin/gsi", "bin/gsc", "bin/gambuild-C", "include/gambit.h",
    "lib/libgambit.a", "lib/libgambitgsi.a", "lib/libgambitgsc.a",
)
FORMAT = "# joltffi toolchain manifest v1"


def platform_key():
    host = os.uname()
    system, machine = host.sysname.lower(), host.machine.lower()
    machine = {"aarch64": "arm64", "amd64": "x86_64"}.get(machine, machine)
    key = system + "-" + machine
    if not re.fullmatch(r"[a-z0-9_-]+", key):
        raise ValueError("invalid uname platform key: " + repr(key))
    return key


def selected_manifest():
    key = platform_key()
    path = MANIFEST_DIR / ("TOOLCHAIN." + key + ".sha256")
    print("gambitffi: platform=" + key + " manifest=host/gambit/ffi/" + path.name,
          flush=True)
    return key, path


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def render_manifest(prefix, key):
    # Hash everything before writing: a missing input cannot leave partial pins.
    rows = [digest(prefix / name) + "  " + name for name in PATHS]
    return "\n".join([FORMAT, "# platform: " + key] + rows) + "\n"


def read_manifest(path, key):
    if not path.is_file():
        raise ValueError("missing toolchain manifest: " + str(path) +
                         "; record this platform explicitly with record-toolchain.sh")
    lines = path.read_text(encoding="ascii").splitlines()
    if lines[:2] != [FORMAT, "# platform: " + key]:
        raise ValueError("toolchain manifest format/platform header mismatch: " + str(path))
    rows = [re.fullmatch(r"([0-9a-f]{64})  (.+)", line) for line in lines[2:]]
    if (len(rows) != len(PATHS) or any(row is None for row in rows)
            or tuple(row.group(2) for row in rows) != PATHS):
        raise ValueError("toolchain manifest must pin exactly the seven ordered inputs: " + str(path))
    return [(row.group(1), row.group(2)) for row in rows]


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2 or argv[0] not in ("record", "verify"):
        print("usage: toolchain.py record|verify GAMBIT_PREFIX", file=sys.stderr)
        return 2
    try:
        key, path = selected_manifest()
        prefix = Path(argv[1]).resolve()
        if argv[0] == "record":
            content = render_manifest(prefix, key)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode="w", encoding="ascii",
                                                 dir=MANIFEST_DIR,
                                                 prefix="." + path.name + ".",
                                                 delete=False) as stream:
                    temporary = Path(stream.name)
                    stream.write(content)
                os.replace(temporary, path)
            finally:
                if temporary is not None and temporary.exists():
                    temporary.unlink()
            # Explicit recording also pins the new manifest in the source index.
            # Verification never calls this recording/update path.
            subprocess.run(["sh", str(MANIFEST_DIR / "make-digests.sh")], check=True)
            print("gambitffi: recorded 7 toolchain inputs")
            print("gambitffi: refreshed host/gambit/ffi/DIGESTS.txt")
        else:
            failures = []
            for expected, name in read_manifest(path, key):
                if digest(prefix / name) == expected:
                    print(name + ": OK")
                else:
                    print(name + ": FAILED", file=sys.stderr)
                    failures.append(name)
            if failures:
                raise ValueError("toolchain digest mismatch (" + str(len(failures)) + " inputs)")
            print("gambitffi: toolchain verified (7 inputs)")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("gambitffi: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
