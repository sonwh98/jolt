#!/usr/bin/env python3
"""Record and verify this checkout's Gambit installation, never global pins."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
RECORD_DIR = ROOT / "build/gambit-ffi/provenance"
PATHS = (
    "bin/gsi", "bin/gsc", "bin/gambuild-C", "include/gambit.h",
    "lib/libgambit.a", "lib/libgambitgsi.a", "lib/libgambitgsc.a",
)
FORMAT = "joltffi toolchain provenance v2"


def platform_key():
    host = os.uname()
    system, machine = host.sysname.lower(), host.machine.lower()
    machine = {"aarch64": "arm64", "amd64": "x86_64"}.get(machine, machine)
    key = system + "-" + machine
    # Android/bionic reports Linux/aarch64. Each install records its own
    # configuration and bytes under linux-arm64; no glibc binary pins are used.
    if system not in ("darwin", "linux") or machine not in ("arm64", "x86_64"):
        raise ValueError("unsupported uname platform: " + repr(key) +
                         "; expected Darwin/Linux on arm64/x86_64")
    return key


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def current_record(prefix, key):
    inputs = {name: digest(prefix / name) for name in PATHS}
    version = subprocess.run([str(prefix / "bin/gsi"), "-v"], check=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, timeout=15).stdout.strip()
    # Gambit -v: version, build stamp, target triplet, quoted configure command.
    # Hash the configure summary without surrounding double quotes/newline.
    parts = version.split(None, 3)
    if (len(parts) != 4 or parts[0] != "v4.9.8"
            or not parts[3].startswith('"./configure') or not parts[3].endswith('"')
            or "\n" in version):
        raise ValueError("unsupported Gambit version/configure summary: " + repr(version))
    return {"format": FORMAT, "platform": key, "install_path": str(prefix),
            "gambit_version_string": version,
            "configure_summary_sha256": hashlib.sha256(parts[3][1:-1].encode("utf-8")).hexdigest(),
            "inputs_sha256": inputs}


def render(record):
    return json.dumps(record, sort_keys=True, indent=2) + "\n"


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2 or argv[0] not in ("record", "verify"):
        print("usage: toolchain.py record|verify GAMBIT_PREFIX", file=sys.stderr)
        return 2
    try:
        key = platform_key()
        path = RECORD_DIR / ("TOOLCHAIN." + key + ".json")
        prefix = Path(argv[1]).resolve()
        command = "sh host/gambit/ffi/record-toolchain.sh " + shlex.quote(str(prefix))
        print("gambitffi: platform=" + key + " manifest=" + str(path), flush=True)
        if argv[0] == "verify" and not path.is_file():
            raise ValueError("missing local toolchain provenance; record with: " + command)
        record = current_record(prefix, key)
        if argv[0] == "record":
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8",
                                                 dir=path.parent, prefix=".TOOLCHAIN.",
                                                 delete=False) as stream:
                    temporary = Path(stream.name)
                    stream.write(render(record))
                os.replace(temporary, path)
            finally:
                if temporary is not None and temporary.exists():
                    temporary.unlink()
            print("gambitffi: recorded local toolchain provenance (7 inputs); source digests unchanged")
        else:
            if path.read_text(encoding="utf-8") != render(record):
                raise ValueError("stale local toolchain provenance (platform/version/configure/"
                                 "install path/input mismatch); record with: " + command)
            print("gambitffi: local toolchain provenance verified (7 inputs)")
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("gambitffi: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
